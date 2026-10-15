"""Scenario: dust cannot lock the vault.

Tests that no dust state can permanently block deposits or withdrawals, in
three scenarios (one test each, all sharing the session localnet on separate
subnets):
  1. A position reduced to dust under a validator that dropped out of the
     set: the alpha exit is refused cheaply with a clear error, the TAO
     exit still pays out in full, and the vault works normally afterwards.
  2. A market crash that devalues a position below the chain's minimum:
     the alpha exit is refused clearly instead of failing forever, the TAO
     exit still pays out, and deposits keep working at the crashed price.
  3. A small holder alongside a large one, its slice below the minimum:
     both exits refuse without touching the large holder's backing, and a
     top-up lets the small holder leave with exactly its slice; the large
     holder exits unharmed.
"""
import pytest

from alpha_e2e import chain, config, exits, extrinsics
from alpha_e2e.checks import assert_gas_within, assert_value_per_share_kept, min_tao_out_for
from alpha_e2e.substrate import h160_to_ss58, h160_to_substrate_b32


@pytest.mark.scenario
def test_rotated_out_dust_cannot_lock_the_vault(env):
    chain_min_stake = env.chain_min_stake_tao()
    print(f"  chain minimum stake = {chain_min_stake} RAO")

    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    hotkeys = env.subnet_hotkey_pubkeys(0)
    rotated_out_hotkey_pubkey = hotkeys[0]
    kept_hotkey_b_pubkey = hotkeys[1]

    _, floor_boundary_alpha = env.floor_boundary(netuid, chain_min_stake)
    env.deposit_and_wrap(
        netuid, rotated_out_hotkey_pubkey, env.hotkey_ss58s[0], floor_boundary_alpha * 3 // 2,
        1_500_000, "Rotated-out dust: wrap failed",
    )

    # Burn 5/6 of the shares, then rotate: the leftover is sub-floor dust on a
    # rotated-out hotkey and there is no fresh deposit to consolidate it - the
    # worst stranded state the vault can reach.
    clone_coldkey = env.clone_coldkey(token_id)
    exits.unwrap(
        env, token_id, env.vault_shares(token_id) * 5 // 6, "Rotated-out dust: partial unwrap failed",
        hotkeys=hotkeys,
    )
    dust_residue = env.stake(rotated_out_hotkey_pubkey, clone_coldkey, netuid)
    assert env.alpha_value_tao(netuid, dust_residue) < chain_min_stake, (
        f"Rotated-out dust: residual {dust_residue} alpha RAO is not sub-floor"
    )
    env.set_validator(netuid, kept_hotkey_b_pubkey)
    print(f"  Position is now {dust_residue} alpha RAO of dust under a rotated-out hotkey")

    remaining_shares = env.vault_shares(token_id)
    refusal_receipt = env.assert_vault_reverts_with(
        "ConsolidationBelowFloor()", 1_500_000,
        "Rotated-out dust: alpha exit did NOT revert as ConsolidationBelowFloor",
        "unwrap(uint256,uint256,bytes32,uint256)",
        token_id, remaining_shares, env.wrapper_substrate_coldkey, 0,
    )
    assert_gas_within(
        refusal_receipt, config.REVERT_GAS_BOUND, "Rotated-out dust: alpha-exit refusal",
    )

    # The TAO exit needs no consolidation and full drains are floor-exempt on the
    # chain: it must pay out even from this state.
    position_alpha = env.total_stake_across(clone_coldkey, netuid, hotkeys)
    tao_exit_receipt, _ = exits.unwrap_for_tao(
        env, token_id, remaining_shares, "Rotated-out dust: TAO exit from the dust state", hotkeys=hotkeys,
        min_tao_out=min_tao_out_for(env.alpha_to_tao_quote(netuid, position_alpha)),
    )
    assert env.vault_shares(token_id) == 0, "Rotated-out dust: shares not fully burned"
    exits.assert_drained(env, token_id, hotkeys, tao_exit_receipt, "Rotated-out dust: TAO exit")
    print("  TAO exit drained the dust in full and paid out per the chain quote")

    # The token stays fully usable after the episode.
    _, floor_boundary_alpha = env.floor_boundary(netuid, chain_min_stake)
    env.deposit_and_wrap(
        netuid, kept_hotkey_b_pubkey, env.hotkey_ss58s[1], floor_boundary_alpha * 3 // 2, 1_500_000,
        "Rotated-out dust: follow-up wrap failed",
    )
    exits.unwrap(
        env, token_id, env.vault_shares(token_id), "Rotated-out dust: follow-up unwrap failed", hotkeys=hotkeys,
    )
    print("  Round-trip after the dust episode: wrap and unwrap both clean")


@pytest.mark.scenario
def test_price_crash_cannot_lock_exits(env):
    chain_min_stake = env.chain_min_stake_tao()

    netuid = env.netuids[1]
    token_id = env.token_ids[1]
    hotkeys = env.subnet_hotkey_pubkeys(1)
    position_hotkey_pubkey = hotkeys[0]
    position_hotkey_ss58 = env.hotkey_ss58s[3]
    sell_hotkey_pubkey = hotkeys[1]
    sell_hotkey_ss58 = env.hotkey_ss58s[4]

    crash_price, floor_boundary_alpha = env.floor_boundary(netuid, chain_min_stake)
    # Just above the floor, so a sell that roughly halves the price (the crash
    # helper's reach) drops the whole position well under it.
    env.deposit_and_wrap(
        netuid, position_hotkey_pubkey, position_hotkey_ss58, floor_boundary_alpha * 12 // 10, 1_500_000,
        "Price crash: wrap failed",
    )
    clone_coldkey = env.clone_coldkey(token_id)
    print(f"  Healthy position wrapped at price {crash_price}")

    # Alice dumps alpha until the whole position is worth less than the floor -
    # devalued by the market alone, with no stake moved.
    env.crash_price_until_below(
        netuid, sell_hotkey_pubkey, sell_hotkey_ss58,
        env.total_stake_across(clone_coldkey, netuid, hotkeys), chain_min_stake * 9 // 10, "Price crash",
    )

    crashed_shares = env.vault_shares(token_id)
    refusal_receipt = env.assert_vault_reverts_with(
        "WithdrawTooSmall()", 1_500_000,
        "Price crash: alpha exit did NOT revert as WithdrawTooSmall",
        "unwrap(uint256,uint256,bytes32,uint256)",
        token_id, crashed_shares, env.wrapper_substrate_coldkey, 0,
    )
    assert_gas_within(refusal_receipt, config.REVERT_GAS_BOUND, "Price crash: alpha-exit refusal")

    position_alpha = env.total_stake_across(clone_coldkey, netuid, hotkeys)
    tao_exit_receipt, _ = exits.unwrap_for_tao(
        env, token_id, crashed_shares, "Price crash: TAO exit at the crashed price", hotkeys=hotkeys,
        min_tao_out=min_tao_out_for(env.alpha_to_tao_quote(netuid, position_alpha)),
    )
    assert env.vault_shares(token_id) == 0, "Price crash: shares not fully burned"
    exits.assert_drained(env, token_id, hotkeys, tao_exit_receipt, "Price crash: TAO exit")
    print("  TAO exit paid out the devalued position in full")

    # Deposits and alpha exits keep working at the crashed price.
    _, floor_boundary_alpha = env.floor_boundary(netuid, chain_min_stake)
    env.deposit_and_wrap(
        netuid, position_hotkey_pubkey, position_hotkey_ss58, floor_boundary_alpha * 3 // 2, 1_500_000,
        "Price crash: post-crash wrap failed",
    )
    _, delivered = exits.unwrap(
        env, token_id, env.vault_shares(token_id), "Price crash: post-crash unwrap failed", hotkeys=hotkeys,
    )
    print(f"  Post-crash round-trip clean: wrap accepted, unwrap delivered {delivered} alpha RAO")


@pytest.mark.scenario
def test_sub_floor_co_holder_cannot_be_locked_in_or_leak_the_other_holder(env):
    chain_min_stake = env.chain_min_stake_tao()

    netuid = env.netuids[2]
    token_id = env.token_ids[2]
    hotkeys = env.subnet_hotkey_pubkeys(2)
    position_hotkey_pubkey = hotkeys[0]
    position_hotkey_ss58 = env.hotkey_ss58s[6]
    second_holder_coldkey = h160_to_substrate_b32(config.SECOND_HOLDER_ADDRESS)

    extrinsics.fund_account(h160_to_ss58(config.SECOND_HOLDER_ADDRESS), 10 * config.RAO_PER_TAO)

    _, floor_boundary_alpha = env.floor_boundary(netuid, chain_min_stake)
    large_deposit = floor_boundary_alpha * 10
    small_deposit = floor_boundary_alpha * 12 // 10
    env.deposit_and_wrap(
        netuid, position_hotkey_pubkey, position_hotkey_ss58, large_deposit, 2_500_000,
        "Co-holder: large wrap failed",
    )
    env.deposit_and_wrap(
        netuid, position_hotkey_pubkey, position_hotkey_ss58, small_deposit, 1_500_000,
        "Co-holder: small wrap failed",
        user=config.SECOND_HOLDER_ADDRESS, private_key=config.SECOND_HOLDER_PRIVATE_KEY,
    )
    clone_coldkey = env.clone_coldkey(token_id)
    print(f"  Two holders wrapped: large {large_deposit}, small {small_deposit} alpha RAO")

    # Selling most of a healthy position leaves the seller with a slice worth less than
    # the chain will move or sell. The large co-holder's stake deepens the pool, so a
    # market sell could not devalue the slice this far; a share sale gets there without
    # touching the price.
    small_holder_shares_before = env.vault_shares(token_id, config.SECOND_HOLDER_ADDRESS)
    env.transfer_shares(
        token_id, config.SECOND_HOLDER_ADDRESS, config.WRAPPER_USER_ADDRESS,
        small_holder_shares_before * 2 // 3, "Co-holder: share sale failed",
        private_key=config.SECOND_HOLDER_PRIVATE_KEY,
    )

    small_holder_value = env.alpha_value_tao(
        netuid, env.holder_assets(token_id, config.SECOND_HOLDER_ADDRESS),
    )
    large_holder_value = env.alpha_value_tao(
        netuid, env.holder_assets(token_id, config.WRAPPER_USER_ADDRESS),
    )
    assert small_holder_value < chain_min_stake, (
        f"Co-holder: small slice not below the floor "
        f"({small_holder_value} RAO, floor {chain_min_stake})"
    )
    assert large_holder_value >= chain_min_stake * 2, (
        f"Co-holder: large holder not clear of the floor ({large_holder_value} RAO)"
    )

    # Both rails refuse the sub-floor slice: the chain cannot move or sell that
    # little, and force-selling it would sweep value out of the co-holder's backing.
    small_holder_shares = env.vault_shares(token_id, config.SECOND_HOLDER_ADDRESS)
    alpha_refusal_receipt = env.assert_vault_reverts_with(
        "WithdrawTooSmall()", 1_500_000,
        "Co-holder: sub-floor alpha exit did NOT revert as WithdrawTooSmall",
        "unwrap(uint256,uint256,bytes32,uint256)", token_id, small_holder_shares, second_holder_coldkey, 0,
        private_key=config.SECOND_HOLDER_PRIVATE_KEY, sender=config.SECOND_HOLDER_ADDRESS,
    )
    assert_gas_within(
        alpha_refusal_receipt, config.REVERT_GAS_BOUND, "Co-holder: alpha-exit refusal",
    )
    tao_refusal_receipt = env.assert_vault_reverts_with(
        "WithdrawTooSmall()", 2_500_000,
        "Co-holder: sub-floor TAO exit did NOT revert as WithdrawTooSmall",
        "unwrapForTao(uint256,uint256,uint256)", token_id, small_holder_shares, 1,
        private_key=config.SECOND_HOLDER_PRIVATE_KEY, sender=config.SECOND_HOLDER_ADDRESS,
    )
    assert_gas_within(
        tao_refusal_receipt, config.REVERT_GAS_BOUND, "Co-holder: TAO-exit refusal",
    )
    print("  Both exits refused the sub-floor slice cleanly")

    # Escape: topping up past the floor unlocks a full exit on the alpha rail.
    _, floor_boundary_alpha = env.floor_boundary(netuid, chain_min_stake)
    env.deposit_and_wrap(
        netuid, position_hotkey_pubkey, position_hotkey_ss58, floor_boundary_alpha * 2, 1_500_000,
        "Co-holder: top-up wrap failed",
        user=config.SECOND_HOLDER_ADDRESS, private_key=config.SECOND_HOLDER_PRIVATE_KEY,
    )
    small_holder_shares = env.vault_shares(token_id, config.SECOND_HOLDER_ADDRESS)
    supply = env.vault_total_supply(token_id)
    receipt, small_holder_delivered = exits.unwrap(
        env, token_id, small_holder_shares, "Co-holder: post-top-up exit failed", hotkeys=hotkeys,
        coldkey=second_holder_coldkey, private_key=config.SECOND_HOLDER_PRIVATE_KEY,
    )
    assert env.vault_shares(token_id, config.SECOND_HOLDER_ADDRESS) == 0, (
        "Co-holder: small holder shares not fully burned"
    )
    exit_block = chain.receipt_block_number(receipt, "Co-holder exit")
    assert_value_per_share_kept(
        env.total_stake_across(clone_coldkey, netuid, hotkeys, exit_block - 1), supply,
        env.total_stake_across(clone_coldkey, netuid, hotkeys, exit_block), supply - small_holder_shares,
        config.ROUNDING_DUST_TOTAL_RAO + 1, "Co-holder: the small holder's exit changed the large holder's value",
    )
    print(f"  Top-up unlocked the alpha exit: small holder left with {small_holder_delivered} alpha RAO")

    position_alpha = env.total_stake_across(clone_coldkey, netuid, hotkeys)
    large_exit_receipt, _ = exits.unwrap_for_tao(
        env, token_id, env.vault_shares(token_id), "Co-holder: large holder's exit", hotkeys=hotkeys,
        min_tao_out=min_tao_out_for(env.alpha_to_tao_quote(netuid, position_alpha)),
    )
    exits.assert_drained(env, token_id, hotkeys, large_exit_receipt, "Co-holder: both holders exited")
    print("  Large holder exited in full; vault position fully drained")

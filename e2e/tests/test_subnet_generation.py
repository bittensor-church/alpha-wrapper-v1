"""A token follows the chain's registration counter, not the registration block.

Chain migrations have rewritten live subnets' registration blocks. A position must
survive that untouched, while a subnet dissolved and registered again must get a new
token with the old one still redeemable for its dissolution refund.
"""
import pytest

from alpha_e2e import bootstrap, chain, checks, config, exits, extrinsics

IMMUNITY_EXTENSION_BLOCKS = 13 * 7200
TOKENS_PER_REGISTRATION = 2**16


@pytest.mark.scenario
def test_token_follows_the_registration_counter_not_the_block(env):
    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    hotkeys = env.subnet_hotkey_pubkeys(0)

    hotkey_ss58 = env.subnet_hotkey_ss58s(0)[0]

    receipt = env.deposit_and_wrap(
        netuid, hotkeys[0], hotkey_ss58,
        config.DEPOSIT_RAO, 1_500_000, "Generation: wrap failed",
    )
    shares = env.vault_shares(token_id)
    checks.assert_first_deposit_shares(shares, env.deposited(receipt, netuid), "Generation: setup wrap")
    registrations = env.registration_counter(netuid)
    assert token_id == netuid + registrations * TOKENS_PER_REGISTRATION, (
        f"token {token_id} should carry netuid {netuid} in its low 16 bits and registration {registrations} above"
    )

    block_before = extrinsics.network_registration_block(netuid)
    extrinsics.set_network_registration_block(netuid, block_before + IMMUNITY_EXTENSION_BLOCKS)

    assert env.current_token_id(netuid) == token_id, "a rewritten registration block changes nothing"
    assert env.backing_intact(token_id), "the record is untouched"
    exits.unwrap(
        env, token_id, shares // 4, "Generation: the exit should pay in alpha after the rewrite",
        hotkeys=hotkeys, label="unwrap [after block rewrite]",
    )
    receipt = env.deposit_and_wrap(
        netuid, hotkeys[0], hotkey_ss58,
        config.DEPOSIT_RAO // 10, 1_500_000, "Generation: deposits should land on the same token",
    )
    deposited = env.deposited(receipt, netuid)
    joined = env.stake_change(
        env.clone_coldkey(token_id), netuid, hotkeys, chain.receipt_block_number(receipt, "Generation: deposit"),
    )
    assert abs(joined - deposited) <= config.ROUNDING_DUST_SLOT_RAO, (
        f"the existing position's clone gained {joined} RAO of a {deposited} RAO deposit"
    )

    extrinsics.dissolve_network(netuid)
    env.wait_for_dissolution_cleanup(netuid)
    assert bootstrap.create_subnet() == netuid, "the chain hands the freed netuid back"

    assert env.registration_counter(netuid) == registrations + 1, "the counter stepped with the registration"
    assert env.current_token_id(netuid) == netuid + (registrations + 1) * TOKENS_PER_REGISTRATION, (
        "so the new subnet has a new token"
    )

    old_clone = env.clone_address(token_id)
    clone_refund = chain.cast_balance_wei(old_clone)
    assert clone_refund > 0, "the old token's clone received no dissolution refund"
    remaining_shares = env.vault_shares(token_id)
    assert env.vault_total_supply(token_id) == remaining_shares, "the wrapper user should hold every share"
    balance_before = env.user_tao_wei()
    receipt = env.vault_send(
        2_000_000, "Generation: the old token should redeem its dissolution refund",
        "unwrap(uint256,uint256,bytes32,uint256)",
        token_id, remaining_shares, env.wrapper_substrate_coldkey, 0,
    )
    refund = checks.reconstructed_payout(balance_before, env.user_tao_wei(), receipt, "Generation: refund")
    checks.assert_floored_pro_rata(
        refund, clone_refund, remaining_shares, remaining_shares, config.WEI_PER_RAO,
        "the old token's only holder should receive its clone's whole refund, in whole RAO",
    )
    assert env.vault_total_supply(token_id) == 0, "the old token kept outstanding shares"

"""A stranger claims a vacated validator hotkey, takes a fresh token's deposit and swaps it away.

A validator swaps its hotkey across all subnets before the token holds anything, so the
vault has no slot to follow. A stranger claims the vacated hotkey, the first deposit lands
under it, and the stranger swaps it across all subnets onto a hotkey of their own. The
vacated hotkey holds no seat, so the chain writes no edge for that swap; the validator's
edge still points at its successor, which holds nothing for the clone, so the vault searches
the clone's staking list, where the chain moved the entry to the stranger's hotkey. It finds
its alpha there with no watcher: quotes answer, no shortfall is declared, wraps, both exits and
rebalances work before the registry acts and never touch the claimed hotkey, and once the
registry names the successor the position moves off the stranger's hotkey.
"""
import pytest

from alpha_e2e import chain, config, exits, extrinsics, rails

STRANGER = "//ClaimStranger"
STRANGER_FUNDING_RAO = 2 * config.RAO_PER_TAO


@pytest.mark.scenario
def test_a_claimed_hotkey_swapped_away_keeps_every_rail_open(env):
    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    hotkeys = env.subnet_hotkey_pubkeys(0)
    vacated_pubkey, vacated_ss58 = hotkeys[0], env.subnet_hotkey_ss58s(0)[0]
    clone_coldkey = env.clone_coldkey(token_id)

    successor_ss58 = extrinsics.keypair_ss58("//ClaimSuccessor")
    successor_pubkey = extrinsics.keypair_pubkey("//ClaimSuccessor")
    extrinsics.swap_hotkey(vacated_ss58, successor_ss58)
    assert extrinsics.hotkey_owner(vacated_ss58) == "", "the swap should leave the old hotkey unowned"

    stranger_ss58 = extrinsics.keypair_ss58(STRANGER)
    extrinsics.fund_account(stranger_ss58, STRANGER_FUNDING_RAO)
    extrinsics.associate_hotkey(vacated_ss58, signer_uri=STRANGER)
    assert extrinsics.hotkey_owner(vacated_ss58) == stranger_ss58, "the stranger did not take the hotkey"

    receipt = env.deposit_and_wrap(
        netuid, vacated_pubkey, successor_ss58, config.DEPOSIT_RAO, 1_500_000,
        "Claimed hotkey: the first deposit failed", label="wrap [claimed hotkey, fresh token]",
    )
    collected = env.deposited(receipt, netuid)
    assert config.DEPOSIT_RAO - config.ROUNDING_DUST_SLOT_RAO <= collected <= config.DEPOSIT_RAO, (
        f"the wrap collected {collected} RAO of a {config.DEPOSIT_RAO} RAO deposit"
    )
    deposited = env.stake(vacated_pubkey, clone_coldkey, netuid, chain.receipt_block_number(receipt, "first deposit"))
    assert abs(deposited - collected) <= config.ROUNDING_DUST_SLOT_RAO, (
        f"a fresh token's deposit should land on the claimed hotkey: {deposited} RAO of {collected}"
    )

    stranger_hotkey_ss58 = extrinsics.keypair_ss58("//StrangerHotkey")
    stranger_hotkey_pubkey = extrinsics.keypair_pubkey("//StrangerHotkey")
    extrinsics.swap_hotkey(vacated_ss58, stranger_hotkey_ss58, signer_uri=STRANGER)
    assert extrinsics.hotkey_owner(stranger_hotkey_ss58) == stranger_ss58, "the stranger's swap did not land"
    assert env.stake(vacated_pubkey, clone_coldkey, netuid) == 0, "the swap should carry the vault's alpha"
    swapped_away_rao = env.stake(stranger_hotkey_pubkey, clone_coldkey, netuid)
    assert abs(swapped_away_rao - deposited) <= config.ROUNDING_DUST_SLOT_RAO, (
        "the alpha should sit on the stranger's hotkey"
    )

    assert env.hotkey_in_last_seen(token_id, vacated_pubkey), "no call has written the record yet"
    assert env.resolved_hotkeys(token_id)[0] == stranger_hotkey_pubkey, (
        "the vault should resolve the slot to the stranger's hotkey on the clone's staking list"
    )
    assert env.backing_intact(token_id), "the vault should find its alpha on the clone's staking list"
    read_block = chain.cast_block_number()
    found = env.stake(stranger_hotkey_pubkey, clone_coldkey, netuid, read_block)
    quoted = env.vault_total_stake(token_id, block=read_block)
    assert quoted == found, f"the quote prices {quoted} alpha RAO; the stranger's hotkey holds {found}"
    assert env.write_off_deadline(token_id) == 0, "a found slot is not a loss"

    located = hotkeys + [successor_pubkey, stranger_hotkey_pubkey]
    run = rails.assert_rails_skip_hotkey(
        env, 0, vacated_pubkey, successor_ss58, located, "swapped away", "Claimed hotkey",
    )
    wrap_block = chain.receipt_block_number(run.wrap_receipt, "Claimed hotkey: deposit after the swap away")
    joined = env.stake_change(clone_coldkey, netuid, [stranger_hotkey_pubkey], wrap_block)
    assert abs(joined - run.deposited) <= config.ROUNDING_DUST_SLOT_RAO, (
        f"the deposit should join the found alpha: {joined} RAO of {run.deposited}"
    )
    assert env.hotkey_in_last_seen(token_id, stranger_hotkey_pubkey, block=wrap_block), "the wrap records the found hotkey"
    assert not env.hotkey_in_last_seen(token_id, vacated_pubkey, block=wrap_block), "the record leaves the claimed hotkey"
    rebalance_block = chain.receipt_block_number(run.rebalance_receipt, "Claimed hotkey: rebalance")
    moved = env.stake_change(clone_coldkey, netuid, [stranger_hotkey_pubkey], rebalance_block)
    assert moved == 0, f"a rebalance before the registry acts keeps the position where it was found, moved {moved}"
    assert env.backing_intact(token_id), "every rail keeps the position whole"
    assert env.write_off_deadline(token_id) == 0, "no rail declares a shortfall"

    env.set_validator(netuid, successor_pubkey)
    receipt = env.vault_send_between_epochs(
        netuid, 4_000_000, "Claimed hotkey: rebalance onto the successor failed", "rebalance(uint256)", netuid,
        label="rebalance [successor attested]",
    )
    block = chain.receipt_block_number(receipt, "Claimed hotkey: rebalance onto the successor")
    position = env.stake(stranger_hotkey_pubkey, clone_coldkey, netuid, block - 1)
    assert env.stake(stranger_hotkey_pubkey, clone_coldkey, netuid, block) <= config.ROUNDING_DUST_SLOT_RAO, (
        "the position should leave the stranger's hotkey"
    )
    landed = env.stake(successor_pubkey, clone_coldkey, netuid, block)
    assert abs(landed - position) <= config.ROUNDING_DUST_SLOT_RAO, (
        f"the successor should take the whole position: {landed} RAO of {position}"
    )
    assert env.hotkey_in_last_seen(token_id, successor_pubkey), "the record moves to the successor"
    assert not env.hotkey_in_last_seen(token_id, stranger_hotkey_pubkey), "the record leaves the stranger's hotkey"

    receipt, _ = exits.unwrap(
        env, token_id, env.vault_shares(token_id), "Claimed hotkey: the full exit failed", hotkeys=located,
    )
    exits.assert_drained(env, token_id, located, receipt, "Claimed hotkey: full exit")

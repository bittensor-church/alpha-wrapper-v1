"""A stranger claims a vacated validator hotkey, takes a fresh token's deposit and swaps it away (L-06).

A validator swaps its hotkey across all subnets before the token holds anything, so the
vault has no slot to follow. A stranger claims the vacated hotkey, the first deposit lands
under it, and the stranger swaps it across all subnets onto a hotkey of their own. The
vacated hotkey holds no seat, so the chain writes no edge for that swap; the validator's
edge still points at its successor, which holds nothing for the clone, so the vault searches
the clone's staking list, where the chain renamed the entry. It finds its alpha there with
no watcher: quotes answer, no shortfall is declared, wraps, both exits and rebalances work
before the registry acts and never touch the claimed hotkey, and once the registry names the
successor the position moves off the stranger's hotkey.
"""
import pytest

from alpha_e2e import chain, config, exits, extrinsics

STRANGER = "//ClaimStranger"
STRANGER_FUNDING_RAO = 2 * config.RAO_PER_TAO


@pytest.mark.scenario
def test_a_claimed_hotkey_swapped_away_keeps_every_rail_open(env):
    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    hotkeys = env.subnet_hotkey_pubkeys(0)
    vacated_pubkey, vacated_ss58 = env.hotkey_pubkeys[0], env.hotkey_ss58s[0]
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
    assert collected >= config.DEPOSIT_RAO - config.ROUNDING_DUST_SLOT_RAO, (
        f"the wrap collected {collected} RAO of a {config.DEPOSIT_RAO} RAO deposit"
    )
    deposited = env.stake(vacated_pubkey, clone_coldkey, netuid)
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
    assert env.vault_total_stake(token_id) == swapped_away_rao, "the quote prices the alpha found on the list"
    assert env.write_off_deadline(token_id) == 0, "a found slot is not a loss"

    located = hotkeys + [successor_pubkey, stranger_hotkey_pubkey]
    shares = env.vault_shares(token_id)
    deposit = config.DEPOSIT_RAO // 10
    receipt = env.deposit_and_wrap(
        netuid, vacated_pubkey, successor_ss58, deposit, 1_500_000,
        "Claimed hotkey: a deposit after the swap away failed", label="wrap [swapped away]",
        min_shares_out=env.preview_wrap(token_id, deposit) * 95 // 100,
    )
    minted = env.vault_shares(token_id) - shares
    quoted_shares = env.preview_wrap(
        token_id, deposit, block=chain.receipt_block_number(receipt, "Claimed hotkey: wrap after the swap away") - 1,
    )
    assert quoted_shares * 99 // 100 <= minted <= quoted_shares, (
        f"Claimed hotkey: previewWrap quoted {quoted_shares} shares, the wrap minted {minted}"
    )
    joined = env.stake(stranger_hotkey_pubkey, clone_coldkey, netuid) - swapped_away_rao
    collected = env.deposited(receipt, netuid)
    assert abs(joined - collected) <= config.ROUNDING_DUST_SLOT_RAO, (
        f"the deposit should join the found alpha: {joined} RAO of {collected}"
    )
    assert env.stake(vacated_pubkey, clone_coldkey, netuid) == 0, "the claimed hotkey must receive nothing"
    assert env.hotkey_in_last_seen(token_id, stranger_hotkey_pubkey), "the wrap records the found hotkey"
    assert not env.hotkey_in_last_seen(token_id, vacated_pubkey), "the record leaves the claimed hotkey"

    shares = env.vault_shares(token_id)
    quoted_alpha, _ = env.preview_unwrap(token_id, shares // 2)
    _, delivered = exits.unwrap(
        env, token_id, shares // 2, "Claimed hotkey: the partial exit failed", hotkeys=located,
        label="unwrap [swapped away]",
    )
    assert delivered + config.ROUNDING_DUST_TOTAL_RAO >= quoted_alpha, (
        f"Claimed hotkey: previewUnwrap quoted {quoted_alpha} RAO but the exit paid {delivered}"
    )
    exits.unwrap_for_tao(
        env, token_id, shares // 4, "Claimed hotkey: the TAO exit failed", hotkeys=located,
        label="unwrapForTao [swapped away]",
    )
    assert env.stake(vacated_pubkey, clone_coldkey, netuid) == 0, "exits must not touch the claimed hotkey"

    position = env.stake(stranger_hotkey_pubkey, clone_coldkey, netuid)
    env.vault_send(4_000_000, "Claimed hotkey: rebalance failed", "rebalance(uint256)", netuid, label="rebalance [swapped away]")
    assert env.stake(vacated_pubkey, clone_coldkey, netuid) == 0, "a rebalance must not move stake onto the claimed hotkey"
    assert abs(env.stake(stranger_hotkey_pubkey, clone_coldkey, netuid) - position) <= config.ROUNDING_DUST_SLOT_RAO, (
        "a rebalance before the registry acts keeps the position where it was found"
    )
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

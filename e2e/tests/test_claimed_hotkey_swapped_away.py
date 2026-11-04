"""A stranger claims a vacated validator hotkey, takes a fresh token's deposit and swaps it away (L-06).

A validator swaps its hotkey across all subnets before the token holds anything, so the
vault has no slot to follow. A stranger claims the vacated hotkey, the first deposit lands
under it, and the stranger swaps it across all subnets onto a hotkey of their own. The
vacated hotkey holds no seat, so the chain writes no edge, but it renames the clone's
staking-list entry. The vault finds its alpha there with no watcher: quotes answer, no
shortfall is declared, wraps, both exits and rebalances work before the registry acts, and
once the registry names the successor the position moves off the stranger's hotkey.
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

    env.deposit_and_wrap(
        netuid, vacated_pubkey, successor_ss58, config.DEPOSIT_RAO, 1_500_000,
        "Claimed hotkey: the first deposit failed", label="wrap [claimed hotkey, fresh token]",
    )
    deposited = env.stake(vacated_pubkey, clone_coldkey, netuid)
    assert deposited > 0, "a fresh token's deposit should land on the claimed hotkey"

    moved_ss58 = extrinsics.keypair_ss58("//StrangerHotkey")
    moved_pubkey = extrinsics.keypair_pubkey("//StrangerHotkey")
    extrinsics.swap_hotkey(vacated_ss58, moved_ss58, signer_uri=STRANGER)
    assert extrinsics.hotkey_owner(moved_ss58) == stranger_ss58, "the stranger's swap did not land"
    assert env.stake(vacated_pubkey, clone_coldkey, netuid) == 0, "the swap should carry the vault's alpha"
    moved = env.stake(moved_pubkey, clone_coldkey, netuid)
    assert abs(moved - deposited) <= config.ROUNDING_DUST_SLOT_RAO, "the alpha should sit on the stranger's hotkey"

    assert env.backing_intact(token_id), "the vault should find its alpha on the clone's staking list"
    assert env.vault_total_stake(token_id) == moved, "the quote prices the alpha found on the list"
    assert env.write_off_deadline(token_id) == 0, "a found slot is not a loss"

    located = hotkeys + [successor_pubkey, moved_pubkey]
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
    assert env.stake(moved_pubkey, clone_coldkey, netuid) > moved, "the deposit joins the found alpha"
    assert env.backing_intact(token_id), "the record follows the found hotkey"

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
    env.vault_send(4_000_000, "Claimed hotkey: rebalance failed", "rebalance(uint256)", netuid, label="rebalance [swapped away]")
    assert env.backing_intact(token_id), "every rail keeps the position whole"
    assert env.write_off_deadline(token_id) == 0, "no rail declares a shortfall"

    env.set_validator(netuid, successor_pubkey)
    env.vault_send(4_000_000, "Claimed hotkey: rebalance onto the successor failed", "rebalance(uint256)", netuid,
                   label="rebalance [successor attested]")
    assert env.stake(moved_pubkey, clone_coldkey, netuid) <= config.ROUNDING_DUST_SLOT_RAO, (
        "the position should leave the stranger's hotkey"
    )
    assert env.stake(successor_pubkey, clone_coldkey, netuid) > 0, "the position should sit on the successor"

    receipt, _ = exits.unwrap(
        env, token_id, env.vault_shares(token_id), "Claimed hotkey: the full exit failed", hotkeys=located,
    )
    exits.assert_drained(env, token_id, located, receipt, "Claimed hotkey: full exit")

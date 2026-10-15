"""Scenario: alpha on hotkey 0x0 is reachable.

Subtensor keeps an owner record for the all-zero hotkey, so stake can be put on it and moved
off it like on any other hotkey, and a hotkey swap can carry the vault's backing there. The
vault must not read that key as "no key". A gift to the vault's subnet account on hotkey 0x0
is collected by `recoverStray(tokenId, 0x0)` into live backing, rolling the whole position
through hotkey 0x0 on the real chain, and a mailbox deposit sitting on hotkey 0x0 is reclaimed
by naming hotkey 0x0, in TAO and in alpha. A deposit may still not be wrapped under it.
"""
import pytest

from alpha_e2e import chain, config, exits, extrinsics
from alpha_e2e.extrinsics import UNOWNED_ACCOUNT as ZERO_HOTKEY_SS58
from alpha_e2e.substrate import h160_to_ss58

ZERO_HOTKEY = "0x" + "00" * 32
STAKE_TAO_RAO = 2 * config.RAO_PER_TAO


def _stake_alice_on_zero_hotkey(env, netuid: int) -> int:
    """Buy alpha on hotkey 0x0 for Alice and return how much she holds there."""
    extrinsics.add_stake(ZERO_HOTKEY_SS58, netuid, STAKE_TAO_RAO)
    held = env.stake(ZERO_HOTKEY, config.ALICE_COLDKEY_PUBKEY, netuid)
    assert held > 0, "Alice holds no alpha on hotkey 0 after staking to it"
    return held


@pytest.mark.scenario
def test_backing_and_deposits_on_hotkey_zero_are_reachable(env):
    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    hotkeys = env.subnet_hotkey_pubkeys(0)
    attested_hotkey, attested_ss58 = hotkeys[0], env.hotkey_ss58s[0]
    clone_coldkey = env.clone_coldkey(token_id)

    # As on mainnet: hotkey 0x0 has an owner record, and it is not the vault's.
    extrinsics.associate_hotkey(ZERO_HOTKEY_SS58)
    owner_exists, owner = chain.cast_call_lines(
        config.STAKING_PRECOMPILE, "getHotkeyOwner(bytes32)(bool,bytes32)", ZERO_HOTKEY,
    )
    assert owner_exists == "true", "hotkey 0 has no owner record on this chain"
    assert int(owner, 16) != int(clone_coldkey, 16), "hotkey 0 must not belong to the vault's clone"

    env.deposit_and_wrap(
        netuid, attested_hotkey, attested_ss58, config.DEPOSIT_RAO, 1_500_000, "Zero hotkey: wrap failed",
    )
    backing_before = env.total_stake_across(clone_coldkey, netuid, hotkeys)

    # --- A gift to the vault on hotkey 0x0 is collected into live backing ---------------
    gift = _stake_alice_on_zero_hotkey(env, netuid)
    extrinsics.transfer_stake(h160_to_ss58(env.clone_address(token_id)), ZERO_HOTKEY_SS58, netuid, gift)
    assert env.stake(ZERO_HOTKEY, clone_coldkey, netuid) >= gift - config.ROUNDING_DUST_SLOT_RAO, (
        "the gift did not reach the clone on hotkey 0"
    )
    assert env.backing_intact(token_id), "a stray gift is not a shortfall"

    receipt = env.recover_stray(token_id, ZERO_HOTKEY, "Zero hotkey: recoverStray from hotkey 0 failed")
    block = chain.receipt_block_number(receipt, "Zero hotkey: recoverStray")
    recovered = chain.event_word(receipt, "BackingRecovered(uint256,bytes32,uint256)", 0, "Zero hotkey: recovery")
    assert abs(recovered - gift) <= config.CONSOLIDATION_ROUNDING_TOLERANCE_RAO, (
        f"the vault recovered {recovered} RAO of a {gift} RAO gift"
    )
    assert env.stake(ZERO_HOTKEY, clone_coldkey, netuid, block) <= config.ROUNDING_DUST_SLOT_RAO, (
        "the clone still holds alpha on hotkey 0"
    )
    located = env.total_stake_across(clone_coldkey, netuid, hotkeys, block)
    assert located >= backing_before + gift - config.CONSOLIDATION_ROUNDING_TOLERANCE_RAO, (
        f"the attested keys hold {located} RAO against {backing_before} + {gift}"
    )
    assert env.backing_intact(token_id), "the record follows the collected gift"
    exits.unwrap(
        env, token_id, env.vault_shares(token_id), "Zero hotkey: the full exit failed", hotkeys=hotkeys,
    )

    # --- A mailbox deposit on hotkey 0x0 cannot be wrapped but can be reclaimed ------------
    mailbox_ss58 = h160_to_ss58(env.mailbox_address(netuid))
    mailbox_coldkey = env.mailbox_coldkey(netuid)

    deposit = _stake_alice_on_zero_hotkey(env, netuid)
    extrinsics.transfer_stake(mailbox_ss58, ZERO_HOTKEY_SS58, netuid, deposit)
    assert env.stake(ZERO_HOTKEY, mailbox_coldkey, netuid) >= deposit - config.ROUNDING_DUST_SLOT_RAO, (
        "the deposit did not reach the mailbox on hotkey 0"
    )
    env.assert_vault_reverts_with(
        "ZeroHotkey()", 1_500_000, "Zero hotkey: a wrap must not name hotkey 0",
        "wrap(uint256,bytes32,uint256)", netuid, ZERO_HOTKEY, 0,
    )
    exits.reclaim_mailbox_alpha_as_tao(env, netuid, ZERO_HOTKEY, "Zero hotkey: the mailbox sale from hotkey 0")

    deposit = _stake_alice_on_zero_hotkey(env, netuid)
    extrinsics.transfer_stake(mailbox_ss58, ZERO_HOTKEY_SS58, netuid, deposit)
    reclaim_receipt = env.vault_send_between_epochs(
        netuid, 1_500_000, "Zero hotkey: reclaimAlphaFromMailbox from hotkey 0 failed",
        "reclaimAlphaFromMailbox(uint256,bytes32,bytes32)", netuid, ZERO_HOTKEY, env.wrapper_substrate_coldkey,
    )
    reclaim_block = chain.receipt_block_number(reclaim_receipt, "Zero hotkey: reclaimAlphaFromMailbox")
    released = -env.stake_change(mailbox_coldkey, netuid, [ZERO_HOTKEY], reclaim_block)
    returned = env.stake_change(env.wrapper_substrate_coldkey, netuid, [ZERO_HOTKEY], reclaim_block)
    assert released >= deposit - config.ROUNDING_DUST_SLOT_RAO, (
        f"the mailbox released {released} RAO of a {deposit} RAO deposit"
    )
    assert abs(returned - released) <= config.ROUNDING_DUST_SLOT_RAO, (
        f"the user got back {returned} RAO of the {released} RAO the mailbox released"
    )
    leftover = env.stake(ZERO_HOTKEY, mailbox_coldkey, netuid, reclaim_block)
    assert leftover <= config.ROUNDING_DUST_SLOT_RAO, f"the mailbox still holds {leftover} RAO on hotkey 0"

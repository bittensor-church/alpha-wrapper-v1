"""A stranger cannot grow a clone's staking list; a crumb under a listed validator keeps its entry.

Subtensor lets another coldkey add a hotkey to an account's staking list by transferring
stake onto it, until the list holds 128 entries; after that, transfers onto unlisted hotkeys
are refused. Each clone refuses that growth from the moment it is created, so a stranger
can only top up hotkeys the clone already lists. Deposits land on the mailbox's own hotkey
and reach the clone on a hotkey it lists, with the growth flag lifted for the one transfer
that lands on a clone listing nothing. A candidate dusted before creation is rejected.
Hotkey 0x0, which the localnet owns from genesis, is refused like any other unlisted hotkey.

A crumb sent under a listed validator on another subnet keeps that validator listed after
the registry rotates it out; nothing of the vault's is affected and deposits keep landing.
"""
import secrets
from dataclasses import replace

import pytest

from alpha_e2e import bootstrap, chain, checks, config, exits, extrinsics
from alpha_e2e.extrinsics import UNOWNED_ACCOUNT as ZERO_HOTKEY_SS58
from alpha_e2e.substrate import h160_to_ss58, h160_to_substrate_b32

STRANGER = "//StakingListStranger"
STRANGER_FUNDING_RAO = 20 * config.RAO_PER_TAO
ZERO_HOTKEY = "0x" + "00" * 32


def _uid() -> str:
    return "0x" + secrets.token_hex(32)


def _rejects_growth(address: str) -> bool:
    return chain.cast_call(
        config.STAKING_PRECOMPILE, "getRejectStakingHotkeyGrowth(bytes32)(bool)", h160_to_substrate_b32(address),
    ) == "true"


def _assert_growth_refused(address: str, hotkey_ss58: str, netuid: int, alpha: int) -> None:
    with pytest.raises(extrinsics.ExtrinsicError) as refused:
        extrinsics.transfer_stake(h160_to_ss58(address), hotkey_ss58, netuid, alpha, signer_uri=STRANGER)
    assert "AccountRejectsStakingHotkeyGrowth" in str(refused.value), str(refused.value)


@pytest.mark.scenario
def test_stranger_cannot_grow_a_clones_staking_list(env, recovery_window):
    netuid, other_netuid, _ = env.netuids
    token_id = env.token_ids[0]
    hotkeys = env.subnet_hotkey_pubkeys(0)
    validator, validator_ss58 = hotkeys[0], env.hotkey_ss58s[0]
    stranger_hotkey, stranger_hotkey_ss58 = env.hotkey_pubkeys[3], env.hotkey_ss58s[3]
    stranger_ss58 = extrinsics.keypair_ss58(STRANGER)
    deployment = bootstrap.deploy_contracts([netuid], hotkeys, recovery_window=recovery_window)
    env = replace(
        env, vault_address=deployment.vault_address, lens_address=deployment.lens_address,
        validator_registry_address=deployment.validator_registry_address,
    )

    extrinsics.fund_account(stranger_ss58, STRANGER_FUNDING_RAO)
    extrinsics.add_stake(stranger_hotkey_ss58, other_netuid, 2 * config.RAO_PER_TAO, signer_uri=STRANGER)
    extrinsics.add_stake(validator_ss58, netuid, 2 * config.RAO_PER_TAO, signer_uri=STRANGER)
    extrinsics.add_stake(validator_ss58, other_netuid, 2 * config.RAO_PER_TAO, signer_uri=STRANGER)
    extrinsics.add_stake(ZERO_HOTKEY_SS58, netuid, 2 * config.RAO_PER_TAO, signer_uri=STRANGER)
    _, dust = env.floor_boundary(other_netuid, 2 * env.chain_min_transfer_tao())
    _, gift = env.floor_boundary(netuid, 2 * env.chain_min_transfer_tao())

    poisoned_uid = _uid()
    poisoned_clone, poisoned_mailbox = env.candidate_addresses(token_id, netuid, poisoned_uid)
    for candidate in (poisoned_clone, poisoned_mailbox):
        extrinsics.transfer_stake(
            h160_to_ss58(candidate), stranger_hotkey_ss58, other_netuid, dust, signer_uri=STRANGER,
        )
        assert env.stake(stranger_hotkey, h160_to_substrate_b32(candidate), other_netuid) > 0, "the dust did not land"
    env.assert_vault_reverts_with(
        "CloneContaminated(address)", 2_000_000, "a dusted candidate was accepted",
        "createMailbox(uint256,bytes32)", netuid, poisoned_uid,
    )

    env.vault_send(
        2_000_000, "fresh UID did not prepare protected addresses", "createMailbox(uint256,bytes32)", netuid, _uid(),
    )
    clone = env.clone_address(token_id)
    mailbox = env.mailbox_address(netuid)
    assert clone.lower() != poisoned_clone.lower() and mailbox.lower() != poisoned_mailbox.lower()
    for address, own_entries in ((clone, 0), (mailbox, 1)):
        assert _rejects_growth(address), f"{address} does not refuse staking-list growth"
        assert len(extrinsics.staking_hotkeys(h160_to_ss58(address))) == own_entries, "a fresh clone lists a stranger"
        _assert_growth_refused(address, stranger_hotkey_ss58, other_netuid, dust)
        _assert_growth_refused(address, ZERO_HOTKEY_SS58, netuid, gift)
    env.assert_vault_reverts_with(
        "ZeroHotkey()", 1_500_000, "a wrap must not name hotkey 0",
        "wrap(uint256,bytes32,uint256)", netuid, ZERO_HOTKEY, 0,
    )

    receipt = env.deposit_and_wrap(
        netuid, validator, validator_ss58, config.DEPOSIT_RAO, 1_500_000, "the first wrap failed",
    )
    deposited = env.deposited(receipt, netuid)
    checks.assert_first_deposit_shares(env.vault_shares(token_id), deposited, "first wrap")
    assert env.mailbox_deposit(netuid) <= config.ROUNDING_DUST_SLOT_RAO, "the wrap left the deposit in the mailbox"

    clone_coldkey = env.clone_coldkey(token_id)
    with pytest.raises(extrinsics.ExtrinsicError) as refused:
        extrinsics.transfer_stake_and_hotkey(
            h160_to_ss58(clone), validator_ss58, h160_to_ss58(clone), netuid, gift, signer_uri=STRANGER,
        )
    assert "AccountRejectsStakingHotkeyGrowth" in str(refused.value), "the clone's own hotkey is no landing pad"

    extrinsics.transfer_stake(h160_to_ss58(clone), validator_ss58, other_netuid, dust, signer_uri=STRANGER)
    assert env.stake(validator, clone_coldkey, other_netuid) > 0, "a crumb under a listed validator did not land"
    env.set_validator(netuid, hotkeys[1])
    env.vault_send(4_000_000, "the rotation rebalance failed", "rebalance(uint256)", netuid, label="rebalance [rotate]")
    assert env.stake(validator, clone_coldkey, netuid) <= config.ROUNDING_DUST_SLOT_RAO, "the old validator kept backing"
    assert len(extrinsics.staking_hotkeys(h160_to_ss58(clone))) == 2, "the crumb did not keep the old entry"

    env.deposit_and_wrap(netuid, hotkeys[1], env.hotkey_ss58s[1], config.DEPOSIT_RAO, 1_500_000, "the second wrap failed")
    assert env.stake(validator, clone_coldkey, other_netuid) > 0, "the crumb stays where the stranger put it"
    assert len(extrinsics.staking_hotkeys(h160_to_ss58(clone))) == 2, "the second deposit grew the list"
    for address in (clone, mailbox):
        _assert_growth_refused(address, stranger_hotkey_ss58, other_netuid, dust)

    receipt, _ = exits.unwrap(env, token_id, env.vault_shares(token_id), "the full exit failed", hotkeys=hotkeys)
    exits.assert_drained(env, token_id, hotkeys, receipt, "full exit")
    env.deposit_and_wrap(
        netuid, hotkeys[1], env.hotkey_ss58s[1], config.DEPOSIT_RAO // 10, 1_500_000, "the wrap after a full exit failed",
    )
    assert _rejects_growth(clone), "the flag is down after a wrap"
    assert env.stake(stranger_hotkey, h160_to_substrate_b32(poisoned_clone), other_netuid) > 0, (
        "rejected dust never entered backing"
    )

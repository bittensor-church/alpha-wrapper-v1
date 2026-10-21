"""A stranger cannot grow a clone's staking list, before or after creation.

Subtensor lets another coldkey add a hotkey to an account's staking list by transferring
stake onto it, until the list holds 128 entries; after that, transfers onto unlisted hotkeys
are refused. A mailbox or subnet clone with a full list could never take a deposit onto a
new hotkey. Each clone refuses that growth from the moment it is created, and deposits
travel over hotkeys the clones own, which the chain admits whatever the list holds. A
candidate dusted before creation is rejected, so the window before the flag is set cannot
be used either.
"""
import secrets
from dataclasses import replace

import pytest

from alpha_e2e import bootstrap, chain, checks, config, exits, extrinsics
from alpha_e2e.substrate import h160_to_ss58, h160_to_substrate_b32

STRANGER = "//StakingListStranger"
STRANGER_FUNDING_RAO = 20 * config.RAO_PER_TAO


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
    _, dust = env.floor_boundary(other_netuid, env.chain_min_stake_tao())
    _, gift = env.floor_boundary(netuid, 2 * env.chain_min_stake_tao())

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
    for address in (clone, mailbox):
        assert _rejects_growth(address), f"{address} does not refuse staking-list growth"
        assert len(extrinsics.staking_hotkeys(h160_to_ss58(address))) == 1, "a fresh clone lists only its own hotkey"
        _assert_growth_refused(address, stranger_hotkey_ss58, other_netuid, dust)

    receipt = env.deposit_and_wrap(
        netuid, validator, validator_ss58, config.DEPOSIT_RAO, 1_500_000, "the first wrap failed",
    )
    deposited = env.deposited(receipt, netuid)
    checks.assert_first_deposit_shares(env.vault_shares(token_id), deposited, "first wrap")
    assert env.mailbox_deposit(netuid) <= config.ROUNDING_DUST_SLOT_RAO, "the wrap left the deposit in the mailbox"

    clone_coldkey = env.clone_coldkey(token_id)
    backing_before = env.total_stake_across(clone_coldkey, netuid, hotkeys)
    extrinsics.transfer_stake_and_hotkey(
        h160_to_ss58(clone), validator_ss58, h160_to_ss58(clone), netuid, gift, signer_uri=STRANGER,
    )
    recover_receipt = env.recover_stray(token_id, clone_coldkey, "collecting the gift on the clone's own hotkey failed")
    recovered = chain.event_word(recover_receipt, "BackingRecovered(uint256,bytes32,uint256)", 0, "gift recovery")
    assert abs(recovered - gift) <= config.CONSOLIDATION_ROUNDING_TOLERANCE_RAO, (
        f"the vault recovered {recovered} RAO of a {gift} RAO gift"
    )
    assert env.total_stake_across(clone_coldkey, netuid, hotkeys) >= (
        backing_before + gift - config.CONSOLIDATION_ROUNDING_TOLERANCE_RAO
    ), "the collected gift did not join the backing"

    env.deposit_and_wrap(netuid, validator, validator_ss58, config.DEPOSIT_RAO, 1_500_000, "the second wrap failed")
    # A drain can leave one RAO behind, which keeps an own hotkey listed beside the attested one.
    assert len(extrinsics.staking_hotkeys(h160_to_ss58(clone))) <= 2, "the clone lists a stranger's hotkey"
    assert len(extrinsics.staking_hotkeys(h160_to_ss58(mailbox))) <= 1, "the mailbox lists a stranger's hotkey"
    for address in (clone, mailbox):
        _assert_growth_refused(address, stranger_hotkey_ss58, other_netuid, dust)

    receipt, _ = exits.unwrap(env, token_id, env.vault_shares(token_id), "the full exit failed", hotkeys=hotkeys)
    exits.assert_drained(env, token_id, hotkeys, receipt, "full exit")
    assert env.stake(stranger_hotkey, h160_to_substrate_b32(poisoned_clone), other_netuid) > 0, (
        "rejected dust never entered backing"
    )

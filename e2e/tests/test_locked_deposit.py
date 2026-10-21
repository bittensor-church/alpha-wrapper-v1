"""Creation rejects contaminated candidates and leaves accepted clones nothing a swap can target.

A fresh vault is used so the scenario can poison the first candidates on the subnet.
Stake and conviction can sit on different hotkeys; neither may be imported into
accepted backing through a poisoned candidate. A fresh UID selects a clean candidate.
"""
import secrets
from dataclasses import replace

import pytest

from alpha_e2e import bootstrap, chain, checks, config, exits, extrinsics
from alpha_e2e.substrate import h160_to_account_id, h160_to_ss58, h160_to_substrate_b32

SWAP_DELAY_BLOCKS = 5
CLONE_DONOR = "//CloneCandidateDonor"
MAILBOX_DONOR = "//MailboxCandidateDonor"
SWAP_DONOR = "//PostDeploymentSwapDonor"
LOCKED_HOLDER = "//LockedHolder"
SWAP_REFUSALS = ("NewColdKeyIsHotkey", "ColdKeyAlreadyAssociated")


def _uid() -> str:
    return "0x" + secrets.token_hex(32)


def _swap_into(signer_uri: str, destination: str) -> None:
    extrinsics.announce_coldkey_swap(h160_to_account_id(destination), signer_uri=signer_uri)
    maturity_blocks = SWAP_DELAY_BLOCKS + 2
    chain.wait_for_blocks(maturity_blocks, timeout=maturity_blocks * config.BLOCK_TIMEOUT_SECONDS)
    extrinsics.swap_coldkey_announced(h160_to_ss58(destination), signer_uri=signer_uri)


def _protected(env, address: str, owner_coldkey: str) -> None:
    coldkey = h160_to_substrate_b32(address)
    owner = chain.cast_call_lines(
        config.STAKING_PRECOMPILE, "getHotkeyOwner(bytes32)(bool,bytes32)", coldkey,
    )
    assert owner[0] == "true", "the clone's account is a hotkey"
    assert owner[1].lower() == owner_coldkey.lower(), "the clone's account answers to the wrong owner"
    owned = chain.cast_call(config.STAKING_PRECOMPILE, "getOwnedHotkeys(bytes32)(bytes32[])", owner_coldkey)
    assert owned.strip("[]").lower() == coldkey.lower(), "the owner owns the clone's account and nothing else"
    assert chain.cast_call(
        config.STAKING_PRECOMPILE, "getRejectLockedAlpha(bytes32)(bool)", coldkey,
    ) == "true"
    assert chain.cast_call(
        config.STAKING_PRECOMPILE, "getRejectStakingHotkeyGrowth(bytes32)(bool)", coldkey,
    ) == "true"


@pytest.mark.scenario
def test_locked_deposit(env, recovery_window):
    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    hotkey = env.hotkey_pubkeys[0]
    hotkey_ss58 = env.hotkey_ss58s[0]
    gift_hotkey = env.hotkey_pubkeys[-1]
    gift_hotkey_ss58 = env.hotkey_ss58s[-1]
    assert gift_hotkey != hotkey, "scenario needs a gift key outside the first subnet's attested set"
    deployment = bootstrap.deploy_contracts([netuid], env.subnet_hotkey_pubkeys(0), recovery_window=recovery_window)
    env = replace(
        env, vault_address=deployment.vault_address, lens_address=deployment.lens_address,
        validator_registry_address=deployment.validator_registry_address,
    )
    extrinsics.set_coldkey_swap_announcement_delay(SWAP_DELAY_BLOCKS)
    for uri in (CLONE_DONOR, MAILBOX_DONOR, SWAP_DONOR, LOCKED_HOLDER):
        extrinsics.fund_account(extrinsics.keypair_ss58(uri), 30 * 10**9)
    for uri in (CLONE_DONOR, MAILBOX_DONOR, LOCKED_HOLDER):
        extrinsics.set_reject_locked_alpha(False, signer_uri=uri)
        extrinsics.add_stake(gift_hotkey_ss58, netuid, 20 * 10**9, signer_uri=uri)
        alpha = env.stake(gift_hotkey, extrinsics.keypair_pubkey(uri), netuid)
        extrinsics.lock_stake(hotkey_ss58, netuid, alpha, signer_uri=uri)
        extrinsics.set_perpetual_lock(netuid, True, signer_uri=uri)

    poisoned_uid = _uid()
    poisoned_clone, _ = env.candidate_addresses(token_id, netuid, poisoned_uid)
    _swap_into(CLONE_DONOR, poisoned_clone)
    assert env.stake(gift_hotkey, h160_to_substrate_b32(poisoned_clone), netuid) > 0
    env.assert_vault_reverts_with(
        "CloneContaminated(address)", 2_000_000, "contaminated subnet candidate was accepted",
        "createMailbox(uint256,bytes32)", netuid, poisoned_uid,
    )

    mailbox_uid = _uid()
    _, poisoned_mailbox = env.candidate_addresses(token_id, netuid, mailbox_uid)
    _swap_into(MAILBOX_DONOR, poisoned_mailbox)
    env.assert_vault_reverts_with(
        "CloneContaminated(address)", 2_000_000, "contaminated mailbox candidate was accepted",
        "createMailbox(uint256,bytes32)", netuid, mailbox_uid,
    )

    env.vault_send(
        2_000_000, "fresh UID did not prepare protected addresses", "createMailbox(uint256,bytes32)",
        netuid, _uid(),
    )
    clone = env.clone_address(token_id)
    mailbox = env.mailbox_address(netuid)
    assert clone.lower() != poisoned_clone.lower()
    assert mailbox.lower() != poisoned_mailbox.lower()
    vault_coldkey = h160_to_substrate_b32(env.vault_address)
    clone_owner = env.clone_owner(token_id)
    assert clone_owner.lower() != vault_coldkey.lower(), "the vault must not own a subnet clone's hotkey"
    assert len(extrinsics.staking_hotkeys(h160_to_ss58(env.vault_address))) == 1, "the vault lists parking only"
    _protected(env, clone, clone_owner)
    _protected(env, mailbox, h160_to_substrate_b32(mailbox))
    for address in (clone, mailbox):
        assert env.stake(hotkey, h160_to_substrate_b32(address), netuid) == 0
    extrinsics.associate_hotkey(h160_to_ss58(clone), signer_uri=LOCKED_HOLDER)
    _protected(env, clone, clone_owner)
    print("  A stranger's association attempt leaves the clone's owner untouched")
    env.vault_send(2_000_000, "idempotent creation failed", "createMailbox(uint256,bytes32)", netuid, _uid())
    assert env.clone_address(token_id) == clone
    assert env.mailbox_address(netuid) == mailbox

    extrinsics.fund_account(h160_to_ss58(clone), 10**9)
    with pytest.raises(extrinsics.ExtrinsicError) as refused:
        _swap_into(SWAP_DONOR, clone)
    assert any(reason in str(refused.value) for reason in SWAP_REFUSALS), str(refused.value)

    locked_alpha = env.stake(gift_hotkey, extrinsics.keypair_pubkey(LOCKED_HOLDER), netuid)
    for destination, refusal in ((mailbox, "AccountRejectsLockedAlpha"), (clone, "AccountRejectsStakingHotkeyGrowth")):
        with pytest.raises(extrinsics.ExtrinsicError) as refused:
            extrinsics.transfer_stake_and_hotkey(
                h160_to_ss58(destination), gift_hotkey_ss58, h160_to_ss58(destination), netuid, locked_alpha // 2,
                signer_uri=LOCKED_HOLDER,
            )
        assert refusal in str(refused.value), str(refused.value)

    receipt = env.deposit_and_wrap(
        netuid, hotkey, hotkey_ss58, 10 * config.RAO_PER_ALPHA, 1_500_000, "honest wrap failed",
    )
    deposited = env.deposited(receipt, netuid)
    assert deposited >= 10 * config.RAO_PER_ALPHA - config.ROUNDING_DUST_SLOT_RAO, (
        f"the honest wrap collected {deposited} RAO of 10 alpha"
    )
    with pytest.raises(extrinsics.ExtrinsicError) as refused:
        extrinsics.transfer_stake_and_hotkey(
            h160_to_ss58(clone), gift_hotkey_ss58, hotkey_ss58, netuid, locked_alpha // 2, signer_uri=LOCKED_HOLDER,
        )
    assert "AccountRejectsLockedAlpha" in str(refused.value), "a listed validator still refuses locked alpha"
    checks.assert_first_deposit_shares(env.vault_shares(token_id), deposited, "honest wrap on a fresh vault")
    receipt, received = exits.unwrap(
        env, token_id, env.vault_shares(token_id), "honest exit failed", hotkeys=env.subnet_hotkey_pubkeys(0),
    )
    assert received >= deposited - config.ROUNDING_DUST_TOTAL_RAO, (
        f"the honest exit returned {received} RAO of a {deposited} RAO deposit"
    )
    assert env.vault_shares(token_id) == 0
    exits.assert_drained(env, token_id, env.subnet_hotkey_pubkeys(0), receipt, "honest exit")
    assert env.stake(gift_hotkey, h160_to_substrate_b32(poisoned_clone), netuid) > 0, "rejected gift never entered backing"
    _protected(env, clone, clone_owner)

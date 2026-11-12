"""Creation rejects contaminated candidates and leaves accepted clones nothing a swap can target.

A fresh vault is used so the scenario can poison the first candidates on the subnet.
Stake and conviction can sit on different hotkeys; neither may be imported into
accepted backing through a poisoned candidate. A fresh UID selects a clean candidate,
whose clone and mailbox are each a hotkey (a mailbox its own, a subnet clone its owner
contract's), so a coldkey swap into them is refused at execution, the owner contract
refuses one that would grow its staking list, and both refuse locked alpha. An honest
deposit still wraps and exits.
"""
import pytest

from alpha_e2e import bootstrap, chain, checks, config, exits, extrinsics
from alpha_e2e.environment import random_bytes32
from alpha_e2e.substrate import h160_to_account_id, h160_to_ss58, h160_to_substrate_b32

SWAP_DELAY_BLOCKS = 5
CLONE_DONOR = "//CloneCandidateDonor"
MAILBOX_DONOR = "//MailboxCandidateDonor"
SWAP_DONOR = "//PostDeploymentSwapDonor"
OWNER_SWAP_DONOR = "//CloneOwnerSwapDonor"
LOCKED_HOLDER = "//LockedHolder"


def _announce_swap_into(signer_uri: str, destination: str) -> None:
    extrinsics.announce_coldkey_swap_and_wait(h160_to_account_id(destination), SWAP_DELAY_BLOCKS, signer_uri=signer_uri)


def _swap_into(signer_uri: str, destination: str) -> None:
    _announce_swap_into(signer_uri, destination)
    extrinsics.swap_coldkey_announced(h160_to_ss58(destination), signer_uri=signer_uri)


def _assert_swap_refused(signer_uri: str, destination: str, refusal: str) -> None:
    _announce_swap_into(signer_uri, destination)
    with pytest.raises(extrinsics.ExtrinsicError) as refused:
        extrinsics.swap_coldkey_announced(h160_to_ss58(destination), signer_uri=signer_uri)
    assert refusal in str(refused.value), f"the swap into {destination} should fail with {refusal}: {refused.value}"


def _assert_protected(address: str, owner_coldkey: str) -> None:
    coldkey = h160_to_substrate_b32(address)
    owner = chain.cast_call_lines(
        config.STAKING_PRECOMPILE, "getHotkeyOwner(bytes32)(bool,bytes32)", coldkey,
    )
    assert owner[0] == "true", f"{address}'s account should be a hotkey"
    assert owner[1].lower() == owner_coldkey.lower(), f"{address}'s account answers to the wrong owner"
    owned = chain.cast_call(config.STAKING_PRECOMPILE, "getOwnedHotkeys(bytes32)(bytes32[])", owner_coldkey)
    assert owned.strip("[]").lower() == coldkey.lower(), f"the owner should own {address}'s account and nothing else"
    assert chain.cast_call(
        config.STAKING_PRECOMPILE, "getRejectLockedAlpha(bytes32)(bool)", coldkey,
    ) == "true", f"{address} should refuse locked alpha"
    assert chain.cast_call(
        config.STAKING_PRECOMPILE, "getRejectStakingHotkeyGrowth(bytes32)(bool)", coldkey,
    ) == "true", f"{address} should refuse staking-list growth"


@pytest.mark.scenario
def test_poisoned_candidates_are_refused_and_accepted_clones_refuse_swaps_and_locked_alpha(env, recovery_window):
    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    hotkey = env.subnet_hotkey_pubkeys(0)[0]
    hotkey_ss58 = env.subnet_hotkey_ss58s(0)[0]
    gift_hotkey = env.subnet_hotkey_pubkeys(2)[-1]
    gift_hotkey_ss58 = env.subnet_hotkey_ss58s(2)[-1]
    env = bootstrap.redeploy(env, 0, recovery_window)
    extrinsics.set_coldkey_swap_announcement_delay(SWAP_DELAY_BLOCKS)
    for uri in (CLONE_DONOR, MAILBOX_DONOR, SWAP_DONOR, OWNER_SWAP_DONOR, LOCKED_HOLDER):
        extrinsics.fund_account(extrinsics.keypair_ss58(uri), 30 * config.RAO_PER_TAO)
    extrinsics.add_stake(gift_hotkey_ss58, netuid, 2 * config.RAO_PER_TAO, signer_uri=OWNER_SWAP_DONOR)
    for uri in (CLONE_DONOR, MAILBOX_DONOR, LOCKED_HOLDER):
        extrinsics.set_reject_locked_alpha(False, signer_uri=uri)
        extrinsics.add_stake(gift_hotkey_ss58, netuid, 20 * config.RAO_PER_TAO, signer_uri=uri)
        alpha = env.stake(gift_hotkey, extrinsics.keypair_pubkey(uri), netuid)
        extrinsics.lock_stake(hotkey_ss58, netuid, alpha, signer_uri=uri)
        extrinsics.set_perpetual_lock(netuid, True, signer_uri=uri)

    poisoned_uid = random_bytes32()
    poisoned_clone, _ = env.candidate_addresses(token_id, netuid, poisoned_uid)
    _swap_into(CLONE_DONOR, poisoned_clone)
    assert env.stake(gift_hotkey, h160_to_substrate_b32(poisoned_clone), netuid) > 0, (
        "the donor's swap should have carried its stake onto the clone candidate"
    )
    env.assert_vault_reverts_with(
        "CloneContaminated(address)", 3_000_000, "contaminated subnet candidate was accepted",
        "createMailbox(uint256,bytes32)", netuid, poisoned_uid, error_args=(poisoned_clone,),
    )

    mailbox_uid = random_bytes32()
    _, poisoned_mailbox = env.candidate_addresses(token_id, netuid, mailbox_uid)
    _swap_into(MAILBOX_DONOR, poisoned_mailbox)
    env.assert_vault_reverts_with(
        "CloneContaminated(address)", 3_000_000, "contaminated mailbox candidate was accepted",
        "createMailbox(uint256,bytes32)", netuid, mailbox_uid, error_args=(poisoned_mailbox,),
    )

    env.vault_send(
        2_000_000, "fresh UID did not prepare protected addresses", "createMailbox(uint256,bytes32)",
        netuid, random_bytes32(),
    )
    clone = env.clone_address(token_id)
    mailbox = env.mailbox_address(netuid)
    assert clone.lower() != poisoned_clone.lower(), "the fresh UID should prepare another clone"
    assert mailbox.lower() != poisoned_mailbox.lower(), "the fresh UID should prepare another mailbox"
    vault_coldkey = h160_to_substrate_b32(env.vault_address)
    clone_owner = env.clone_owner(token_id)
    assert clone_owner.lower() != vault_coldkey.lower(), "the vault must not own a subnet clone's hotkey"
    assert len(extrinsics.staking_hotkeys(h160_to_ss58(env.vault_address))) == 1, "the vault lists parking only"
    _assert_protected(clone, clone_owner)
    _assert_protected(mailbox, h160_to_substrate_b32(mailbox))
    for address in (clone, mailbox):
        assert env.stake(hotkey, h160_to_substrate_b32(address), netuid) == 0, f"{address} should start with no stake"
    extrinsics.associate_hotkey(h160_to_ss58(clone), signer_uri=LOCKED_HOLDER)
    _assert_protected(clone, clone_owner)
    print("  A stranger's association attempt leaves the clone's owner untouched")
    env.vault_send(2_000_000, "idempotent creation failed", "createMailbox(uint256,bytes32)", netuid, random_bytes32())
    assert env.clone_address(token_id) == clone, "a second creation should keep the clone"
    assert env.mailbox_address(netuid) == mailbox, "a second creation should keep the mailbox"

    extrinsics.fund_account(h160_to_ss58(clone), config.RAO_PER_TAO)
    _assert_swap_refused(SWAP_DONOR, clone, "NewColdKeyIsHotkey")

    owner_contract = env.clone_owner_address(token_id)
    assert h160_to_substrate_b32(owner_contract).lower() == clone_owner.lower(), (
        "the factory's owner contract should be the coldkey that owns the clone's account"
    )
    _assert_swap_refused(OWNER_SWAP_DONOR, owner_contract, "AccountRejectsStakingHotkeyGrowth")
    assert len(extrinsics.staking_hotkeys(h160_to_ss58(owner_contract))) == 1, (
        "the swap grew the owner contract's staking list"
    )

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
    assert 10 * config.RAO_PER_ALPHA - config.ROUNDING_DUST_SLOT_RAO <= deposited <= 10 * config.RAO_PER_ALPHA, (
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
    assert env.vault_shares(token_id) == 0, "shares left after the honest exit"
    exits.assert_drained(env, token_id, env.subnet_hotkey_pubkeys(0), receipt, "honest exit")
    assert env.stake(gift_hotkey, h160_to_substrate_b32(poisoned_clone), netuid) > 0, "rejected gift never entered backing"
    _assert_protected(clone, clone_owner)

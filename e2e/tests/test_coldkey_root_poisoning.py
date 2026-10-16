"""A stranger poisons a validator coldkey's lineage root; the watcher and registry owner recover the slot.

The chain lets anyone swap a coldkey into one that stakes under no hotkey. The validator's
coldkey owns the approved hotkey, charges no take and holds no alpha, so a stranger's swap into
it goes through and rewrites the root. The vault refuses the validator until the registry owner
re-approves, and the re-approval records the stranger's root. When the validator later swaps its
hotkey away, the stranger claims the vacated name and, the position being empty, receives the
next deposit, then swaps that hotkey away and the vault loses sight of the alpha. The watcher
parks it with `recoverStray`, the registry owner publishes the validator's real key, and the
holder exits in full. A gift of alpha to the validator's coldkey puts it back on a staking list,
and the chain refuses the next stranger's swap. Every step is an ordinary extrinsic or vault
call; the only privileged action shortens the swap announcement delay.
"""
import pytest

from alpha_e2e import chain, config, exits, extrinsics, incidents
from alpha_e2e.substrate import h160_to_ss58

VALIDATOR_URI = "//PoisonedValidator"
VALIDATOR_HOTKEY_URI = "//PoisonedValidatorHotkey"
VALIDATOR_NEXT_HOTKEY_URI = "//PoisonedValidatorNextHotkey"
STRANGER_URI = "//RootPoisoner"
STRANGER_HOTKEY_URI = "//RootPoisonerHotkey"
SECOND_STRANGER_URI = "//SecondRootPoisoner"
SWAP_DELAY_BLOCKS = 5
FUNDING_RAO = 50 * config.RAO_PER_TAO
ALICE_STAKE_RAO = config.VALIDATOR_STAKE_TAO[0] * config.RAO_PER_TAO
VALIDATOR_OWN_STAKE_RAO = 1 * config.RAO_PER_TAO
GIFT_RAO = config.RAO_PER_ALPHA
ALREADY_REGISTERED = "HotKeyAlreadyRegisteredInSubNet"


def _register(hotkey_ss58: str, netuid: int, signer_uri: str) -> None:
    refusal = None
    for _ in (1, 2, 3):
        try:
            extrinsics.burned_register(hotkey_ss58, netuid, signer_uri=signer_uri)
            return
        except extrinsics.ExtrinsicError as error:
            if ALREADY_REGISTERED in str(error):
                return
            refusal = error
        chain.wait_for_blocks(1, timeout=config.BLOCK_TIMEOUT_SECONDS)
    raise RuntimeError(f"register failed on netuid {netuid} after 3 attempts: {refusal}")


def _staking_hotkey_count(coldkey_pubkey: str) -> int:
    lines = chain.cast_call_lines(
        config.STAKING_PRECOMPILE, "getStakingHotkeys(bytes32,uint64,uint16)(bytes32[],uint64)",
        coldkey_pubkey, 0, 64,
    )
    return int(lines[1])


def _coldkey_root(coldkey_pubkey: str):
    exists, root = chain.cast_call_lines(
        config.STAKING_PRECOMPILE, "getColdkeyRoot(bytes32)(bool,bytes32)", coldkey_pubkey,
    )
    return exists == "true", root.lower()


def _recorded_owner_root(env, netuid: int) -> str:
    lines = chain.cast_call_lines(
        env.validator_registry_address, "getValidators(uint256)(bytes32[],uint16[],bytes32[])", netuid,
    )
    return lines[2].strip("[]").lower()


@pytest.mark.scenario
def test_stranger_holds_deposits_until_the_watcher_parks_and_the_owner_republishes(env):
    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    validator_ss58 = extrinsics.keypair_ss58(VALIDATOR_URI)
    validator_pubkey = extrinsics.keypair_pubkey(VALIDATOR_URI)
    hotkey_ss58 = extrinsics.keypair_ss58(VALIDATOR_HOTKEY_URI)
    hotkey_pubkey = extrinsics.keypair_pubkey(VALIDATOR_HOTKEY_URI)
    next_hotkey_ss58 = extrinsics.keypair_ss58(VALIDATOR_NEXT_HOTKEY_URI)
    next_hotkey_pubkey = extrinsics.keypair_pubkey(VALIDATOR_NEXT_HOTKEY_URI)
    stranger_ss58 = extrinsics.keypair_ss58(STRANGER_URI)
    stranger_pubkey = extrinsics.keypair_pubkey(STRANGER_URI)
    stranger_hotkey_ss58 = extrinsics.keypair_ss58(STRANGER_HOTKEY_URI)
    stranger_hotkey_pubkey = extrinsics.keypair_pubkey(STRANGER_HOTKEY_URI)

    extrinsics.fund_account(validator_ss58, FUNDING_RAO)
    extrinsics.fund_account(stranger_ss58, FUNDING_RAO)
    _register(hotkey_ss58, netuid, VALIDATOR_URI)
    assert extrinsics.hotkey_owner(hotkey_ss58) == validator_ss58
    extrinsics.decrease_take(hotkey_ss58, 0, signer_uri=VALIDATOR_URI)
    assert _staking_hotkey_count(validator_pubkey) == 1, "registration lists the hotkey under its owner"
    extrinsics.add_stake(hotkey_ss58, netuid, ALICE_STAKE_RAO)
    env.set_validator(netuid, hotkey_pubkey)
    assert _recorded_owner_root(env, netuid) == validator_pubkey.lower()

    env.deposit_and_wrap(
        netuid, hotkey_pubkey, hotkey_ss58, config.DEPOSIT_RAO, 1_500_000, "Poisoning: setup wrap failed",
    )
    shares = env.vault_shares(token_id)
    clone_coldkey = env.clone_coldkey(token_id)
    assert env.stake(hotkey_pubkey, clone_coldkey, netuid) > 0, "the vault holds alpha under the hotkey"

    extrinsics.add_stake(hotkey_ss58, netuid, VALIDATOR_OWN_STAKE_RAO, signer_uri=VALIDATOR_URI)
    own_alpha = env.stake(hotkey_pubkey, validator_pubkey, netuid)
    assert own_alpha > 0
    extrinsics.remove_stake(hotkey_ss58, netuid, own_alpha, signer_uri=VALIDATOR_URI)
    assert env.stake(hotkey_pubkey, validator_pubkey, netuid) == 0
    assert _staking_hotkey_count(validator_pubkey) == 0, (
        "with no alpha of its own the validator coldkey has no staking hotkeys"
    )

    extrinsics.set_coldkey_swap_announcement_delay(SWAP_DELAY_BLOCKS)
    extrinsics.announce_coldkey_swap(bytes.fromhex(validator_pubkey[2:]), signer_uri=STRANGER_URI)
    maturity_blocks = SWAP_DELAY_BLOCKS + 2
    chain.wait_for_blocks(maturity_blocks, timeout=maturity_blocks * config.BLOCK_TIMEOUT_SECONDS)
    assert env.stake(hotkey_pubkey, validator_pubkey, netuid) == 0, "no take accrued to the zero-take validator"
    assert _staking_hotkey_count(validator_pubkey) == 0, "the validator coldkey is still an eligible destination"
    extrinsics.swap_coldkey_announced(validator_ss58, signer_uri=STRANGER_URI)
    assert _coldkey_root(validator_pubkey) == (True, stranger_pubkey.lower()), "the stranger rewrote the root"
    assert extrinsics.hotkey_owner(hotkey_ss58) == validator_ss58, "the hotkey still belongs to the validator"
    assert env.stake(hotkey_pubkey, clone_coldkey, netuid) > 0, "the vault's alpha did not move"

    env.assert_vault_reverts_with(
        "AttestedHotkeyRetired(bytes32)", 2_500_000,
        "Poisoning: the vault should refuse the validator after the root changed",
        "rebalance(uint256)", netuid,
    )

    env.set_validator(netuid, hotkey_pubkey)
    assert _recorded_owner_root(env, netuid) == stranger_pubkey.lower(), (
        "re-approval records the stranger's root as the approved owner"
    )
    env.vault_send(2_500_000, "Poisoning: rebalance after re-approval failed", "rebalance(uint256)", netuid)

    extrinsics.swap_hotkey(hotkey_ss58, next_hotkey_ss58, signer_uri=VALIDATOR_URI)
    assert extrinsics.hotkey_owner(hotkey_ss58) == "", "the approved name is left without an owner"
    assert env.stake(next_hotkey_pubkey, clone_coldkey, netuid) > 0, "the vault's alpha followed the swap"
    env.vault_send(2_500_000, "Poisoning: rebalance after the hotkey swap failed", "rebalance(uint256)", netuid)

    extrinsics.fund_account(stranger_ss58, FUNDING_RAO)
    extrinsics.associate_hotkey(hotkey_ss58, signer_uri=STRANGER_URI)
    assert extrinsics.hotkey_owner(hotkey_ss58) == stranger_ss58, "the stranger holds the approved name"
    extrinsics.add_stake(hotkey_ss58, netuid, ALICE_STAKE_RAO)

    exits.unwrap_for_tao(
        env, token_id, shares, "Poisoning: the TAO exit failed", hotkeys=[next_hotkey_pubkey],
    )
    assert env.vault_shares(token_id) == 0
    assert env.stake(next_hotkey_pubkey, clone_coldkey, netuid) == 0, "the TAO exit empties the slot"

    extrinsics.fund_account(h160_to_ss58(config.SECOND_HOLDER_ADDRESS), 10 * config.RAO_PER_TAO)
    env.deposit_and_wrap(
        netuid, hotkey_pubkey, hotkey_ss58, config.DEPOSIT_RAO, 1_500_000,
        "Poisoning: the next deposit failed",
        user=config.SECOND_HOLDER_ADDRESS, private_key=config.SECOND_HOLDER_PRIVATE_KEY,
    )
    on_stranger_key = env.stake(hotkey_pubkey, clone_coldkey, netuid)
    assert on_stranger_key >= config.DEPOSIT_RAO - config.ROUNDING_DUST_TOTAL_RAO, (
        "the vault put the new deposit on the hotkey the stranger owns"
    )
    assert env.stake(next_hotkey_pubkey, clone_coldkey, netuid) == 0, "and nothing on the validator's real key"
    assert extrinsics.hotkey_owner(hotkey_ss58) == stranger_ss58
    assert env.backing_intact(token_id), "the vault sees nothing wrong"

    extrinsics.swap_hotkey(hotkey_ss58, stranger_hotkey_ss58, signer_uri=STRANGER_URI)
    assert env.stake(stranger_hotkey_pubkey, clone_coldkey, netuid) >= on_stranger_key, (
        "the stranger's hotkey swap carried the users' alpha"
    )
    assert not env.backing_intact(token_id), "the vault cannot find the alpha after the stranger's swap"
    env.assert_vault_reverts_with(
        "BackingShortfall(uint16,bytes32,uint256)", 1_500_000,
        "Poisoning: priced operations should refuse while the alpha is unlocated",
        "rebalance(uint256)", netuid,
    )

    stranding = incidents.Stranding(
        hotkey_pubkey, hotkey_ss58, stranger_hotkey_pubkey, stranger_hotkey_ss58, stranger_ss58, on_stranger_key,
    )
    parked = incidents.park(env, token_id, stranding, "Poisoning")
    assert env.stake(stranger_hotkey_pubkey, clone_coldkey, netuid) <= config.ROUNDING_DUST_SLOT_RAO, (
        "the watcher moved the alpha off the stranger's key"
    )

    env.set_validator(netuid, next_hotkey_pubkey)
    assert _recorded_owner_root(env, netuid) == stranger_pubkey.lower(), (
        "the validator's lineage keeps the root the stranger gave it"
    )
    env.vault_send(
        4_000_000, "Poisoning: the release rebalance failed", "rebalance(uint256)", netuid,
        label="rebalance [release parked]",
    )
    assert env.stake(env.parking_hotkey(), clone_coldkey, netuid) <= config.ROUNDING_DUST_SLOT_RAO, (
        "the parking hotkey should be empty after the release"
    )
    assert env.stake(next_hotkey_pubkey, clone_coldkey, netuid) >= parked - config.CONSOLIDATION_ROUNDING_TOLERANCE_RAO, (
        "the validator's real key carries the recovered alpha"
    )
    assert env.backing_intact(token_id), "the record follows the new set"

    extrinsics.transfer_stake(validator_ss58, next_hotkey_ss58, netuid, GIFT_RAO)
    assert _staking_hotkey_count(validator_pubkey) == 1, "a gift of alpha puts the coldkey on a staking list"
    second_stranger_ss58 = extrinsics.keypair_ss58(SECOND_STRANGER_URI)
    extrinsics.fund_account(second_stranger_ss58, FUNDING_RAO)
    extrinsics.announce_coldkey_swap(bytes.fromhex(validator_pubkey[2:]), signer_uri=SECOND_STRANGER_URI)
    chain.wait_for_blocks(maturity_blocks, timeout=maturity_blocks * config.BLOCK_TIMEOUT_SECONDS)
    with pytest.raises(extrinsics.ExtrinsicError) as refused:
        extrinsics.swap_coldkey_announced(validator_ss58, signer_uri=SECOND_STRANGER_URI)
    assert "ColdKeyAlreadyAssociated" in str(refused.value), str(refused.value)
    assert _coldkey_root(validator_pubkey) == (True, stranger_pubkey.lower()), "the refused swap left the root alone"
    env.vault_send(2_500_000, "Poisoning: rebalance after the refused swap failed", "rebalance(uint256)", netuid)

    exits.unwrap_for_tao(
        env, token_id, env.vault_shares(token_id, holder=config.SECOND_HOLDER_ADDRESS),
        "Poisoning: the holder's exit after recovery failed", hotkeys=[next_hotkey_pubkey],
        holder=config.SECOND_HOLDER_ADDRESS, private_key=config.SECOND_HOLDER_PRIVATE_KEY,
    )
    assert env.vault_shares(token_id, holder=config.SECOND_HOLDER_ADDRESS) == 0

"""A validator swaps its coldkey; the vault keeps allocating to it with no new attestation.

The validator's hotkey keeps its name and the vault's alpha stays under the clone's
coldkey, but the chain now reports a different owner for the hotkey. The registry
recorded the owner's lineage root at attestation and the chain gives the new coldkey
that same root, so wraps, rebalances and partial exits continue. The registry nonce
never moves.
"""
import pytest

from alpha_e2e import chain, config, extrinsics

VALIDATOR_URI = "//LineageValidator"
VALIDATOR_HOTKEY_URI = "//LineageValidatorHotkey"
NEXT_COLDKEY_URI = "//LineageValidatorNext"
SWAP_DELAY_BLOCKS = 5
VALIDATOR_FUNDING_RAO = 50 * config.RAO_PER_TAO
ALICE_STAKE_RAO = config.VALIDATOR_STAKE_TAO[0] * config.RAO_PER_TAO
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


def _coldkey_root(coldkey_pubkey: str):
    exists, root = chain.cast_call_lines(
        config.STAKING_PRECOMPILE, "getColdkeyRoot(bytes32)(bool,bytes32)", coldkey_pubkey,
    )
    return exists == "true", root.lower()


def _registry_nonce(env, netuid: int) -> int:
    return int(chain.cast_call(env.validator_registry_address, "nonces(uint256)(uint256)", netuid))


@pytest.mark.scenario
def test_wraps_continue_after_the_validator_swaps_its_coldkey(env):
    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    validator_ss58 = extrinsics.keypair_ss58(VALIDATOR_URI)
    validator_pubkey = extrinsics.keypair_pubkey(VALIDATOR_URI)
    hotkey_ss58 = extrinsics.keypair_ss58(VALIDATOR_HOTKEY_URI)
    hotkey_pubkey = extrinsics.keypair_pubkey(VALIDATOR_HOTKEY_URI)
    next_ss58 = extrinsics.keypair_ss58(NEXT_COLDKEY_URI)
    next_pubkey = extrinsics.keypair_pubkey(NEXT_COLDKEY_URI)

    extrinsics.fund_account(validator_ss58, VALIDATOR_FUNDING_RAO)
    _register(hotkey_ss58, netuid, VALIDATOR_URI)
    assert extrinsics.hotkey_owner(hotkey_ss58) == validator_ss58, "the validator owns its hotkey"
    extrinsics.add_stake(hotkey_ss58, netuid, ALICE_STAKE_RAO)
    env.set_validator(netuid, hotkey_pubkey)
    nonce = _registry_nonce(env, netuid)

    env.deposit_and_wrap(
        netuid, hotkey_pubkey, hotkey_ss58,
        config.DEPOSIT_RAO, 1_500_000, "Lineage: wrap before the swap failed",
    )
    shares = env.vault_shares(token_id)
    assert shares > 0, "no shares minted by the setup wrap"
    clone_coldkey = env.clone_coldkey(token_id)
    staked_before = env.stake(hotkey_pubkey, clone_coldkey, netuid)
    assert staked_before > 0, "the setup wrap left nothing on the validator's hotkey"

    extrinsics.set_coldkey_swap_announcement_delay(SWAP_DELAY_BLOCKS)
    extrinsics.announce_coldkey_swap(bytes.fromhex(next_pubkey[2:]), signer_uri=VALIDATOR_URI)
    maturity_blocks = SWAP_DELAY_BLOCKS + 2
    chain.wait_for_blocks(maturity_blocks, timeout=maturity_blocks * config.BLOCK_TIMEOUT_SECONDS)
    extrinsics.swap_coldkey_announced(next_ss58, signer_uri=VALIDATOR_URI)

    assert extrinsics.hotkey_owner(hotkey_ss58) == next_ss58, "the hotkey answers to the new coldkey"
    assert _coldkey_root(next_pubkey) == (True, validator_pubkey.lower()), (
        "the chain links the new coldkey to the one the registry recorded"
    )
    assert env.stake(hotkey_pubkey, clone_coldkey, netuid) >= staked_before, "the vault's alpha did not move"
    assert env.backing_intact(token_id), "a coldkey swap is not a loss"

    env.vault_send(2_500_000, "Lineage: rebalance after the swap failed", "rebalance(uint256)", netuid)
    env.deposit_and_wrap(
        netuid, hotkey_pubkey, hotkey_ss58,
        config.DEPOSIT_RAO // 2, 1_500_000, "Lineage: wrap after the swap failed",
    )
    assert env.vault_shares(token_id) > shares, "the second wrap minted nothing"
    env.vault_send(
        2_500_000, "Lineage: partial exit after the swap failed",
        "unwrap(uint256,uint256,bytes32,uint256)", token_id, shares // 2, env.wrapper_substrate_coldkey, 1,
    )

    assert _registry_nonce(env, netuid) == nonce, "no new attestation was needed"
    assert not env.awaiting_attestation(token_id)
    assert env.backing_intact(token_id)

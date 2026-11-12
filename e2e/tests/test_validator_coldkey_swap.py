"""A validator swaps its coldkey; the vault keeps allocating to it with no new attestation.

The validator's hotkey stays the same and the vault's alpha stays under the clone's
coldkey, while the chain now reports a different owner for the hotkey. Wraps,
rebalances and partial exits continue at the position's own rate and the registry
nonce never moves.
"""
import pytest

from alpha_e2e import bootstrap, chain, checks, config, exits, extrinsics

VALIDATOR_URI = "//RotatingValidator"
VALIDATOR_HOTKEY_URI = "//RotatingValidatorHotkey"
NEXT_COLDKEY_URI = "//RotatingValidatorNext"
SWAP_DELAY_BLOCKS = 5
VALIDATOR_FUNDING_RAO = 50 * config.RAO_PER_TAO
ALICE_STAKE_RAO = config.VALIDATOR_STAKE_TAO[0] * config.RAO_PER_TAO


@pytest.mark.scenario
def test_wraps_continue_after_the_validator_swaps_its_coldkey(env):
    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    validator_ss58 = extrinsics.keypair_ss58(VALIDATOR_URI)
    hotkey_ss58 = extrinsics.keypair_ss58(VALIDATOR_HOTKEY_URI)
    hotkey_pubkey = extrinsics.keypair_pubkey(VALIDATOR_HOTKEY_URI)
    next_ss58 = extrinsics.keypair_ss58(NEXT_COLDKEY_URI)
    next_pubkey = extrinsics.keypair_pubkey(NEXT_COLDKEY_URI)

    extrinsics.fund_account(validator_ss58, VALIDATOR_FUNDING_RAO)
    bootstrap.burned_register_with_retry(hotkey_ss58, netuid, signer_uri=VALIDATOR_URI)
    assert extrinsics.hotkey_owner(hotkey_ss58) == validator_ss58, "the validator owns its hotkey"
    extrinsics.add_stake(hotkey_ss58, netuid, ALICE_STAKE_RAO)
    env.set_validator(netuid, hotkey_pubkey)
    nonce = env.registry_nonce(netuid)

    receipt = env.deposit_and_wrap(
        netuid, hotkey_pubkey, hotkey_ss58,
        config.DEPOSIT_RAO, 1_500_000, "Coldkey swap: wrap before the swap failed",
    )
    shares = env.vault_shares(token_id)
    checks.assert_first_deposit_shares(shares, env.deposited(receipt, netuid), "Coldkey swap: wrap before the swap")
    clone_coldkey = env.clone_coldkey(token_id)
    staked_before = env.stake(hotkey_pubkey, clone_coldkey, netuid)
    assert staked_before > 0, "the setup wrap left nothing on the validator's hotkey"

    extrinsics.set_coldkey_swap_announcement_delay(SWAP_DELAY_BLOCKS)
    extrinsics.announce_coldkey_swap_and_wait(bytes.fromhex(next_pubkey[2:]), SWAP_DELAY_BLOCKS, signer_uri=VALIDATOR_URI)
    extrinsics.swap_coldkey_announced(next_ss58, signer_uri=VALIDATOR_URI)

    assert extrinsics.hotkey_owner(hotkey_ss58) == next_ss58, "the hotkey answers to the new coldkey"
    assert env.stake(hotkey_pubkey, clone_coldkey, netuid) >= staked_before, "the vault's alpha did not move"
    assert env.backing_intact(token_id), "a coldkey swap is not a loss"

    held = [hotkey_pubkey]
    receipt = env.vault_send_between_epochs(
        netuid, 2_500_000, "Coldkey swap: rebalance after the swap failed", "rebalance(uint256)", netuid,
    )
    moved = env.stake_change(clone_coldkey, netuid, held, chain.receipt_block_number(receipt, "Coldkey swap: rebalance"))
    assert moved == 0, f"a rebalance onto the same one validator should move nothing, moved {moved}"
    receipt = env.deposit_and_wrap(
        netuid, hotkey_pubkey, hotkey_ss58,
        config.DEPOSIT_RAO // 2, 1_500_000, "Coldkey swap: wrap after the swap failed",
    )
    checks.assert_wrap_kept_value_per_share(env, token_id, receipt, held, "Coldkey swap: wrap after the swap")
    exits.unwrap(env, token_id, shares // 2, "Coldkey swap: partial exit after the swap failed", hotkeys=held)

    assert env.registry_nonce(netuid) == nonce, "no new attestation was needed"
    assert not env.awaiting_attestation(token_id), "a coldkey swap should not park the position"
    assert env.backing_intact(token_id), "the position should stay whole through the coldkey swap"

"""Sub-floor deposits require a top-up; a later deposit consolidates dust from a rotated-out validator."""
import pytest

from alpha_e2e import config, extrinsics
from alpha_e2e.checks import assert_gas_within
from alpha_e2e.substrate import h160_to_ss58


@pytest.mark.scenario
def test_min_stake_floor(env):
    chain_min_stake = env.chain_min_stake_tao()
    print(f"  chain minimum stake = {chain_min_stake} RAO")

    # --- Leg 1: the wrap gate refuses a sub-floor deposit up front ---------------
    # The chain floors moving a deposit onward far below what it floors an unstake at, and exposes
    # no getter for the lower bar, so the vault applies the readable one everywhere and refuses
    # deposits the chain would in fact have taken. What this leg tests is that the refusal is cheap
    # and correctly labelled - not that a doomed chain call was avoided.
    gate_netuid = env.netuids[0]
    gate_hotkey_pubkey = env.hotkey_pubkeys[0]
    gate_hotkey_ss58 = env.hotkey_ss58s[0]

    gate_price, gate_boundary = env.floor_boundary(gate_netuid, chain_min_stake)
    # Two of these park below the boundary individually but clear it together.
    sub_floor_alpha = gate_boundary * 2 // 3
    print(f"  Alpha price={gate_price} -> floor boundary={gate_boundary} alpha RAO, "
          f"parking {sub_floor_alpha}")

    gate_mailbox = env.mailbox_address(gate_netuid)
    try:
        extrinsics.transfer_stake(
            h160_to_ss58(gate_mailbox), gate_hotkey_ss58, gate_netuid, sub_floor_alpha,
        )
    except extrinsics.ExtrinsicError as error:
        raise AssertionError(
            "Floor gate: parking transfer refused - the deposit must sit between the "
            f"chain's parking bar and its minimum stake ({sub_floor_alpha} alpha = 2/3 "
            "of the boundary); has either moved past this test's sizing?"
        ) from error

    gate_refusal_receipt = env.assert_vault_reverts_with(
        "DepositTooSmall()", 1_500_000,
        "Floor gate: sub-floor wrap did NOT revert as DepositTooSmall",
        "wrap(uint256,bytes32,uint256)", gate_netuid, gate_hotkey_pubkey, 0,
    )
    assert_gas_within(
        gate_refusal_receipt, config.REVERT_GAS_BOUND, "Floor gate: sub-floor wrap refusal",
    )
    print("  wrap refused a deposit below the chain minimum as DepositTooSmall, "
          "without burning the gas budget")

    extrinsics.transfer_stake(
        h160_to_ss58(gate_mailbox), gate_hotkey_ss58, gate_netuid, sub_floor_alpha,
    )
    env.vault_send(
        1_500_000, "Floor gate: above-floor wrap failed",
        "wrap(uint256,bytes32,uint256)", gate_netuid, gate_hotkey_pubkey, 0,
    )
    print("  wrap accepted the deposit once it cleared the minimum")

    # --- Leg 2: rotated-out dust is consolidated by the next wrap ------------------
    # The next wrap's fresh deposit starts the roller, so deposit and dust roll over the
    # chain floor in one transaction - no keeper, no forfeiture.
    dust_netuid = env.netuids[2]
    dust_token_id = env.token_ids[2]
    dust_hotkey_pubkey = env.hotkey_pubkeys[6]
    dust_hotkey_ss58 = env.hotkey_ss58s[6]
    kept_hotkey_b_pubkey = env.hotkey_pubkeys[7]
    kept_hotkey_b_ss58 = env.hotkey_ss58s[7]

    dust_price, dust_boundary = env.floor_boundary(dust_netuid, chain_min_stake)
    dust_deposit = dust_boundary * 3 // 2
    env.deposit_and_wrap(
        dust_netuid, dust_hotkey_pubkey, dust_hotkey_ss58, dust_deposit,
        1_500_000, "Dust consolidation: wrap failed",
    )

    dust_shares = env.vault_shares(dust_token_id)
    dust_clone_coldkey = env.clone_coldkey(dust_token_id)

    # Delivers ~1.25x the boundary and leaves ~0.25x of it behind as sub-floor dust.
    dust_burn = dust_shares * 5 // 6
    env.vault_send(
        2_500_000, "Dust consolidation: partial unwrap failed",
        "unwrap(uint256,uint256,bytes32,uint256)",
        dust_token_id, dust_burn, env.wrapper_substrate_coldkey, 1,
    )
    dust_residue = env.stake(dust_hotkey_pubkey, dust_clone_coldkey, dust_netuid)
    assert dust_residue * dust_price // config.ALPHA_PRICE_SCALE < chain_min_stake, (
        f"Dust consolidation: residual {dust_residue} is not sub-floor (price {dust_price})"
    )
    print(f"  Left sub-floor dust of {dust_residue} alpha RAO under the "
          "soon-rotated hotkey")

    env.set_validator(dust_netuid, kept_hotkey_b_pubkey)
    dust_total_before = env.vault_total_stake(dust_token_id)
    consolidating_deposit = dust_boundary * 3
    env.deposit_and_wrap(
        dust_netuid, kept_hotkey_b_pubkey, kept_hotkey_b_ss58, consolidating_deposit,
        2_500_000, "Dust consolidation: consolidating wrap failed",
    )

    dust_residue_after = env.stake(dust_hotkey_pubkey, dust_clone_coldkey, dust_netuid)
    assert dust_residue_after <= config.ROUNDING_DUST_SLOT_RAO, (
        f"Dust consolidation: rotated dust NOT consolidated "
        f"({dust_residue_after} > {config.ROUNDING_DUST_SLOT_RAO})"
    )
    print(f"  Next wrap consolidated the rotated dust: rotated-out hotkey left with "
          f"{dust_residue_after} RAO")

    assert not env.hotkey_in_last_seen(dust_token_id, dust_hotkey_pubkey), (
        "Dust consolidation: consolidated hotkey still present in lastSeenHotkeys"
    )
    dust_total_after = env.vault_total_stake(dust_token_id)
    assert dust_total_after >= (
        dust_total_before + consolidating_deposit - config.CONSOLIDATION_ROUNDING_TOLERANCE_RAO
    ), (
        f"Dust consolidation: backing did not fold in deposit + reclaimed dust "
        f"({dust_total_after})"
    )
    print("  Backing folded in the fresh deposit and the reclaimed dust; "
          "remembered set refreshed to the current set")

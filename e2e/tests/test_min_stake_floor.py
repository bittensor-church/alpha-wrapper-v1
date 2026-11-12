"""A deposit just under the floor waits for a top-up; a later deposit consolidates dust from a rotated-out validator.

The vault applies the chain's unstake minimum to deposits, which the chain moves at a lower bar,
so a mailbox can hold alpha a tenth under the floor: the wrap refuses it cheaply and leaves it in
the mailbox, and a top-up to a tenth over the floor wraps it as a first deposit. On another subnet,
a partial exit leaves sub-floor dust under the attested validator; once the registry rotates that
validator out, the next deposit carries the dust onto the new one.
"""
import pytest

from alpha_e2e import chain, checks, config, exits, extrinsics


@pytest.mark.scenario
def test_deposit_below_the_floor_waits_for_a_top_up_and_rotated_out_dust_consolidates(env):
    floor = env.chain_min_stake_tao()
    print(f"  vault floor = {floor} RAO")

    gate_netuid = env.netuids[0]
    gate_token_id = env.token_ids[0]
    gate_hotkey_pubkey = env.subnet_hotkey_pubkeys(0)[0]
    gate_hotkey_ss58 = env.subnet_hotkey_ss58s(0)[0]

    gate_price, gate_boundary = env.floor_boundary(gate_netuid, floor)
    below_floor_alpha = gate_boundary * 9 // 10
    top_up_alpha = gate_boundary * 2 // 10
    print(f"  Alpha price={gate_price} -> floor boundary={gate_boundary} alpha RAO, "
          f"parking {below_floor_alpha}, topping up {top_up_alpha}")

    try:
        env.send_to_mailbox(gate_netuid, gate_hotkey_ss58, below_floor_alpha)
    except extrinsics.ExtrinsicError as error:
        raise AssertionError(
            "Floor gate: parking transfer refused - the deposit must sit between the "
            f"chain's transfer minimum and the vault's floor ({below_floor_alpha} alpha = 9/10 "
            "of the boundary); has either moved past this test's sizing?"
        ) from error
    parked = env.mailbox_deposit(gate_netuid)

    gate_refusal_receipt = env.assert_vault_reverts_with(
        "DepositTooSmall()", 1_500_000,
        "Floor gate: a wrap a tenth under the floor did NOT revert as DepositTooSmall",
        "wrap(uint256,bytes32,uint256)", gate_netuid, gate_hotkey_pubkey, 0,
    )
    refusal_block = chain.receipt_block_number(gate_refusal_receipt, "Floor gate: refusal")
    assert env.mailbox_deposit(gate_netuid, block=refusal_block) == parked, (
        "the refused wrap should leave the deposit in the mailbox"
    )
    print("  wrap refused a deposit a tenth under the floor as DepositTooSmall, "
          "without burning the gas budget")

    env.send_to_mailbox(gate_netuid, gate_hotkey_ss58, top_up_alpha)
    receipt = env.wrap(gate_netuid, gate_hotkey_pubkey, 1_500_000, "Floor gate: the wrap a tenth over the floor failed")
    checks.assert_first_deposit_shares(
        env.vault_shares(gate_token_id), env.deposited(receipt, gate_netuid), "Floor gate: topped-up wrap",
    )
    print("  wrap accepted the deposit once the top-up cleared the minimum")

    dust_netuid = env.netuids[2]
    dust_token_id = env.token_ids[2]
    dust_hotkeys = env.subnet_hotkey_pubkeys(2)
    dust_hotkey_pubkey, kept_hotkey_b_pubkey = dust_hotkeys[:2]
    dust_hotkey_ss58, kept_hotkey_b_ss58 = env.subnet_hotkey_ss58s(2)[:2]

    _, dust_boundary = env.floor_boundary(dust_netuid, floor)
    env.deposit_and_wrap(
        dust_netuid, dust_hotkey_pubkey, dust_hotkey_ss58, dust_boundary * 3 // 2,
        1_500_000, "Dust consolidation: wrap failed",
    )

    dust_shares = env.vault_shares(dust_token_id)
    dust_clone_coldkey = env.clone_coldkey(dust_token_id)

    # Delivers ~1.25x the boundary and leaves ~0.25x of it behind as sub-floor dust.
    exits.unwrap(
        env, dust_token_id, dust_shares * 5 // 6, "Dust consolidation: partial unwrap failed", hotkeys=dust_hotkeys,
    )
    dust_residue = env.stake(dust_hotkey_pubkey, dust_clone_coldkey, dust_netuid)
    assert env.alpha_value_tao(dust_netuid, dust_residue) < floor, (
        f"Dust consolidation: residual {dust_residue} alpha RAO is not sub-floor"
    )
    print(f"  Left sub-floor dust of {dust_residue} alpha RAO under the "
          "soon-rotated hotkey")

    env.set_validator(dust_netuid, kept_hotkey_b_pubkey)
    receipt = env.deposit_and_wrap(
        dust_netuid, kept_hotkey_b_pubkey, kept_hotkey_b_ss58, dust_boundary * 3,
        2_500_000, "Dust consolidation: consolidating wrap failed",
    )
    consolidating_deposit = env.deposited(receipt, dust_netuid)
    wrap_block = chain.receipt_block_number(receipt, "Dust consolidation: consolidating wrap")

    dust_residue_after = env.stake(dust_hotkey_pubkey, dust_clone_coldkey, dust_netuid, wrap_block)
    assert dust_residue_after <= config.ROUNDING_DUST_SLOT_RAO, (
        f"Dust consolidation: rotated dust NOT consolidated "
        f"({dust_residue_after} > {config.ROUNDING_DUST_SLOT_RAO})"
    )
    print(f"  Next wrap consolidated the rotated dust: rotated-out hotkey left with "
          f"{dust_residue_after} RAO")

    assert not env.hotkey_in_last_seen(dust_token_id, dust_hotkey_pubkey, block=wrap_block), (
        "Dust consolidation: consolidated hotkey still present in lastSeenHotkeys"
    )
    landed = env.stake_change(dust_clone_coldkey, dust_netuid, dust_hotkeys, wrap_block)
    assert abs(landed - consolidating_deposit) <= config.ROUNDING_DUST_TOTAL_RAO, (
        f"Dust consolidation: the clone gained {landed} RAO from a {consolidating_deposit} RAO deposit "
        "while folding in its own dust"
    )
    print("  Backing folded in the fresh deposit and the reclaimed dust; "
          "remembered set refreshed to the current set")

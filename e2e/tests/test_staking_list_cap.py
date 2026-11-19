"""Walks a subnet clone's staking list to the last entry the vault lets it take, syncs there and replaces the clone.

Each round attests a fresh validator and rebalances onto it, which lists it, then sends a
crumb under it on another subnet, which keeps its entry once the next round rotates it
out. The last round attests a pair. The vault stops its own growth one entry short of its
96-entry cap, kept for the parking hotkey.

A stranger then gives the clone ten piles under rotated-out validators, and the pair's
validator swaps one attested hotkey onto the other on this subnet, so two slots share one
pile and the position reads short. Every stake move on chain walks the clone's whole
staking list, so this is the costliest list the vault allows a sync on: it collects the
merged pile and the ten strays onto the parking hotkey and must stay within the gas the
runbook quotes. The registry then names a fresh validator, and a rebalance and a deposit
onto it revert `StakingListFull`. `replaceClone` moves the parked position and all of the
clone's TAO to a fresh clone that lists only the parking hotkey, the deposit lands,
carrying the parked pile onto the fresh validator, and the token exits in full.

Gas rows: deposit and `previewUnwrap` on the fresh clone; deposit, partial exit and
`previewUnwrap` on the full list; the sync; the replacement; deposit, `previewUnwrap` and
full exit on the successor.
"""
import pytest

from alpha_e2e import bootstrap, chain, config, exits, extrinsics
from alpha_e2e.environment import random_bytes32
from alpha_e2e.substrate import h160_to_ss58

STRANGER = "//CapStranger"
OWNER = "//CapOwner"
VAULT_CAP = 96
PARKING_RESERVE = 1
STRAYS = 10
EQUAL_WEIGHTS = [5_000, 5_000]
# docs/recovery.md: what one stake move and one list read cost on chain.
MOVE_GAS = 75_000
MOVE_GAS_PER_ENTRY = 8_750
LIST_READ_GAS_PER_ENTRY = 6_000
# The vault's own bookkeeping around the moves.
VAULT_OVERHEAD_GAS = 2_000_000


@pytest.mark.scenario
def test_list_reaches_the_cap_syncs_there_and_replacement_reopens_it(env, recovery_window):
    env = bootstrap.redeploy(env, 0, recovery_window, weighted_registry=True)
    netuid, other_netuid, _ = env.netuids
    token_id = env.token_ids[0]
    first_validator, first_validator_ss58 = env.subnet_hotkey_pubkeys(0)[0], env.subnet_hotkey_ss58s(0)[0]
    own_entries = VAULT_CAP - PARKING_RESERVE
    rounds = own_entries - 3
    validators = [
        (extrinsics.keypair_pubkey(f"{STRANGER}//{i}"), extrinsics.keypair_ss58(f"{STRANGER}//{i}"))
        for i in range(rounds + 3)
    ]
    (swapped, swapped_ss58), (merged_onto, merged_onto_ss58) = validators[rounds:rounds + 2]
    spare, _ = validators[rounds + 2]
    parking_hotkey = env.parking_hotkey()

    def listed(address: str) -> int:
        return len(extrinsics.staking_hotkeys(h160_to_ss58(address)))

    def preview_gas(tag: str) -> None:
        chain.report_view_gas(
            f"previewUnwrap [{tag}]", env.lens_address, "previewUnwrap(uint256,uint256)",
            token_id, env.vault_shares(token_id),
        )

    env.deposit_and_wrap(
        netuid, first_validator, first_validator_ss58, config.DEPOSIT_RAO, 1_500_000,
        "Cap, fresh clone: wrap failed",
    )
    clone = env.clone_address(token_id)
    clone_ss58 = h160_to_ss58(clone)
    preview_gas("Cap, fresh clone")
    extrinsics.fund_account(extrinsics.keypair_ss58(STRANGER), 30 * config.RAO_PER_TAO)
    extrinsics.fund_account(extrinsics.keypair_ss58(OWNER), 5 * config.RAO_PER_TAO)
    extrinsics.associate_hotkeys([ss58 for _, ss58 in validators], signer_uri=OWNER)
    extrinsics.add_stakes(
        [first_validator_ss58] + [ss58 for _, ss58 in validators[:rounds + 2]], other_netuid,
        2 * env.chain_min_stake_tao(), signer_uri=STRANGER,
    )
    _, crumb = env.floor_boundary(other_netuid, 2 * env.chain_min_transfer_tao())
    extrinsics.transfer_stake(clone_ss58, first_validator_ss58, other_netuid, crumb, signer_uri=STRANGER)

    for i in range(rounds):
        pubkey, ss58 = validators[i]
        env.set_validator(netuid, pubkey)
        env.vault_send(4_000_000, f"Cap: rebalance onto validator {i} failed", "rebalance(uint256)", netuid)
        extrinsics.transfer_stake(clone_ss58, ss58, other_netuid, crumb, signer_uri=STRANGER)
        if (i + 1) % 32 == 0:
            print(f"  {i + 1} validators rotated; the clone lists {listed(clone)} hotkeys")
    env.set_validators(netuid, [swapped, merged_onto], EQUAL_WEIGHTS)
    env.vault_send(4_000_000, "Cap: rebalance onto the last pair failed", "rebalance(uint256)", netuid)
    for ss58 in (swapped_ss58, merged_onto_ss58):
        extrinsics.transfer_stake(clone_ss58, ss58, other_netuid, crumb, signer_uri=STRANGER)
    assert listed(clone) == own_entries, f"the clone lists {listed(clone)} hotkeys, expected the last admitted entry"

    held = [first_validator] + [pubkey for pubkey, _ in validators[:rounds + 2]]
    env.send_to_mailbox(netuid, first_validator_ss58, config.DEPOSIT_RAO)
    env.wrap(netuid, merged_onto, 2_500_000, "Cap, full list: the deposit onto the listed validator failed")
    preview_gas("Cap, full list")
    exits.unwrap(
        env, token_id, env.vault_shares(token_id) // 4, "Cap, full list: the partial exit failed", hotkeys=held,
        gas_limit=4_000_000,
    )

    old_coldkey = env.clone_coldkey(token_id)
    strays = validators[:STRAYS]
    _, gift = env.floor_boundary(netuid, 3 * env.chain_min_stake_tao())
    extrinsics.add_stakes(
        [ss58 for _, ss58 in strays], netuid, 10 * env.chain_min_stake_tao(), signer_uri=STRANGER,
    )
    for pubkey, ss58 in strays:
        extrinsics.transfer_stake(clone_ss58, ss58, netuid, gift, signer_uri=STRANGER)
        assert env.stake(pubkey, old_coldkey, netuid) >= gift, "the gift did not land under the listed validator"
    extrinsics.swap_hotkey_on_subnet(swapped_ss58, merged_onto_ss58, netuid, signer_uri=OWNER)
    assert env.stake(swapped, old_coldkey, netuid) == 0, "the swap should empty the swapped hotkey"
    assert listed(clone) == own_entries, "the crumb keeps the swapped hotkey listed, so the list stays full"
    assert not env.backing_intact(token_id), "one pile cannot account for two slots"

    receipt = env.vault_send_between_epochs(
        netuid, 40_000_000, "Cap: syncBacking failed", "syncBacking(uint256)", token_id,
        label="syncBacking [Cap, ten strays]",
    )
    sync_block = chain.receipt_block_number(receipt, "Cap: sync")
    collected = [swapped, merged_onto] + [pubkey for pubkey, _ in strays]
    moves = STRAYS + 1
    held_before = env.total_stake_across(old_coldkey, netuid, collected, sync_block - 1)
    parked = env.stake(parking_hotkey, old_coldkey, netuid, sync_block)
    assert abs(parked - held_before) <= moves * config.ROUNDING_DUST_SLOT_RAO, (
        f"the sync should park the merged pile and the ten strays, {held_before} alpha RAO, parked {parked}"
    )
    left = env.total_stake_across(old_coldkey, netuid, collected, sync_block)
    assert left <= moves * config.ROUNDING_DUST_SLOT_RAO, f"{left} alpha RAO stayed behind under collected hotkeys"
    assert env.write_off_deadline(token_id) == 0, "the sync should finish recovery in the same call"
    assert env.awaiting_attestation(token_id), "the position should wait for the registry owner"
    assert listed(clone) == VAULT_CAP, "parking should take the entry kept for it"
    gas_used = chain.receipt_gas_used(receipt)
    assert gas_used is not None, f"the sync's receipt carries no gasUsed: {receipt}"
    quoted = (
        moves * (MOVE_GAS + MOVE_GAS_PER_ENTRY * VAULT_CAP)
        + 2 * VAULT_CAP * LIST_READ_GAS_PER_ENTRY
        + VAULT_OVERHEAD_GAS
    )
    assert gas_used <= quoted, (
        f"the sync used {gas_used} gas for {moves} moves on a full list; the runbook quotes {quoted}"
    )

    env.set_validator(netuid, spare)
    env.assert_vault_reverts_with(
        "StakingListFull()", 4_000_000, "Cap: a rebalance onto an unlisted validator should hit the cap",
        "rebalance(uint256)", netuid,
    )
    env.send_to_mailbox(netuid, first_validator_ss58, config.DEPOSIT_RAO)
    env.assert_vault_reverts_with(
        "StakingListFull()", 1_500_000, "Cap: a deposit onto an unlisted validator should hit the cap",
        "wrap(uint256,bytes32,uint256)", netuid, spare, 0,
    )

    shares = env.vault_shares(token_id)
    tao_before = chain.cast_balance_wei(clone)
    assert tao_before == 0, f"the clone should hold no TAO before it is funded, holds {tao_before} wei"
    extrinsics.fund_account(h160_to_ss58(clone), config.RAO_PER_TAO)
    tao_shown = chain.cast_balance_wei(clone)
    assert tao_shown == (config.RAO_PER_TAO - config.EXISTENTIAL_DEPOSIT_RAO) * config.WEI_PER_RAO, (
        f"a fresh account shows 1 TAO less the existential deposit, the clone shows {tao_shown} wei"
    )
    receipt = env.replace_clone(token_id, random_bytes32(), "Cap: replacing the clone failed")
    replace_block = chain.receipt_block_number(receipt, "Cap: replacement")
    successor = env.clone_address(token_id)
    assert successor.lower() != clone.lower(), "the token has no fresh clone"
    successor_coldkey = env.clone_coldkey(token_id)
    assert chain.cast_balance_wei(clone) == 0, "the old clone kept TAO"
    assert chain.cast_balance_wei(successor) == tao_shown, "the successor shows a different TAO balance"
    assert env.vault_shares(token_id) == shares, "shares changed with the clone"
    assert listed(successor) == 1, f"the successor lists {listed(successor)} hotkeys, expected the parking hotkey"
    pile = env.stake(parking_hotkey, old_coldkey, netuid, replace_block - 1)
    moved = env.stake(parking_hotkey, successor_coldkey, netuid, replace_block)
    assert abs(moved - pile) <= config.ROUNDING_DUST_SLOT_RAO, f"the successor took {moved} alpha RAO of a {pile} RAO pile"
    left = env.stake(parking_hotkey, old_coldkey, netuid, replace_block)
    assert left <= config.ROUNDING_DUST_SLOT_RAO, f"the old clone kept {left} alpha RAO of the parked pile"
    quoted_stake = env.vault_total_stake(token_id, block=replace_block)
    assert quoted_stake == moved, f"the quote prices {quoted_stake} alpha RAO; the successor holds {moved}"

    receipt = env.wrap(netuid, spare, 2_500_000, "Cap, successor: the deposit should land once the list has room")
    wrap_block = chain.receipt_block_number(receipt, "Cap, successor: deposit")
    deposited = env.deposited(receipt, netuid)
    landed = env.stake_change(successor_coldkey, netuid, [parking_hotkey, spare], wrap_block)
    assert abs(landed - deposited) <= config.ROUNDING_DUST_TOTAL_RAO, (
        f"the successor gained {landed} alpha RAO from a {deposited} RAO deposit"
    )
    parked_after = env.stake(parking_hotkey, successor_coldkey, netuid, wrap_block)
    assert parked_after <= config.ROUNDING_DUST_SLOT_RAO, (
        f"the deposit should carry the parked pile onto the fresh validator, {parked_after} RAO stayed behind"
    )
    assert listed(clone) == own_entries, "the crumbs keep every validator's entry on the old clone"
    preview_gas("Cap, successor")

    receipt, _ = exits.unwrap(
        env, token_id, env.vault_shares(token_id), "Cap, successor: the full exit failed",
        hotkeys=[parking_hotkey, spare],
    )
    exits.assert_drained(env, token_id, [parking_hotkey, spare], receipt, "Cap, successor: full exit")

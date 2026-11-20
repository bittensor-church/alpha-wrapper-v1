"""A validator swaps its hotkey onto the one another validator vacated; one `syncBacking` parks the position whole.

The registry attests two validators' hotkeys at 60% and 40%. The 40% validator swaps its hotkey on
every subnet, which carries that pile to a successor and leaves the hotkey without an owner. The
60% validator then swaps its own hotkey onto the vacated one on this subnet, which the chain allows
for a hotkey nobody owns. The record now finds the larger pile under the smaller slot's hotkey, and
the smaller pile under the successor cannot cover the larger slot, so the position reads short
although the clone still holds all of it. One `syncBacking` collects both piles from the clone's
staking list onto the parking hotkey and finishes recovery in the same call: no recovery window
opens and nothing is written off. Both exits pay from the parking hotkey, a registry set naming
the hotkeys the two validators now hold releases the position, deposits resume and the holder
exits whole.
"""
import pytest

from alpha_e2e import bootstrap, chain, checks, config, exits, extrinsics, incidents

LARGER_VALIDATOR_URI = "//CrossLargerValidator"
LARGER_HOTKEY_URI = "//CrossLargerHotkey"
SMALLER_SUCCESSOR_URI = "//CrossSmallerSuccessor"
LARGER_VALIDATOR_FUNDING_RAO = 2 * config.RAO_PER_TAO
WEIGHTS = [6_000, 4_000]


@pytest.mark.scenario
def test_one_sync_parks_a_slot_swapped_onto_another_slots_vacated_hotkey(env, recovery_window):
    env = bootstrap.redeploy(env, 0, recovery_window, weighted_registry=True)
    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    smaller = env.subnet_hotkey_pubkeys(0)[0]
    smaller_ss58 = env.subnet_hotkey_ss58s(0)[0]
    larger = extrinsics.keypair_pubkey(LARGER_HOTKEY_URI)
    larger_ss58 = extrinsics.keypair_ss58(LARGER_HOTKEY_URI)
    larger_validator_ss58 = extrinsics.keypair_ss58(LARGER_VALIDATOR_URI)
    parking_hotkey = env.parking_hotkey()

    extrinsics.fund_account(larger_validator_ss58, LARGER_VALIDATOR_FUNDING_RAO)
    extrinsics.associate_hotkey(larger_ss58, signer_uri=LARGER_VALIDATOR_URI)
    assert extrinsics.hotkey_owner(larger_ss58) == larger_validator_ss58, (
        "the second validator's coldkey should own the 60% hotkey"
    )
    env.set_validators(netuid, [larger, smaller], WEIGHTS)

    receipt = env.deposit_and_wrap(
        netuid, smaller, smaller_ss58, config.DEPOSIT_RAO, 2_500_000, "Cross-assigned slots: wrap failed",
    )
    clone_coldkey = env.clone_coldkey(token_id)
    wrap_block = chain.receipt_block_number(receipt, "Cross-assigned slots: wrap")
    deposited = env.deposited(receipt, netuid)
    larger_pile = env.stake(larger, clone_coldkey, netuid, wrap_block)
    smaller_pile = env.stake(smaller, clone_coldkey, netuid, wrap_block)
    for pile, weight in ((larger_pile, 6), (smaller_pile, 4)):
        checks.assert_pro_rata(
            pile, deposited, weight, 10, config.CONSOLIDATION_ROUNDING_TOLERANCE_RAO,
            "Cross-assigned slots: each slot should hold its weight of the deposit",
        )

    stranding = incidents.swap_validator_hotkey(env, 0, 0, SMALLER_SUCCESSOR_URI, "Cross-assigned slots")
    successor = stranding.successor_pubkey
    assert env.backing_intact(token_id), "a plain swap is followed and is not a loss"

    extrinsics.swap_hotkey_on_subnet(larger_ss58, smaller_ss58, netuid, signer_uri=LARGER_VALIDATOR_URI)
    assert extrinsics.hotkey_owner(smaller_ss58) == larger_validator_ss58, (
        "the 60% validator should now own the vacated hotkey"
    )
    assert env.stake(larger, clone_coldkey, netuid) == 0, "the swap should empty the 60% hotkey"
    assert env.stake(smaller, clone_coldkey, netuid) >= larger_pile - config.ROUNDING_DUST_SLOT_RAO, (
        "the 60% pile should sit under the vacated hotkey"
    )
    stranded = env.stake(successor, clone_coldkey, netuid)
    assert smaller_pile - config.ROUNDING_DUST_SLOT_RAO <= stranded < larger_pile, (
        f"the successor holds {stranded} alpha RAO: the 40% pile of {smaller_pile}, short of the 60% slot's {larger_pile}"
    )

    assert not env.backing_intact(token_id), "the 40% pile cannot account for the 60% slot"
    incidents.assert_shortfall_blocks_priced_calls(env, token_id, larger, larger_pile, "Cross-assigned slots")

    receipt = env.vault_send_between_epochs(
        netuid, 6_000_000, "Cross-assigned slots: syncBacking failed", "syncBacking(uint256)", token_id,
        label="syncBacking [park cross-assigned]",
    )
    sync_block = chain.receipt_block_number(receipt, "Cross-assigned slots: sync")
    located = [larger, smaller, successor]
    held_before = env.total_stake_across(clone_coldkey, netuid, located, sync_block - 1)
    assert held_before >= deposited - config.ROUNDING_DUST_TOTAL_RAO, (
        f"the clone held {held_before} alpha RAO before the sync, less than the {deposited} deposited"
    )
    parked = env.stake(parking_hotkey, clone_coldkey, netuid, sync_block)
    assert abs(parked - held_before) <= config.ROUNDING_DUST_TOTAL_RAO, (
        f"the sync should park both piles, {held_before} alpha RAO, parked {parked}"
    )
    reported = chain.event_word(receipt, "BackingParked(uint256,uint256,uint256)", 0, "Cross-assigned slots: sync")
    assert reported == parked, f"BackingParked reports {reported} alpha RAO; the parking hotkey holds {parked}"
    assert env.total_stake_across(clone_coldkey, netuid, located, sync_block) <= config.ROUNDING_DUST_TOTAL_RAO, (
        "alpha stayed behind under a validator hotkey"
    )
    assert env.vault_total_stake(token_id, block=sync_block) == parked, "the quote prices the parked alpha"
    assert env.write_off_deadline(token_id) == 0, "the sync should finish recovery in the same call"
    assert env.backing_intact(token_id), "parked backing accounts for itself"
    assert env.awaiting_attestation(token_id), "the position should wait for the registry owner"
    assert checks.find_strays(env, token_id) == [], "nothing should be left outside the record"

    incidents.assert_parked_refuses_allocation_and_pays_exits(
        env, token_id, smaller, env.vault_shares(token_id) // 4, "Cross-assigned slots",
    )

    released_onto = [smaller, successor]
    env.set_validators(netuid, released_onto, WEIGHTS)
    release_block = incidents.release_parked(
        env, token_id, released_onto, "Cross-assigned slots", "rebalance [release cross-assigned]",
    )
    position = env.total_stake_across(clone_coldkey, netuid, released_onto, release_block)
    for hotkey, weight in zip(released_onto, (6, 4)):
        checks.assert_pro_rata(
            env.stake(hotkey, clone_coldkey, netuid, release_block), position, weight, 10,
            config.CONSOLIDATION_ROUNDING_TOLERANCE_RAO,
            "Cross-assigned slots: each released slot should hold its weight of the position",
        )

    env.deposit_and_wrap(
        netuid, successor, stranding.successor_ss58, config.DEPOSIT_RAO, 2_500_000,
        "Cross-assigned slots: deposits should resume",
    )
    held = located + [parking_hotkey]
    receipt, _ = exits.unwrap(
        env, token_id, env.vault_shares(token_id), "Cross-assigned slots: the full exit after the release failed",
        hotkeys=held,
    )
    exits.assert_drained(env, token_id, held, receipt, "Cross-assigned slots: full exit")

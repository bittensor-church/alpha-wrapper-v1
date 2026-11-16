"""A validator swaps one attested hotkey onto another; one `syncBacking` parks the position whole.

The registry attests two hotkeys of one validator coldkey at equal weight. The second holds no
seat on the subnets the swap covers, as a validator's hotkey does after it loses its seat, so the
chain lets a swap land on it although it already holds stake. The validator swaps the first
hotkey onto the second on every subnet, and the clone's two piles become one under a hotkey the
record already names for the other slot. The vault counts a hotkey for one slot only: the first
slot reads short and the deposit, both exits, the rebalance, the quotes and `recoverStray` all
refuse. One `syncBacking` gathers the whole pile onto the parking hotkey and finishes recovery
in the same call. Exits pay from there, and a registry set naming the successor beside another
validator releases the position.
"""
import pytest

from alpha_e2e import bootstrap, chain, checks, config, exits, extrinsics, incidents

SUCCESSOR_URI = "//MergeSuccessor"
EQUAL_WEIGHTS = [5_000, 5_000]


@pytest.mark.scenario
def test_one_sync_parks_two_slots_merged_onto_one_hotkey(env, recovery_window):
    env = bootstrap.redeploy(env, 0, recovery_window, weighted_registry=True)
    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    swapped, other_hotkey = env.subnet_hotkey_pubkeys(0)[:2]
    swapped_ss58, other_hotkey_ss58 = env.subnet_hotkey_ss58s(0)[:2]
    successor = extrinsics.keypair_pubkey(SUCCESSOR_URI)
    successor_ss58 = extrinsics.keypair_ss58(SUCCESSOR_URI)
    parking_hotkey = env.parking_hotkey()

    extrinsics.associate_hotkey(successor_ss58)
    assert extrinsics.hotkey_owner(successor_ss58) == config.ALICE_COLDKEY_SS58, (
        "the validator's coldkey should own the second hotkey"
    )
    assert not extrinsics.hotkey_is_registered(successor_ss58, netuid), "the second hotkey should hold no seat"
    env.set_validators(netuid, [swapped, successor], EQUAL_WEIGHTS)

    receipt = env.deposit_and_wrap(
        netuid, swapped, swapped_ss58, config.DEPOSIT_RAO, 2_500_000, "Merged slots: wrap failed",
    )
    clone_coldkey = env.clone_coldkey(token_id)
    wrap_block = chain.receipt_block_number(receipt, "Merged slots: wrap")
    shares = env.vault_shares(token_id)
    deposited = env.deposited(receipt, netuid)
    swapped_pile = env.stake(swapped, clone_coldkey, netuid, wrap_block)
    successor_pile = env.stake(successor, clone_coldkey, netuid, wrap_block)
    for pile in (swapped_pile, successor_pile):
        checks.assert_pro_rata(
            pile, deposited, 1, 2, config.CONSOLIDATION_ROUNDING_TOLERANCE_RAO,
            "Merged slots: each slot should hold half the deposit",
        )

    incidents.swap_validator_hotkey(env, 0, 0, SUCCESSOR_URI, "Merged slots")
    assert env.stake(swapped, clone_coldkey, netuid) == 0, "the swap should empty the swapped hotkey"
    merged_pile = env.stake(successor, clone_coldkey, netuid)
    assert merged_pile >= swapped_pile + successor_pile - config.ROUNDING_DUST_SLOT_RAO, (
        f"the successor holds {merged_pile} alpha RAO of the two piles' {swapped_pile} + {successor_pile}"
    )

    assert not env.backing_intact(token_id), "one pile cannot account for two slots"
    incidents.assert_shortfall_blocks_priced_calls(env, token_id, swapped, swapped_pile, "Merged slots")
    env.assert_vault_reverts_with(
        incidents.SHORTFALL_ERROR, 1_500_000,
        "Merged slots: recoverStray should refuse while the first slot reads short",
        "recoverStray(uint256,bytes32)", token_id, successor, error_args=(netuid, swapped, swapped_pile),
    )

    receipt = env.vault_send_between_epochs(
        netuid, 4_000_000, "Merged slots: syncBacking failed", "syncBacking(uint256)", token_id,
        label="syncBacking [park merged]",
    )
    sync_block = chain.receipt_block_number(receipt, "Merged slots: sync")
    merged_before = env.stake(successor, clone_coldkey, netuid, sync_block - 1)
    parked = env.stake(parking_hotkey, clone_coldkey, netuid, sync_block)
    assert abs(parked - merged_before) <= config.ROUNDING_DUST_SLOT_RAO, (
        f"the sync should park the whole merged pile of {merged_before} alpha RAO, parked {parked}"
    )
    reported = chain.event_word(receipt, "BackingParked(uint256,uint256,uint256)", 0, "Merged slots: sync")
    assert reported == parked, f"BackingParked reports {reported} alpha RAO; the parking hotkey holds {parked}"
    assert env.stake(successor, clone_coldkey, netuid, sync_block) <= config.ROUNDING_DUST_SLOT_RAO, (
        "alpha stayed behind on the successor"
    )
    assert env.vault_total_stake(token_id, block=sync_block) == parked, "the quote prices the parked alpha"
    assert env.write_off_deadline(token_id) == 0, "the sync should finish recovery in the same call"
    assert env.backing_intact(token_id), "parked backing accounts for itself"
    assert env.awaiting_attestation(token_id), "the position should wait for the registry owner"
    assert checks.find_strays(env, token_id) == [], "nothing should be left outside the record"

    incidents.assert_parked_refuses_allocation_and_pays_exits(env, token_id, successor, shares // 4, "Merged slots")

    released_onto = [successor, other_hotkey]
    env.set_validators(netuid, released_onto, EQUAL_WEIGHTS)
    release_block = incidents.release_parked(env, token_id, released_onto, "Merged slots", "rebalance [release merged]")
    position = env.total_stake_across(clone_coldkey, netuid, released_onto, release_block)
    for hotkey in released_onto:
        checks.assert_pro_rata(
            env.stake(hotkey, clone_coldkey, netuid, release_block), position, 1, 2,
            config.CONSOLIDATION_ROUNDING_TOLERANCE_RAO,
            "Merged slots: each released slot should hold half the position",
        )
    assert env.resolved_hotkeys(token_id) == [hotkey.lower() for hotkey in released_onto], (
        "the record should name one hotkey per slot again"
    )

    env.deposit_and_wrap(
        netuid, other_hotkey, other_hotkey_ss58, config.DEPOSIT_RAO, 2_500_000,
        "Merged slots: deposits should resume",
    )
    located = [swapped, successor, other_hotkey, parking_hotkey]
    receipt, _ = exits.unwrap(
        env, token_id, env.vault_shares(token_id), "Merged slots: the full exit after the release failed",
        hotkeys=located,
    )
    exits.assert_drained(env, token_id, located, receipt, "Merged slots: full exit")

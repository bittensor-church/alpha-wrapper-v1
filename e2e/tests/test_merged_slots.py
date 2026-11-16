"""A validator folds one attested hotkey into another; one `syncBacking` parks the position whole.

The registry attests two hotkeys of one validator coldkey at equal weight. The second holds no
subnet seat, as a validator's hotkey does after it loses its seat, which is the one state where
the chain lets a swap land on a hotkey that already holds stake. The validator swaps the first
hotkey onto the second on every subnet, so the clone's two piles become one under a hotkey the
record already names for the other slot. The vault counts a hotkey for one slot only: the first
slot reads short and every priced call refuses, `recoverStray` included. One `syncBacking`
gathers the whole pile onto the parking hotkey with no recovery window, exits pay from there, and
a registry set naming the surviving hotkey beside another validator releases the position.
"""
import pytest

from alpha_e2e import bootstrap, chain, checks, config, exits, extrinsics, incidents

SURVIVING_HOTKEY_URI = "//MergedInto"
EQUAL_WEIGHTS = [5_000, 5_000]


@pytest.mark.scenario
def test_one_sync_parks_two_slots_merged_onto_one_hotkey(env, recovery_window):
    env = bootstrap.redeploy(env, 0, recovery_window, weighted_registry=True)
    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    folded, other_validator = env.subnet_hotkey_pubkeys(0)[:2]
    folded_ss58, other_validator_ss58 = env.subnet_hotkey_ss58s(0)[:2]
    surviving = extrinsics.keypair_pubkey(SURVIVING_HOTKEY_URI)
    surviving_ss58 = extrinsics.keypair_ss58(SURVIVING_HOTKEY_URI)
    parking_hotkey = env.parking_hotkey()

    extrinsics.associate_hotkey(surviving_ss58)
    assert extrinsics.hotkey_owner(surviving_ss58) == config.ALICE_COLDKEY_SS58, (
        "the validator's coldkey should own the second hotkey"
    )
    assert not extrinsics.hotkey_is_registered(surviving_ss58, netuid), "the second hotkey should hold no seat"
    env.set_validators(netuid, [folded, surviving], EQUAL_WEIGHTS)

    receipt = env.deposit_and_wrap(
        netuid, folded, folded_ss58, config.DEPOSIT_RAO, 2_500_000, "Merged slots: wrap failed",
    )
    clone_coldkey = env.clone_coldkey(token_id)
    wrap_block = chain.receipt_block_number(receipt, "Merged slots: wrap")
    shares = env.vault_shares(token_id)
    deposited = env.deposited(receipt, netuid)
    folded_pile = env.stake(folded, clone_coldkey, netuid, wrap_block)
    surviving_pile = env.stake(surviving, clone_coldkey, netuid, wrap_block)
    checks.assert_pro_rata(
        folded_pile, deposited, 1, 2, config.CONSOLIDATION_ROUNDING_TOLERANCE_RAO,
        "Merged slots: the first slot should hold half the deposit",
    )
    checks.assert_pro_rata(
        surviving_pile, deposited, 1, 2, config.CONSOLIDATION_ROUNDING_TOLERANCE_RAO,
        "Merged slots: the second slot should hold half the deposit",
    )

    incidents.swap_validator_hotkey(env, 0, 0, SURVIVING_HOTKEY_URI, "Merged slots")
    assert env.stake(folded, clone_coldkey, netuid) == 0, "the swap should empty the folded hotkey"
    merged_pile = env.stake(surviving, clone_coldkey, netuid)
    assert merged_pile >= folded_pile + surviving_pile - config.ROUNDING_DUST_SLOT_RAO, (
        f"the surviving hotkey holds {merged_pile} alpha RAO of the two piles' {folded_pile} + {surviving_pile}"
    )

    assert not env.backing_intact(token_id), "one pile cannot account for two slots"
    shortfall = (netuid, folded, folded_pile)
    env.assert_vault_reverts_with(
        "BackingShortfall(uint16,bytes32,uint256)", 1_500_000,
        "Merged slots: a priced operation should refuse while the first slot reads short",
        "rebalance(uint256)", netuid, error_args=shortfall,
    )
    env.assert_vault_reverts_with(
        "BackingShortfall(uint16,bytes32,uint256)", 1_500_000,
        "Merged slots: recoverStray should refuse a hotkey the record already names",
        "recoverStray(uint256,bytes32)", token_id, surviving, error_args=shortfall,
    )

    receipt = env.vault_send_between_epochs(
        netuid, 4_000_000, "Merged slots: syncBacking failed", "syncBacking(uint256)", token_id,
        label="syncBacking [park merged]",
    )
    sync_block = chain.receipt_block_number(receipt, "Merged slots: sync")
    merged_before = env.stake(surviving, clone_coldkey, netuid, sync_block - 1)
    parked = env.stake(parking_hotkey, clone_coldkey, netuid, sync_block)
    assert abs(parked - merged_before) <= config.ROUNDING_DUST_SLOT_RAO, (
        f"the sync should park the whole merged pile of {merged_before} alpha RAO, parked {parked}"
    )
    reported = chain.event_word(receipt, "BackingParked(uint256,uint256,uint256)", 0, "Merged slots: sync")
    assert reported == parked, f"BackingParked reports {reported} alpha RAO; the parking hotkey holds {parked}"
    assert env.stake(surviving, clone_coldkey, netuid, sync_block) <= config.ROUNDING_DUST_SLOT_RAO, (
        "alpha stayed behind on the surviving hotkey"
    )
    assert env.vault_total_stake(token_id, block=sync_block) == parked, "the quote prices the parked alpha"
    assert env.write_off_deadline(token_id) == 0, "nothing is missing, so no recovery window opens"
    assert env.backing_intact(token_id), "parked backing accounts for itself"
    assert env.awaiting_attestation(token_id), "the position should wait for the registry owner"
    assert checks.find_strays(env, token_id) == [], "nothing should be left outside the record"

    env.assert_vault_reverts_with(
        "Parked()", 1_500_000, "Merged slots: a deposit should be refused while parked",
        "wrap(uint256,bytes32,uint256)", netuid, surviving, 0,
    )
    exits.unwrap(
        env, token_id, shares // 4, "Merged slots: the exit should pay from the parking hotkey",
        hotkeys=[parking_hotkey],
    )
    assert env.awaiting_attestation(token_id), "an exit does not release the position"

    released_onto = [surviving, other_validator]
    env.set_validators(netuid, released_onto, EQUAL_WEIGHTS)
    assert not env.awaiting_attestation(token_id), "a newer attestation lifts the hold"
    receipt = env.vault_send_between_epochs(
        netuid, 4_000_000, "Merged slots: the release rebalance failed", "rebalance(uint256)", netuid,
        label="rebalance [release merged]",
    )
    release_block = chain.receipt_block_number(receipt, "Merged slots: release")
    parked_before = env.stake(parking_hotkey, clone_coldkey, netuid, release_block - 1)
    assert env.stake(parking_hotkey, clone_coldkey, netuid, release_block) <= config.ROUNDING_DUST_SLOT_RAO, (
        "the parking hotkey should be empty after the release"
    )
    landed = env.stake_change(clone_coldkey, netuid, released_onto, release_block)
    assert abs(landed - parked_before) <= config.ROUNDING_DUST_TOTAL_RAO, (
        f"the new set should take the {parked_before} alpha RAO parked, took {landed}"
    )
    for hotkey in released_onto:
        checks.assert_pro_rata(
            env.stake(hotkey, clone_coldkey, netuid, release_block), landed, 1, 2,
            config.CONSOLIDATION_ROUNDING_TOLERANCE_RAO,
            "Merged slots: each released slot should hold half the position",
        )
    assert env.resolved_hotkeys(token_id) == [hotkey.lower() for hotkey in released_onto], (
        "the record should name one hotkey per slot again"
    )
    assert env.backing_intact(token_id), "the record follows the set"

    env.deposit_and_wrap(
        netuid, other_validator, other_validator_ss58, config.DEPOSIT_RAO, 2_500_000,
        "Merged slots: deposits should resume",
    )
    located = [folded, surviving, other_validator, parking_hotkey]
    receipt, _ = exits.unwrap(
        env, token_id, env.vault_shares(token_id), "Merged slots: the full exit after the release failed",
        hotkeys=located,
    )
    exits.assert_drained(env, token_id, located, receipt, "Merged slots: full exit")

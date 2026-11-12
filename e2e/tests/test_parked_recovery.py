"""The chain sweeps a position; a stranger returns the alpha under a listed hotkey; the watcher parks it.

Governance raises the nominator minimum and the chain sells the vault's position, the one
loss the staking-list search cannot resolve. A stranger later returns the alpha to the clone
under a rotated-out validator a gift keeps on the clone's list, a hotkey the record does not
name. The watcher calls `syncBacking`, recovers the alpha with `scripts/find_strays.py
--recover`, and syncs again. Backing rests on the vault's parking hotkey, and the vault holds
deposits and weight alignment shut until the owner publishes a newer set. Exits keep working
from the parking hotkey throughout.
"""
import pytest

from alpha_e2e import chain, checks, config, exits, incidents


@pytest.mark.scenario
def test_watcher_parks_a_swept_position_returned_under_a_listed_hotkey(env):
    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    hotkeys = env.subnet_hotkey_pubkeys(0)
    clone_coldkey = env.clone_coldkey(token_id)
    parking_hotkey = env.parking_hotkey()

    receipt = env.deposit_and_wrap(
        netuid, hotkeys[0], env.subnet_hotkey_ss58s(0)[0],
        config.DEPOSIT_RAO, 1_500_000, "Parked recovery: wrap failed",
    )
    shares = env.vault_shares(token_id)
    checks.assert_first_deposit_shares(shares, env.deposited(receipt, netuid), "Parked recovery: setup wrap")

    swept = incidents.sweep(env, 0, "Parked recovery")
    assert not env.backing_intact(token_id), "a swept position must read short"
    env.assert_vault_reverts_with(
        "BackingShortfall(uint16,bytes32,uint256)", 1_500_000,
        "Parked recovery: a priced operation should refuse while the alpha is gone",
        "rebalance(uint256)", netuid, error_args=(netuid, swept.attested_pubkey, swept.swept_rao),
    )

    parking = incidents.park(env, token_id, swept, "Parked recovery")
    incidents.assert_watcher_parked(env, token_id, swept, parking, "Parked recovery")
    assert env.total_stake_across(clone_coldkey, netuid, hotkeys) <= config.ROUNDING_DUST_TOTAL_RAO, (
        "alpha stayed behind on validator hotkeys after parking"
    )
    assert env.vault_total_stake(token_id) == parking.parked, "the quote prices the parked alpha"

    env.assert_vault_reverts_with(
        "Parked()", 1_500_000,
        "Parked recovery: a deposit should be refused while parked",
        "wrap(uint256,bytes32,uint256)", netuid, swept.attested_pubkey, 0,
    )
    exits.unwrap(
        env, token_id, shares // 4, "Parked recovery: the exit should pay from the parking hotkey",
        hotkeys=[parking_hotkey],
    )
    assert env.awaiting_attestation(token_id), "an exit does not release the position"

    env.set_validator(netuid, swept.attested_pubkey)
    assert not env.awaiting_attestation(token_id), "a newer attestation lifts the hold"
    receipt = env.vault_send_between_epochs(
        netuid, 4_000_000, "Parked recovery: the release rebalance failed", "rebalance(uint256)", netuid,
        label="rebalance [release parked]",
    )

    assert env.stake(parking_hotkey, clone_coldkey, netuid) <= config.ROUNDING_DUST_SLOT_RAO, (
        "the parking hotkey should be empty after the release"
    )
    assert env.stake(swept.listed_pubkey, clone_coldkey, netuid) == 0, "nothing goes back to the rotated-out validator"
    release_block = chain.receipt_block_number(receipt, "Parked recovery: release")
    parked_before = env.stake(parking_hotkey, clone_coldkey, netuid, release_block - 1)
    landed = env.stake_change(clone_coldkey, netuid, [swept.attested_pubkey], release_block)
    assert abs(landed - parked_before) <= config.ROUNDING_DUST_SLOT_RAO, (
        f"the attested validator should take the {parked_before} alpha RAO parked, took {landed}"
    )
    assert env.backing_intact(token_id), "the record follows the set"
    assert not env.awaiting_attestation(token_id), "and the position is ordinary again"
    env.deposit_and_wrap(
        netuid, swept.attested_pubkey, swept.attested_ss58,
        config.DEPOSIT_RAO // 10, 1_500_000, "Parked recovery: deposits should resume",
    )

    located = hotkeys + [parking_hotkey]
    receipt, _ = exits.unwrap(
        env, token_id, env.vault_shares(token_id), "Parked recovery: the full exit after the release failed",
        hotkeys=located,
    )
    exits.assert_drained(env, token_id, located, receipt, "Parked recovery: full exit")

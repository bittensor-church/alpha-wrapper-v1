"""One parking hotkey serves every subnet without coupling their positions.

Stake is keyed by hotkey, coldkey and subnet, and each subnet's position has its own
clone coldkey, so parking one subnet must leave the others trading, two must park side
by side, and each must release on its own attestation.
"""
import pytest

from alpha_e2e import chain, config, exits, incidents


@pytest.mark.scenario
def test_parked_subnets_share_the_hotkey_without_sharing_state(env):
    netuid_a, netuid_b = env.netuids[0], env.netuids[1]
    token_a, token_b = env.token_ids[0], env.token_ids[1]
    hotkeys_a, hotkeys_b = env.subnet_hotkey_pubkeys(0), env.subnet_hotkey_pubkeys(1)
    clone_a, clone_b = env.clone_coldkey(token_a), env.clone_coldkey(token_b)
    parking_hotkey = env.parking_hotkey()

    env.deposit_and_wrap(
        netuid_a, hotkeys_a[0], env.subnet_hotkey_ss58s(0)[0],
        config.DEPOSIT_RAO, 1_500_000, "Isolation: wrap on A failed",
    )
    swept_a = incidents.sweep(env, 0, "Isolation: A")
    assert not env.backing_intact(token_a), "A's swept position must read short"
    parking_a = incidents.park(env, token_a, swept_a, "Isolation: A")
    incidents.assert_watcher_parked(env, token_a, swept_a, parking_a, "Isolation: A")
    parked_a = parking_a.parked

    # B's position stays worth a fraction of A's parked balance, so B's sweep cannot reach A's.
    _, b_deposit = env.floor_boundary(netuid_b, env.alpha_value_tao(netuid_a, parked_a) // 8)
    b_deposit = min(b_deposit, config.DEPOSIT_RAO // 2)
    env.deposit_and_wrap(
        netuid_b, hotkeys_b[0], env.subnet_hotkey_ss58s(1)[0],
        b_deposit, 1_500_000, "Isolation: B should wrap while A is parked",
    )
    assert not env.awaiting_attestation(token_b), "B should not be parked by A's incident"
    assert env.backing_intact(token_b), "B's backing should be untouched"
    assert env.stake(parking_hotkey, clone_b, netuid_b) == 0, "nothing of B's should sit on the parking hotkey"

    env.deposit_and_wrap(
        netuid_b, hotkeys_b[0], env.subnet_hotkey_ss58s(1)[0],
        b_deposit // 5, 1_500_000, "Isolation: B should accept a deposit while A is parked",
    )
    env.vault_send(
        4_000_000, "Isolation: B should align while A is parked", "rebalance(uint256)", netuid_b,
        label="rebalance [sibling parked]",
    )
    exits.unwrap(
        env, token_b, env.vault_shares(token_b) // 4, "Isolation: B should pay an exit while A is parked",
        hotkeys=hotkeys_b, label="unwrap [sibling parked]",
    )
    assert env.stake(parking_hotkey, clone_a, netuid_a) == parked_a, "A's parked balance moved while B traded"
    assert env.awaiting_attestation(token_a), "A should still be waiting for its registry owner"

    swept_b = incidents.sweep(env, 1, "Isolation: B")
    assert not env.backing_intact(token_b), "B's swept position must read short"
    parking_b = incidents.park(env, token_b, swept_b, "Isolation: B")
    incidents.assert_watcher_parked(env, token_b, swept_b, parking_b, "Isolation: B")
    parked_b = parking_b.parked

    assert env.stake(parking_hotkey, clone_a, netuid_a) == parked_a, "parking B should leave A's entry alone"
    assert env.stake(parking_hotkey, clone_b, netuid_b) == parked_b, "B's entry should hold B's alpha"
    assert env.awaiting_attestation(token_a) and env.awaiting_attestation(token_b), "both positions should wait"

    env.set_validator(netuid_a, swept_a.attested_pubkey)
    assert env.awaiting_attestation(token_b), "an attestation for A should not release B"
    receipt = env.vault_send_between_epochs(
        netuid_a, 4_000_000, "Isolation: the release rebalance on A failed", "rebalance(uint256)", netuid_a,
        label="rebalance [release A]",
    )
    assert env.stake(parking_hotkey, clone_a, netuid_a) <= config.ROUNDING_DUST_SLOT_RAO, (
        "A's entry should be empty after its release"
    )
    release_block = chain.receipt_block_number(receipt, "Isolation: A: release")
    parked_before = env.stake(parking_hotkey, clone_a, netuid_a, release_block - 1)
    landed = env.stake_change(clone_a, netuid_a, [swept_a.attested_pubkey], release_block)
    assert abs(landed - parked_before) <= config.ROUNDING_DUST_SLOT_RAO, (
        f"A's attested validator should take the {parked_before} alpha RAO parked, took {landed}"
    )
    assert not env.awaiting_attestation(token_a), "A should be ordinary again"
    assert env.stake(parking_hotkey, clone_b, netuid_b) == parked_b, "releasing A should move nothing of B's"
    assert env.awaiting_attestation(token_b), "B should still be parked"

    env.set_validator(netuid_b, swept_b.attested_pubkey)
    receipt = env.vault_send_between_epochs(
        netuid_b, 4_000_000, "Isolation: the release rebalance on B failed", "rebalance(uint256)", netuid_b,
        label="rebalance [release B]",
    )
    assert env.stake(parking_hotkey, clone_b, netuid_b) <= config.ROUNDING_DUST_SLOT_RAO, (
        "B's entry should be empty after its release"
    )
    release_block = chain.receipt_block_number(receipt, "Isolation: B: release")
    parked_before = env.stake(parking_hotkey, clone_b, netuid_b, release_block - 1)
    landed = env.stake_change(clone_b, netuid_b, [swept_b.attested_pubkey], release_block)
    assert abs(landed - parked_before) <= config.ROUNDING_DUST_SLOT_RAO, (
        f"B's attested validator should take the {parked_before} alpha RAO parked, took {landed}"
    )
    assert not env.awaiting_attestation(token_b), "B should be ordinary again"
    assert env.backing_intact(token_a) and env.backing_intact(token_b), "both records should follow their new sets"

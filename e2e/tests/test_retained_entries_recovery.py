"""Recovery after a hotkey swap still works while a crumb keeps an entry on the clone's list.

A stranger sends a crumb under the attested validator on another subnet, which the chain
admits because the clone lists that validator. The validator then renames its hotkey and a
stranger cuts the trail, as in the parked-recovery scenario. The watcher parks the position,
the clone's own move onto the parking hotkey, and the owner's update releases the position
onto the successor while the crumb keeps its entry. Exits pay throughout and deposits resume
afterwards.
"""
import pytest

from alpha_e2e import config, exits, extrinsics, incidents
from alpha_e2e.substrate import h160_to_ss58

STRANGER = "//CrumbStranger"


@pytest.mark.scenario
def test_recovery_with_a_retained_entry(env):
    netuid, other_netuid, _ = env.netuids
    token_id = env.token_ids[0]
    validator, validator_ss58 = env.hotkey_pubkeys[0], env.hotkey_ss58s[0]
    clone = env.clone_address(token_id)
    clone_coldkey = env.clone_coldkey(token_id)
    parking_hotkey = env.parking_hotkey()

    env.deposit_and_wrap(
        netuid, validator, validator_ss58, config.DEPOSIT_RAO, 1_500_000, "Retained entry: wrap failed",
    )
    shares = env.vault_shares(token_id)

    extrinsics.fund_account(extrinsics.keypair_ss58(STRANGER), 5 * config.RAO_PER_TAO)
    extrinsics.add_stake(validator_ss58, other_netuid, 2 * config.RAO_PER_TAO, signer_uri=STRANGER)
    _, crumb = env.floor_boundary(other_netuid, env.chain_min_stake_tao())
    extrinsics.transfer_stake(h160_to_ss58(clone), validator_ss58, other_netuid, crumb, signer_uri=STRANGER)
    assert env.stake(validator, clone_coldkey, other_netuid) > 0, "the crumb did not land"

    stranding = incidents.cut_trail(env, 0, 0, "//RetainedSuccessor", "//RetainedJunk", "Retained entry")
    successor, successor_ss58 = stranding.successor_pubkey, stranding.successor_ss58
    assert env.stake(successor, clone_coldkey, other_netuid) > 0, "the crumb did not follow the rename"

    parked = incidents.park(env, token_id, stranding, "Retained entry")
    assert env.vault_total_stake(token_id) == parked, "the quote prices the parked alpha"
    assert len(extrinsics.staking_hotkeys(h160_to_ss58(clone))) >= 2, (
        "the crumb should keep the successor listed beside the parking hotkey"
    )

    exits.unwrap(
        env, token_id, shares // 4, "Retained entry: the exit should pay from the parking hotkey",
        hotkeys=[parking_hotkey],
    )
    env.set_validator(netuid, successor)
    env.vault_send(
        4_000_000, "Retained entry: the release rebalance failed", "rebalance(uint256)", netuid,
        label="rebalance [release parked]",
    )
    assert env.stake(parking_hotkey, clone_coldkey, netuid) <= config.ROUNDING_DUST_SLOT_RAO, (
        "the parking hotkey should be empty after the release"
    )
    assert env.stake(successor, clone_coldkey, netuid) > 0, "the successor should carry its weight"
    assert env.backing_intact(token_id) and not env.awaiting_attestation(token_id)

    env.deposit_and_wrap(
        netuid, successor, successor_ss58, config.DEPOSIT_RAO // 10, 1_500_000, "Retained entry: deposits should resume",
    )
    located = [successor, parking_hotkey]
    receipt, _ = exits.unwrap(
        env, token_id, env.vault_shares(token_id), "Retained entry: the full exit failed", hotkeys=located,
    )
    exits.assert_drained(env, token_id, located, receipt, "Retained entry: full exit")

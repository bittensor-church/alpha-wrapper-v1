"""Hotkey swaps under a funded position, with and without the stake following the swap.

A validator moves its identity to a new hotkey while its stake stays behind. The old
hotkey keeps its owner record, so the attested hotkey still answers to the coldkey that
was attested and exits keep paying from it. Once the owner publishes a set that names
the successor, the next exit rolls the stake onto the successor and pays the holder,
with no watcher and no subnet re-registration involved.

When the stake follows the swap instead, the chain records the edge from the old
hotkey to the new one; the vault follows it on the next call and keeps paying exits from
the successor while the registry still names the old hotkey.
"""
import pytest

from alpha_e2e import chain, checks, config, exits, extrinsics


@pytest.mark.scenario
def test_holder_exits_across_a_hotkey_swap_that_leaves_the_stake_behind(env):
    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    hotkeys = env.subnet_hotkey_pubkeys(0)
    hotkey_pubkey = hotkeys[0]
    hotkey_ss58 = env.subnet_hotkey_ss58s(0)[0]
    owner_ss58 = extrinsics.hotkey_owner(hotkey_ss58)
    assert owner_ss58 != "", "the validator hotkey should start out owned"

    receipt = env.deposit_and_wrap(
        netuid, hotkey_pubkey, hotkey_ss58,
        config.DEPOSIT_RAO, 1_500_000, "Kept stake: wrap failed",
    )
    shares = env.vault_shares(token_id)
    checks.assert_first_deposit_shares(shares, env.deposited(receipt, netuid), "Kept stake: setup wrap")

    # A live subnet emits, so the position only grows between reads; the comparisons are floors.
    clone_coldkey = env.clone_coldkey(token_id)
    kept = env.stake(hotkey_pubkey, clone_coldkey, netuid)
    assert kept > 0, "the setup left no stake on the hotkey about to be swapped"

    successor_ss58 = extrinsics.keypair_ss58("//ParkedSuccessor")
    successor_pubkey = extrinsics.keypair_pubkey("//ParkedSuccessor")
    extrinsics.swap_hotkey_keep_stake(hotkey_ss58, successor_ss58)

    assert extrinsics.hotkey_owner(hotkey_ss58) == owner_ss58, "the swap should keep the old hotkey's owner"
    assert not extrinsics.hotkey_is_registered(hotkey_ss58, netuid), (
        "the old hotkey should no longer be registered after its identity moved"
    )
    assert env.stake(hotkey_pubkey, clone_coldkey, netuid) >= kept, (
        "the swap was meant to leave the stake where it was"
    )
    assert env.backing_intact(token_id), "the backing check should be satisfied, not tripped"
    assert env.write_off_deadline(token_id) == 0, "an intact position must not be holding anything shut"
    read_block = chain.cast_block_number()
    quoted = env.vault_total_stake(token_id, block=read_block)
    held = env.stake(hotkey_pubkey, clone_coldkey, netuid, read_block)
    assert quoted == held, f"the quote prices {quoted} alpha RAO; the swapped-away hotkey still holds {held}"

    exit_shares = shares // 2
    exits.unwrap(
        env, token_id, exit_shares, "Kept stake: a partial exit should pay from the old hotkey",
        hotkeys=hotkeys, label="unwrap [kept stake]",
    )
    assert env.vault_shares(token_id) == shares - exit_shares, "the exit burned the wrong shares"

    env.set_validator(netuid, successor_pubkey)

    delivery_keys = hotkeys + [successor_pubkey]
    exits.unwrap(
        env, token_id, exit_shares // 2, "Kept stake: the exit should follow the successor once named",
        hotkeys=delivery_keys, gas_limit=4_000_000, label="unwrap [follows the successor]",
        tolerance=config.CONSOLIDATION_ROUNDING_TOLERANCE_RAO,
    )
    assert env.vault_shares(token_id) == shares - exit_shares - exit_shares // 2, "the exit burned the wrong shares"
    assert extrinsics.hotkey_owner(hotkey_ss58) == owner_ss58, "moving the stake off the old key needs no claim"
    assert env.stake(hotkey_pubkey, clone_coldkey, netuid) <= config.ROUNDING_DUST_SLOT_RAO, (
        "the stake should have left the old hotkey"
    )
    assert env.stake(successor_pubkey, clone_coldkey, netuid) > 0, "the successor should carry the position"


@pytest.mark.scenario
def test_exits_follow_a_swapped_validator_hotkey_before_the_registry_catches_up(env):
    netuid = env.netuids[1]
    token_id = env.token_ids[1]
    hotkeys = env.subnet_hotkey_pubkeys(1)
    swapped_pubkey = hotkeys[0]
    swapped_ss58 = env.subnet_hotkey_ss58s(1)[0]

    env.deposit_and_wrap(
        netuid, swapped_pubkey, swapped_ss58, config.DEPOSIT_RAO, 1_500_000, "Followed swap: wrap failed",
    )
    shares = env.vault_shares(token_id)
    clone_coldkey = env.clone_coldkey(token_id)

    successor_ss58 = extrinsics.keypair_ss58("//FollowedSuccessor")
    successor_pubkey = extrinsics.keypair_pubkey("//FollowedSuccessor")
    extrinsics.swap_hotkey(swapped_ss58, successor_ss58)
    assert env.stake(swapped_pubkey, clone_coldkey, netuid) <= config.ROUNDING_DUST_SLOT_RAO, (
        "the swap should carry the stake away"
    )
    assert env.backing_intact(token_id), "the vault should follow the chain's swap edge"

    delivery_keys = hotkeys + [successor_pubkey]
    receipt, delivered = exits.unwrap(
        env, token_id, shares // 2, "Followed swap: a partial exit should pay from the successor",
        hotkeys=delivery_keys,
    )
    exit_block = chain.receipt_block_number(receipt, "Followed swap: partial exit")
    under_successor = env.stake_change(env.wrapper_substrate_coldkey, netuid, [successor_pubkey], exit_block)
    assert under_successor == delivered, (
        f"the exit should deliver under the successor: {under_successor} of {delivered} alpha RAO"
    )
    receipt, _ = exits.unwrap(
        env, token_id, env.vault_shares(token_id), "Followed swap: the full exit failed", hotkeys=delivery_keys,
    )
    exits.assert_drained(env, token_id, delivery_keys, receipt, "Followed swap: full exit")

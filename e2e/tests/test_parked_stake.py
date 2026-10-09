"""Hotkey renames under a live position, with and without the stake following the name.

A validator moves its identity to a new hotkey while its stake stays behind. The old
hotkey then has no owner record, so the chain would refuse to move alpha off it, and
the attested name no longer answers to the coldkey that was attested. The vault keeps
the position quotable but refuses partial exits until the owner publishes a set that
names the successor. The next exit then claims the abandoned key for the vault's own
coldkey, rolls the stake onto the successor and pays the holder, with no watcher and
no subnet re-registration involved.

When the stake follows the rename instead, the chain records the edge from the old
name to the new one; the vault follows it on the next call and keeps paying exits from
the successor while the registry still names the old key.
"""
import pytest

from alpha_e2e import chain, config, exits, extrinsics, substrate


@pytest.mark.scenario
def test_holder_exits_after_owner_replaces_the_ownerless_name(env):
    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    hotkeys = env.subnet_hotkey_pubkeys(0)
    hotkey_pubkey = env.hotkey_pubkeys[0]
    hotkey_ss58 = env.hotkey_ss58s[0]

    env.deposit_and_wrap(
        netuid, hotkey_pubkey, hotkey_ss58,
        config.DEPOSIT_RAO, 1_500_000, "Parked: wrap failed",
    )
    shares = env.vault_shares(token_id)
    assert shares != 0, "no shares minted by the setup wrap"

    # A live subnet emits, so the position only ever grows between reads; the
    # comparisons below are floors rather than equalities for that reason.
    clone_coldkey = env.clone_coldkey(token_id)
    stranded = env.stake(hotkey_pubkey, clone_coldkey, netuid)
    assert stranded > 0, "the setup left no stake on the hotkey about to be stranded"

    successor_ss58 = extrinsics.keypair_ss58("//ParkedSuccessor")
    successor_pubkey = extrinsics.keypair_pubkey("//ParkedSuccessor")
    # The pinned runtime keeps the stake behind, which is the state this scenario needs.
    extrinsics.swap_hotkey_keep_stake(hotkey_ss58, successor_ss58)

    # The identity moved and the owner went with it; the alpha stayed put.
    assert extrinsics.hotkey_owner(hotkey_ss58) == "", "the swap left the hotkey owned"
    assert not extrinsics.hotkey_is_registered(hotkey_ss58, netuid), (
        "the old hotkey should no longer be registered after its identity moved"
    )
    assert env.stake(hotkey_pubkey, clone_coldkey, netuid) >= stranded, (
        "the swap was meant to leave the stake where it was"
    )

    # The record still finds the alpha where it expects it: nothing is missing and no
    # loss goes on file. What the vault refuses is allocating to a name nobody owns.
    assert env.backing_intact(token_id), "the backing check should be satisfied, not tripped"
    assert env.write_off_deadline(token_id) == 0, "an intact position must not be holding anything shut"
    assert env.vault_total_stake(token_id) > 0, "the vault stopped counting the stranded alpha"

    exit_shares = shares // 2
    env.assert_vault_reverts_with(
        "AttestedHotkeyRetired(bytes32)", 2_500_000,
        "Parked: a partial exit should be refused while the attested name has no owner",
        "unwrap(uint256,uint256,bytes32,uint256)", token_id, exit_shares, env.wrapper_substrate_coldkey, 1,
    )

    # The owner names the successor in place of the abandoned key.
    env.set_validator(netuid, successor_pubkey)

    # The same exit, now paid: the vault claims the abandoned key, rolls the stake onto the
    # successor and delivers to the holder's own coldkey.
    delivery_keys = hotkeys + [successor_pubkey]
    receipt, delivered = exits.unwrap(
        env, token_id, exit_shares, "Parked: the exit should succeed once the owner replaced the name",
        hotkeys=delivery_keys, gas_limit=4_000_000, label="unwrap [claims the abandoned key]",
        tolerance=config.CONSOLIDATION_ROUNDING_TOLERANCE_RAO,
    )
    backing_before_exit = env.total_stake_across(
        clone_coldkey, netuid, delivery_keys, chain.receipt_block_number(receipt, "Parked exit") - 1,
    )
    # The roll onto the successor rounds away a little before the half is sized.
    assert abs(delivered - backing_before_exit // 2) <= config.CONSOLIDATION_ROUNDING_TOLERANCE_RAO, (
        f"Parked: the retry paid {delivered} RAO for half of a {backing_before_exit} RAO position"
    )
    assert env.vault_shares(token_id) == shares - exit_shares, "the exit burned the wrong shares"
    assert extrinsics.hotkey_owner(hotkey_ss58) == substrate.h160_to_ss58(env.vault_address), (
        "the vault should have claimed the abandoned key for its own coldkey"
    )
    assert not extrinsics.hotkey_is_registered(hotkey_ss58, netuid), (
        "claiming the key must not register it on the subnet"
    )
    assert env.stake(hotkey_pubkey, clone_coldkey, netuid) <= config.ROUNDING_DUST_SLOT_RAO, (
        "the stake should have left the abandoned key"
    )
    assert env.stake(successor_pubkey, clone_coldkey, netuid) > 0, "the successor should carry the position"


@pytest.mark.scenario
def test_exits_follow_a_renamed_validator_before_the_registry_catches_up(env):
    netuid = env.netuids[1]
    token_id = env.token_ids[1]
    hotkeys = env.subnet_hotkey_pubkeys(1)
    renamed_pubkey = hotkeys[0]
    renamed_ss58 = env.hotkey_ss58s[config.VALIDATORS_PER_SUBNET]

    env.deposit_and_wrap(
        netuid, renamed_pubkey, renamed_ss58, config.DEPOSIT_RAO, 1_500_000, "Followed rename: wrap failed",
    )
    shares = env.vault_shares(token_id)
    clone_coldkey = env.clone_coldkey(token_id)

    successor_ss58 = extrinsics.keypair_ss58("//FollowedSuccessor")
    successor_pubkey = extrinsics.keypair_pubkey("//FollowedSuccessor")
    extrinsics.swap_hotkey(renamed_ss58, successor_ss58)
    assert env.stake(renamed_pubkey, clone_coldkey, netuid) <= config.ROUNDING_DUST_SLOT_RAO, (
        "the rename should carry the stake away"
    )
    assert env.backing_intact(token_id), "the vault should follow the chain's rename edge"

    # The registry still names the old key; the vault pays from the successor its owner holds.
    delivery_keys = hotkeys + [successor_pubkey]
    exits.unwrap(
        env, token_id, shares // 2, "Followed rename: a partial exit should pay from the successor",
        hotkeys=delivery_keys,
    )
    assert env.stake(successor_pubkey, env.wrapper_substrate_coldkey, netuid) > 0, (
        "the exit should have delivered under the successor"
    )
    receipt, _ = exits.unwrap(
        env, token_id, env.vault_shares(token_id), "Followed rename: the full exit failed", hotkeys=delivery_keys,
    )
    exits.assert_drained(env, token_id, delivery_keys, receipt, "Followed rename: full exit")

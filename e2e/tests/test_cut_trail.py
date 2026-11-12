"""A stranger cuts the trail behind a validator's hotkey swap; the vault finds its alpha on the list.

A validator swaps its hotkey on every subnet, which moves the vault's alpha to the
new hotkey and records the edge the vault follows. Before the vault records that, a
stranger swaps a junk hotkey onto the vacated one: the chain lets anyone claim a hotkey
with no owner, and the swap erases its own edge. The alpha still sits under a hotkey the
clone stakes under, so the vault resolves the slot from the clone's staking list: quotes
answer, one `syncBacking` records the hotkey, a deposit chosen under the vacated hotkey
lands on it, and exits pay from it.
"""
import pytest

from alpha_e2e import chain, config, exits, incidents


@pytest.mark.scenario
def test_a_cut_trail_resolves_on_the_staking_list(env):
    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    hotkeys = env.subnet_hotkey_pubkeys(0)
    clone_coldkey = env.clone_coldkey(token_id)

    env.deposit_and_wrap(
        netuid, hotkeys[0], env.subnet_hotkey_ss58s(0)[0], config.DEPOSIT_RAO, 1_500_000, "Cut trail: wrap failed",
    )
    shares = env.vault_shares(token_id)

    stranding = incidents.swap_validator_hotkey(env, 0, 0, "//CutSuccessor", "Cut trail")
    assert env.backing_intact(token_id), "a plain swap is followed and is not a loss"
    incidents.cut_trail(env, netuid, stranding, "//CutJunk", "Cut trail")
    lost, successor = stranding.lost_pubkey, stranding.successor_pubkey
    located = hotkeys + [successor]
    assert env.backing_intact(token_id), "with the edge gone the vault should find its alpha on the clone's list"
    read_block = chain.cast_block_number()
    quoted = env.vault_total_stake(token_id, block=read_block)
    held = env.total_stake_across(clone_coldkey, netuid, located, read_block)
    assert quoted == held, f"the quote prices {quoted} alpha RAO; the clone holds {held} under the found hotkey"

    env.sync_backing(token_id, label="syncBacking [record]")
    assert env.hotkey_in_last_seen(token_id, successor), "the sync records the hotkey found on the list"
    assert not env.hotkey_in_last_seen(token_id, lost), "and leaves the vacated hotkey"
    assert env.write_off_deadline(token_id) == 0, "a found slot is not a loss"
    env.assert_vault_reverts_with(
        "BackingUnchanged()", 1_500_000, "Cut trail: a second sync has nothing to record",
        "syncBacking(uint256)", token_id,
    )

    # Alice's stake followed the swap too, so the deposit is funded from the successor.
    receipt = env.deposit_and_wrap(
        netuid, hotkeys[0], stranding.successor_ss58, config.DEPOSIT_RAO // 10, 1_500_000,
        "Cut trail: a deposit chosen under the vacated hotkey failed",
    )
    block = chain.receipt_block_number(receipt, "Cut trail: deposit")
    deposited = env.deposited(receipt, netuid)
    assert env.stake(lost, clone_coldkey, netuid, block) == 0, "nothing lands on the vacated hotkey"
    landed = env.stake_change(clone_coldkey, netuid, [successor], block)
    assert abs(landed - deposited) <= config.ROUNDING_DUST_SLOT_RAO, (
        f"the deposit should land on the found hotkey: {landed} RAO of {deposited}"
    )

    exits.unwrap(env, token_id, shares // 4, "Cut trail: the exit should pay from the found hotkey", hotkeys=located)
    env.vault_send(4_000_000, "Cut trail: rebalance failed", "rebalance(uint256)", netuid, label="rebalance [cut trail]")
    assert env.backing_intact(token_id), "the record follows the found hotkey throughout"

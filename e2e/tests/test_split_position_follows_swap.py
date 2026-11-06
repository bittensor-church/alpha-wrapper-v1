"""A validator's all-subnet swap carries the clone's whole position, even one a stranger split across subnets.

A stranger gives the clone a position under the attested hotkey on the other subnet, then the
validator swaps that hotkey across all subnets. The chain moves both of the clone's positions to
the successor, renames the clone's staking-list entry in place under its reject-growth flag and
removes the old hotkey's owner record, so nothing stays behind under a hotkey nobody owns. The
vault follows the edge: the next deposit joins the successor, exits pay from it, and the rotation
onto the attested successor leaves the position where it is.
"""
import pytest

from alpha_e2e import config, exits, extrinsics
from alpha_e2e.substrate import h160_to_ss58

STRANGER = "//SplitStranger"
STRANGER_FUNDING_RAO = 2 * config.RAO_PER_TAO
GIFT_BUDGET_RAO = config.RAO_PER_TAO // 2


@pytest.mark.scenario
def test_a_split_position_follows_the_all_subnet_swap(env):
    netuid, other_netuid = env.netuids[0], env.netuids[1]
    token_id = env.token_ids[0]
    hotkeys = env.subnet_hotkey_pubkeys(0)
    swapped_pubkey, swapped_ss58 = env.hotkey_pubkeys[0], env.hotkey_ss58s[0]

    env.deposit_and_wrap(
        netuid, swapped_pubkey, swapped_ss58, config.DEPOSIT_RAO, 1_500_000, "Split position: the setup wrap failed",
    )
    shares = env.vault_shares(token_id)
    clone_coldkey = env.clone_coldkey(token_id)
    clone_ss58 = h160_to_ss58(env.clone_address(token_id))
    position = env.stake(swapped_pubkey, clone_coldkey, netuid)
    assert position > 0, "the setup left no stake under the hotkey about to be swapped"

    stranger_ss58 = extrinsics.keypair_ss58(STRANGER)
    stranger_pubkey = extrinsics.keypair_pubkey(STRANGER)
    extrinsics.fund_account(stranger_ss58, STRANGER_FUNDING_RAO)
    extrinsics.add_stake(swapped_ss58, other_netuid, GIFT_BUDGET_RAO, signer_uri=STRANGER)
    gift = env.stake(swapped_pubkey, stranger_pubkey, other_netuid)
    assert gift > 0, "the stranger bought nothing to give"
    extrinsics.transfer_stake(clone_ss58, swapped_ss58, other_netuid, gift, signer_uri=STRANGER)
    split = env.stake(swapped_pubkey, clone_coldkey, other_netuid)
    assert split > 0, "the stranger's position did not land"
    assert extrinsics.staking_hotkeys(clone_ss58) == [swapped_ss58], "the clone lists the one hotkey it stakes under"

    successor_ss58 = extrinsics.keypair_ss58("//SplitSuccessor")
    successor_pubkey = extrinsics.keypair_pubkey("//SplitSuccessor")
    extrinsics.swap_hotkey(swapped_ss58, successor_ss58)
    assert extrinsics.hotkey_owner(swapped_ss58) == "", "the swap should leave the old hotkey unowned"
    assert env.stake(swapped_pubkey, clone_coldkey, netuid) == 0, "nothing stays behind on the attested subnet"
    assert env.stake(swapped_pubkey, clone_coldkey, other_netuid) == 0, "nothing stays behind on the other subnet"
    assert env.stake(successor_pubkey, clone_coldkey, netuid) >= position, "the position should follow the swap"
    assert env.stake(successor_pubkey, clone_coldkey, other_netuid) >= split, "the split part should follow too"
    assert extrinsics.staking_hotkeys(clone_ss58) == [successor_ss58], (
        "the swap renames the clone's list entry in place under the reject-growth flag"
    )
    assert env.resolved_hotkeys(token_id)[0] == successor_pubkey, "the vault should resolve the slot to the successor"
    assert env.backing_intact(token_id), "a followed swap is not a loss"
    assert env.write_off_deadline(token_id) == 0, "nothing is on file"

    located = hotkeys + [successor_pubkey]
    deposit = config.DEPOSIT_RAO // 10
    receipt = env.deposit_and_wrap(
        netuid, swapped_pubkey, successor_ss58, deposit, 1_500_000,
        "Split position: a deposit after the swap failed", label="wrap [followed swap]",
    )
    collected = env.deposited(receipt, netuid)
    joined = env.stake(successor_pubkey, clone_coldkey, netuid) - position
    assert joined >= collected - config.ROUNDING_DUST_SLOT_RAO, (
        f"the deposit should join the position on the successor: {joined} RAO of {collected}"
    )
    assert env.stake(swapped_pubkey, clone_coldkey, netuid) == 0, "the ownerless hotkey must receive nothing"

    exits.unwrap(
        env, token_id, shares // 2, "Split position: the partial exit failed", hotkeys=located,
        label="unwrap [followed swap]",
    )

    env.set_validator(netuid, successor_pubkey)
    before = env.stake(successor_pubkey, clone_coldkey, netuid)
    env.vault_send_between_epochs(
        netuid, 4_000_000, "Split position: the rebalance onto the successor failed", "rebalance(uint256)", netuid,
        label="rebalance [successor attested]",
    )
    assert env.stake(successor_pubkey, clone_coldkey, netuid) >= before, "the position already sits on the successor"

    receipt, _ = exits.unwrap(
        env, token_id, env.vault_shares(token_id), "Split position: the full exit failed", hotkeys=located,
    )
    exits.assert_drained(env, token_id, located, receipt, "Split position: full exit")

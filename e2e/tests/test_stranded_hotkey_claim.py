"""A validator's all-subnet swap leaves the vault's stake behind under a hotkey with no owner (F-1).

A stranger gives the clone a position under the attested hotkey on the other subnet. When the
validator then swaps that hotkey across all subnets, the clone's stake stays under the old
hotkey while its owner record goes. Deposits, rebalances and partial alpha exits refuse until
the registry acts. A TAO exit claims the hotkey for the clone that holds the stake, so the
vault's own staking list keeps its single entry, and sells. Once the registry names the
successor, a rebalance moves the position onto it, the waiting deposit wraps and the token exits.
"""
import pytest

from alpha_e2e import chain, config, exits, extrinsics
from alpha_e2e.substrate import h160_to_ss58

STRANGER = "//StrandingStranger"
STRANGER_FUNDING_RAO = 2 * config.RAO_PER_TAO
GIFT_BUDGET_RAO = config.RAO_PER_TAO // 2
RETIRED = "AttestedHotkeyRetired(bytes32)"


@pytest.mark.scenario
def test_a_stranded_hotkey_is_claimed_by_the_clone_holding_the_stake(env):
    netuid, other_netuid = env.netuids[0], env.netuids[1]
    token_id = env.token_ids[0]
    hotkeys = env.subnet_hotkey_pubkeys(0)
    stranded_pubkey, stranded_ss58 = env.hotkey_pubkeys[0], env.hotkey_ss58s[0]

    env.deposit_and_wrap(
        netuid, stranded_pubkey, stranded_ss58, config.DEPOSIT_RAO, 1_500_000, "Stranded: the setup wrap failed",
    )
    shares = env.vault_shares(token_id)
    clone_coldkey = env.clone_coldkey(token_id)
    clone_ss58 = h160_to_ss58(env.clone_address(token_id))
    vault_ss58 = h160_to_ss58(env.vault_address)
    stranded_rao = env.stake(stranded_pubkey, clone_coldkey, netuid)
    assert stranded_rao > 0, "the setup left no stake under the hotkey about to be swapped"
    assert len(extrinsics.staking_hotkeys(vault_ss58)) == 1, "the vault should list only its parking hotkey"

    stranger_ss58 = extrinsics.keypair_ss58(STRANGER)
    stranger_pubkey = extrinsics.keypair_pubkey(STRANGER)
    extrinsics.fund_account(stranger_ss58, STRANGER_FUNDING_RAO)
    extrinsics.add_stake(stranded_ss58, other_netuid, GIFT_BUDGET_RAO, signer_uri=STRANGER)
    gift = env.stake(stranded_pubkey, stranger_pubkey, other_netuid)
    assert gift > 0, "the stranger bought nothing to give"
    extrinsics.transfer_stake(clone_ss58, stranded_ss58, other_netuid, gift, signer_uri=STRANGER)
    assert env.stake(stranded_pubkey, clone_coldkey, other_netuid) > 0, "the stranger's position did not land"

    successor_ss58 = extrinsics.keypair_ss58("//StrandingSuccessor")
    successor_pubkey = extrinsics.keypair_pubkey("//StrandingSuccessor")
    extrinsics.swap_hotkey(stranded_ss58, successor_ss58)
    assert extrinsics.hotkey_owner(stranded_ss58) == "", "the swap should leave the old hotkey unowned"
    assert env.stake(stranded_pubkey, clone_coldkey, netuid) >= stranded_rao, "the clone's stake should stay behind"
    assert env.stake(successor_pubkey, clone_coldkey, netuid) == 0, "nothing of the clone's should follow the swap"
    assert env.backing_intact(token_id), "stake left behind is still located"
    assert env.write_off_deadline(token_id) == 0, "stake left behind is not a loss"

    deposit = config.DEPOSIT_RAO // 10
    env.send_to_mailbox(netuid, successor_ss58, deposit)
    env.assert_vault_reverts_with(
        RETIRED, 1_500_000, "Stranded: a wrap should refuse", "wrap(uint256,bytes32,uint256)",
        netuid, stranded_pubkey, 0, label="wrap [stranded, refused]",
    )
    env.assert_vault_reverts_with(
        RETIRED, 4_000_000, "Stranded: a rebalance should refuse", "rebalance(uint256)", netuid,
        label="rebalance [stranded, refused]",
    )
    env.assert_vault_reverts_with(
        RETIRED, 2_500_000, "Stranded: a partial alpha exit should refuse", "unwrap(uint256,uint256,bytes32,uint256)",
        token_id, shares // 4, env.wrapper_substrate_coldkey, 1, label="unwrap [stranded, refused]",
    )

    exit_hotkeys = hotkeys + [successor_pubkey]
    exits.unwrap_for_tao(
        env, token_id, shares // 4, "Stranded: the TAO exit should claim the hotkey and sell",
        hotkeys=exit_hotkeys, gas_limit=4_000_000, label="unwrapForTao [claims the stranded hotkey]",
    )
    assert extrinsics.hotkey_owner(stranded_ss58) == clone_ss58, "the clone holding the stake should own the hotkey"
    assert len(extrinsics.staking_hotkeys(vault_ss58)) == 1, "the claim must not touch the vault's staking list"
    assert stranded_ss58 in extrinsics.staking_hotkeys(clone_ss58), "the clone keeps the hotkey it already listed"

    env.set_validator(netuid, successor_pubkey)
    receipt = env.vault_send_between_epochs(
        netuid, 4_000_000, "Stranded: the rebalance onto the successor failed", "rebalance(uint256)", netuid,
        label="rebalance [successor attested]",
    )
    block = chain.receipt_block_number(receipt, "Stranded: rebalance onto the successor")
    position = env.stake(stranded_pubkey, clone_coldkey, netuid, block - 1)
    assert env.stake(stranded_pubkey, clone_coldkey, netuid, block) <= config.ROUNDING_DUST_SLOT_RAO, (
        "the position should leave the claimed hotkey"
    )
    landed = env.stake(successor_pubkey, clone_coldkey, netuid, block)
    assert abs(landed - position) <= config.ROUNDING_DUST_SLOT_RAO, (
        f"the successor should take the whole position: {landed} RAO of {position}"
    )
    assert env.hotkey_in_last_seen(token_id, successor_pubkey), "the record moves to the successor"

    receipt = env.wrap(
        netuid, successor_pubkey, 1_500_000, "Stranded: the waiting deposit should wrap onto the successor",
        label="wrap [successor attested]",
    )
    collected = env.deposited(receipt, netuid)
    assert collected >= deposit - config.ROUNDING_DUST_SLOT_RAO, (
        f"the wrap collected {collected} RAO of a {deposit} RAO deposit"
    )

    receipt, _ = exits.unwrap(
        env, token_id, env.vault_shares(token_id), "Stranded: the full exit failed", hotkeys=exit_hotkeys,
    )
    exits.assert_drained(env, token_id, exit_hotkeys, receipt, "Stranded: full exit")

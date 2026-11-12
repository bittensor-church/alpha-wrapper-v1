"""A vacated validator hotkey claimed by a stranger receives nothing once the vault has followed the swap.

A validator swaps its hotkey across all subnets, which carries the vault's stake to the
successor and leaves the old hotkey without an owner. The vault follows the chain's edge. A
stranger then claims the old hotkey. The emptied slot stays on the successor: deposits chosen
under the old hotkey land there, previews match what wrap and the exits pay, a rebalance keeps
the stake there, and once the registry names the successor the position exits in full.
"""
import pytest

from alpha_e2e import chain, config, exits, extrinsics, rails

STRANGER = "//SquatStranger"
STRANGER_FUNDING_RAO = 2 * config.RAO_PER_TAO


@pytest.mark.scenario
def test_every_rail_skips_a_vacated_hotkey_a_stranger_claimed(env):
    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    hotkeys = env.subnet_hotkey_pubkeys(0)
    vacated_pubkey, vacated_ss58 = hotkeys[0], env.subnet_hotkey_ss58s(0)[0]
    clone_coldkey = env.clone_coldkey(token_id)

    env.deposit_and_wrap(netuid, vacated_pubkey, vacated_ss58, config.DEPOSIT_RAO, 1_500_000, "Squatted hotkey: wrap failed")
    shares = env.vault_shares(token_id)

    successor_ss58 = extrinsics.keypair_ss58("//SquatSuccessor")
    successor_pubkey = extrinsics.keypair_pubkey("//SquatSuccessor")
    extrinsics.swap_hotkey(vacated_ss58, successor_ss58)
    assert extrinsics.hotkey_owner(vacated_ss58) == "", "the swap should leave the old hotkey unowned"
    assert env.stake(successor_pubkey, clone_coldkey, netuid) > 0, "the alpha did not follow the swap"
    assert env.backing_intact(token_id), "the vault should follow the chain's swap edge"

    located = hotkeys + [successor_pubkey]
    receipt, _ = exits.unwrap(env, token_id, shares, "Squatted hotkey: the full exit failed", hotkeys=located)
    exits.assert_drained(env, token_id, located, receipt, "Squatted hotkey: full exit")
    assert env.hotkey_in_last_seen(token_id, successor_pubkey), "the record should hold the successor"
    assert not env.hotkey_in_last_seen(token_id, vacated_pubkey), "the record should have left the old hotkey"

    stranger_ss58 = extrinsics.keypair_ss58(STRANGER)
    extrinsics.fund_account(stranger_ss58, STRANGER_FUNDING_RAO)
    extrinsics.associate_hotkey(vacated_ss58, signer_uri=STRANGER)
    assert extrinsics.hotkey_owner(vacated_ss58) == stranger_ss58, "the stranger did not take the hotkey"

    receipt = env.deposit_and_wrap(
        netuid, vacated_pubkey, successor_ss58, config.DEPOSIT_RAO // 10, 1_500_000,
        "Squatted hotkey: a deposit chosen under the claimed hotkey failed", label="wrap [claimed hotkey, empty token]",
    )
    block = chain.receipt_block_number(receipt, "Squatted hotkey: deposit into the emptied token")
    deposited = env.deposited(receipt, netuid)
    assert env.stake(vacated_pubkey, clone_coldkey, netuid, block) == 0, "the claimed hotkey must receive nothing"
    landed = env.stake_change(clone_coldkey, netuid, [successor_pubkey], block)
    assert abs(landed - deposited) <= config.ROUNDING_DUST_SLOT_RAO, (
        f"the deposit should land on the successor: {landed} RAO of {deposited}"
    )
    assert env.backing_intact(token_id), "the position is whole on the successor"

    rails.assert_rails_skip_hotkey(
        env, 0, vacated_pubkey, successor_ss58, vacated_pubkey, located, "claimed hotkey", "Squatted hotkey",
    )

    env.set_validator(netuid, successor_pubkey)
    receipt, _ = exits.unwrap(
        env, token_id, env.vault_shares(token_id), "Squatted hotkey: the exit after the update failed", hotkeys=located,
    )
    exits.assert_drained(env, token_id, located, receipt, "Squatted hotkey: exit after the update")
    assert extrinsics.hotkey_owner(vacated_ss58) == stranger_ss58, "the vault never touched the claimed hotkey"

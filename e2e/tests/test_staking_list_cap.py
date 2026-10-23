"""Walks a subnet clone's staking list to the last entry it may take and replaces the clone.

Each round attests a fresh validator and rebalances onto it, which lists it, then sends a
crumb under it on another subnet, which keeps its entry once the next round rotates it
out. The clone's own moves stop one entry short of the chain's cap, kept for the parking
hotkey, so a rebalance and a deposit onto a fresh validator revert `StakingListFull`.
`replaceClone` moves the position and all of the clone's TAO to a fresh clone that lists
only what it holds, the deposit lands there, `unstuckStake` brings a gift sent to the
retired clone into the backing, and the token exits in full.

Gas rows: deposit and `previewUnwrap` on the fresh clone; deposit, partial exit and
`previewUnwrap` on the full list; the replacement; deposit, `previewUnwrap`, `unstuckStake`
and full exit on the successor.
"""
import secrets

import pytest

from alpha_e2e import chain, config, exits, extrinsics
from alpha_e2e.substrate import h160_to_ss58, h160_to_substrate_b32

STRANGER = "//CapStranger"
OWNER = "//CapOwner"
OWN_CAP = 256
PARKING_RESERVE = 1


@pytest.mark.scenario
def test_list_reaches_the_cap_and_replacement_reopens_it(env):
    netuid, other_netuid, _ = env.netuids
    token_id = env.token_ids[0]
    clone = env.clone_address(token_id)
    clone_ss58 = h160_to_ss58(clone)
    first_validator, first_validator_ss58 = env.hotkey_pubkeys[0], env.hotkey_ss58s[0]
    rounds = OWN_CAP - PARKING_RESERVE - 1
    validators = [
        (extrinsics.keypair_pubkey(f"{STRANGER}//{i}"), extrinsics.keypair_ss58(f"{STRANGER}//{i}"))
        for i in range(rounds + 1)
    ]
    last_listed, _ = validators[rounds - 1]
    spare, _ = validators[rounds]

    def listed(address: str) -> int:
        return len(extrinsics.staking_hotkeys(h160_to_ss58(address)))

    def preview_gas(tag: str) -> None:
        chain.report_view_gas(
            f"previewUnwrap [{tag}]", env.lens_address, "previewUnwrap(uint256,uint256)",
            token_id, env.vault_shares(token_id),
        )

    env.deposit_and_wrap(
        netuid, first_validator, first_validator_ss58, config.DEPOSIT_RAO, 1_500_000,
        "Cap, fresh clone: wrap failed",
    )
    preview_gas("Cap, fresh clone")
    extrinsics.fund_account(extrinsics.keypair_ss58(STRANGER), 30 * config.RAO_PER_TAO)
    extrinsics.fund_account(extrinsics.keypair_ss58(OWNER), 5 * config.RAO_PER_TAO)
    extrinsics.associate_hotkeys([ss58 for _, ss58 in validators], signer_uri=OWNER)
    extrinsics.add_stakes(
        [first_validator_ss58] + [ss58 for _, ss58 in validators[:rounds]], other_netuid,
        2 * env.chain_min_stake_tao(), signer_uri=STRANGER,
    )
    _, crumb = env.floor_boundary(other_netuid, env.chain_min_stake_tao())
    extrinsics.transfer_stake(clone_ss58, first_validator_ss58, other_netuid, crumb, signer_uri=STRANGER)

    for i in range(rounds):
        pubkey, ss58 = validators[i]
        env.set_validator(netuid, pubkey)
        env.vault_send(4_000_000, f"Cap: rebalance onto validator {i} failed", "rebalance(uint256)", netuid)
        extrinsics.transfer_stake(clone_ss58, ss58, other_netuid, crumb, signer_uri=STRANGER)
        if (i + 1) % 32 == 0:
            print(f"  {i + 1} validators rotated; the clone lists {listed(clone)} hotkeys")
    assert listed(clone) == OWN_CAP - PARKING_RESERVE, f"the clone lists {listed(clone)} hotkeys, expected the last admitted entry"

    held = [first_validator] + [pubkey for pubkey, _ in validators[:rounds]]
    env.send_to_mailbox(netuid, first_validator_ss58, config.DEPOSIT_RAO)
    env.wrap(netuid, last_listed, 2_500_000, "Cap, full list: the deposit onto the listed validator failed")
    preview_gas("Cap, full list")
    exits.unwrap(
        env, token_id, env.vault_shares(token_id) // 4, "Cap, full list: the partial exit failed", hotkeys=held,
        gas_limit=4_000_000,
    )

    env.set_validator(netuid, spare)
    env.assert_vault_reverts_with(
        "StakingListFull()", 4_000_000, "Cap: a rebalance onto an unlisted validator should hit the cap",
        "rebalance(uint256)", netuid,
    )
    env.send_to_mailbox(netuid, first_validator_ss58, config.DEPOSIT_RAO)
    env.assert_vault_reverts_with(
        "StakingListFull()", 1_500_000, "Cap: a deposit onto an unlisted validator should hit the cap",
        "wrap(uint256,bytes32,uint256)", netuid, spare, 0,
    )

    shares = env.vault_shares(token_id)
    pile = env.stake(last_listed, env.clone_coldkey(token_id), netuid)
    extrinsics.fund_account(h160_to_ss58(clone), config.RAO_PER_TAO)
    tao_shown = chain.cast_balance_wei(clone)
    env.replace_clone(token_id, "0x" + secrets.token_hex(32), "Cap: replacing the clone failed")
    successor = env.clone_address(token_id)
    assert successor.lower() != clone.lower(), "the token has no fresh clone"
    assert chain.cast_balance_wei(clone) == 0, "the old clone kept TAO"
    assert chain.cast_balance_wei(successor) == tao_shown, "the successor shows a different TAO balance"
    assert env.vault_shares(token_id) == shares, "shares changed with the clone"
    assert listed(successor) == 1, f"the successor lists {listed(successor)} hotkeys, expected the one it holds"
    assert env.vault_total_stake(token_id) >= pile - config.ROUNDING_DUST_SLOT_RAO, "the position shrank with the clone"
    env.wrap(netuid, spare, 2_500_000, "Cap, successor: the deposit should land once the list has room")
    assert env.stake(spare, env.clone_coldkey(token_id), netuid) > 0, "the fresh validator holds the deposit"
    assert listed(clone) == OWN_CAP - PARKING_RESERVE, "the crumbs keep every entry on the old clone"
    preview_gas("Cap, successor")

    retired_coldkey = h160_to_substrate_b32(clone)
    gifted_validator, gifted_validator_ss58 = validators[0]
    extrinsics.add_stake(gifted_validator_ss58, netuid, config.RAO_PER_TAO, signer_uri=STRANGER)
    _, gift = env.floor_boundary(netuid, 2 * env.chain_min_stake_tao())
    extrinsics.transfer_stake(clone_ss58, gifted_validator_ss58, netuid, gift, signer_uri=STRANGER)
    gifted = env.stake(gifted_validator, retired_coldkey, netuid)
    assert gifted >= gift - config.ROUNDING_DUST_SLOT_RAO, "the gift did not reach the retired clone"
    backing = env.vault_total_stake(token_id)
    env.vault_send(
        4_000_000, "Cap, retired clone: unstucking the gift failed", "unstuckStake(uint256,address,bytes32)",
        token_id, clone, gifted_validator, label="unstuckStake",
    )
    assert env.stake(gifted_validator, retired_coldkey, netuid) <= config.ROUNDING_DUST_SLOT_RAO, "the retired clone kept the gift"
    assert env.vault_total_stake(token_id) >= backing + gifted - config.ROUNDING_DUST_SLOT_RAO, (
        "the gift did not join the backing"
    )

    receipt, _ = exits.unwrap(
        env, token_id, env.vault_shares(token_id), "Cap, successor: the full exit failed", hotkeys=[spare],
    )
    exits.assert_drained(env, token_id, [spare], receipt, "Cap, successor: full exit")

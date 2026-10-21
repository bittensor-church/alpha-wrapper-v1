"""Walks a subnet clone's staking list to the last entry it may take and replaces the clone. Local only.

Each round attests a fresh validator and rebalances onto it, which lists it, then sends a
crumb under it on another subnet, which keeps its entry once the next round rotates it
out. The clone's own moves stop one entry short of the chain's cap, kept for the parking
hotkey, so a rebalance and a deposit onto a fresh validator revert `StakingListFull`.
`replaceClone` moves the position to a fresh clone that lists only what it holds, the
deposit lands there, and the token exits in full.

Kept out of the CI matrix on purpose: about 800 transactions take around two hours at the
localnet's 12-second blocks, far past the 30-minute job limit, and the cap behaviour it
proves on chain is covered by the unit tests' modelled list. Run it locally when the
staking-list code changes.
"""
import secrets

import pytest

from alpha_e2e import config, exits, extrinsics
from alpha_e2e.substrate import h160_to_ss58

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
    spare, _ = validators[rounds]

    def listed(address: str) -> int:
        return len(extrinsics.staking_hotkeys(h160_to_ss58(address)))

    env.deposit_and_wrap(
        netuid, first_validator, first_validator_ss58, config.DEPOSIT_RAO, 1_500_000, "Cap: wrap failed",
    )
    shares = env.vault_shares(token_id)
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

    env.replace_clone(token_id, "0x" + secrets.token_hex(32), "Cap: replacing the clone failed")
    successor = env.clone_address(token_id)
    assert successor.lower() != clone.lower(), "the token has no fresh clone"
    assert env.vault_shares(token_id) == shares, "shares changed with the clone"
    assert listed(successor) == 1, f"the successor lists {listed(successor)} hotkeys, expected the one it holds"
    assert env.vault_total_stake(token_id) >= config.DEPOSIT_RAO - config.ROUNDING_DUST_SLOT_RAO
    env.wrap(netuid, spare, 2_500_000, "Cap: the deposit should land once the list has room")
    assert env.stake(spare, env.clone_coldkey(token_id), netuid) > 0, "the fresh validator holds the deposit"
    assert listed(clone) == OWN_CAP - PARKING_RESERVE, "the crumbs keep every entry on the old clone"

    receipt, _ = exits.unwrap(env, token_id, env.vault_shares(token_id), "Cap: the full exit failed", hotkeys=[spare])
    exits.assert_drained(env, token_id, [spare], receipt, "Cap: full exit")

"""Walks a subnet clone's staking list up to the chain's cap and back. Local only.

Each round attests a fresh validator and rebalances onto it, which lists it, then sends a
crumb under it on another subnet, which keeps its entry once the next round rotates it
out. At 256 entries the chain refuses the clone's move onto a hotkey it does not list, so a
rebalance and a deposit onto a fresh validator revert `StakingListFull`. One sale makes
room and the deposit lands; selling the rest in batches shrinks the list back to the
hotkeys that still hold stake. About two hours at 12-second blocks.
"""
import pytest

from alpha_e2e import config, exits, extrinsics
from alpha_e2e.substrate import h160_to_ss58

STRANGER = "//CapStranger"
OWN_CAP = 256
SALE_BATCH = 8


@pytest.mark.scenario
def test_list_reaches_the_cap_and_sales_reopen_it(env):
    netuid, other_netuid, _ = env.netuids
    token_id = env.token_ids[0]
    clone_ss58 = h160_to_ss58(env.clone_address(token_id))
    clone_coldkey = env.clone_coldkey(token_id)
    first_validator, first_validator_ss58 = env.hotkey_pubkeys[0], env.hotkey_ss58s[0]
    rounds = OWN_CAP - 1
    validators = [
        (extrinsics.keypair_pubkey(f"{STRANGER}//{i}"), extrinsics.keypair_ss58(f"{STRANGER}//{i}"))
        for i in range(rounds + 1)
    ]
    spare, _ = validators[rounds]

    def listed() -> int:
        return len(extrinsics.staking_hotkeys(clone_ss58))

    env.deposit_and_wrap(
        netuid, first_validator, first_validator_ss58, config.DEPOSIT_RAO, 1_500_000, "Cap: wrap failed",
    )
    extrinsics.fund_account(extrinsics.keypair_ss58(STRANGER), 30 * config.RAO_PER_TAO)
    extrinsics.associate_hotkeys([ss58 for _, ss58 in validators], signer_uri=STRANGER)
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
            print(f"  {i + 1} validators rotated; the clone lists {listed()} hotkeys")
    assert listed() == OWN_CAP, f"the clone lists {listed()} hotkeys, expected the cap"

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

    env.sell_other_subnet_stake(token_id, [other_netuid], [first_validator], "Cap: selling one crumb failed")
    assert listed() == OWN_CAP - 1, "one sale frees one entry"
    env.wrap(netuid, spare, 2_500_000, "Cap: the deposit should land once the list has room")
    assert env.stake(spare, clone_coldkey, netuid) > 0, "the fresh validator holds the deposit"

    crumbed = [pubkey for pubkey, _ in validators[:rounds]]
    for start in range(0, len(crumbed), SALE_BATCH):
        batch = crumbed[start:start + SALE_BATCH]
        env.sell_other_subnet_stake(token_id, [other_netuid] * len(batch), batch, f"Cap: sale batch {start} failed")
    funded = sum(
        env.stake(pubkey, clone_coldkey, netuid) > 0 for pubkey in [first_validator, spare] + crumbed
    )
    assert listed() == funded, f"the clone lists {listed()} hotkeys while {funded} hold stake"

    receipt, _ = exits.unwrap(env, token_id, env.vault_shares(token_id), "Cap: the full exit failed", hotkeys=[spare])
    exits.assert_drained(env, token_id, [spare], receipt, "Cap: full exit")

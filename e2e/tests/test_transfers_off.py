"""Scenario: alpha transfers switched off.

When a subnet's alpha transfers are disabled, the chain refuses to move
staked alpha between wallets but still allows selling it for TAO. A wrapped
position and a mailbox deposit are seeded while transfers are on; once they
are off, the vault's alpha rail (which delivers by moving staked alpha)
refuses, while both TAO rails still pay out at the chain's quote: they only
ever sell alpha for TAO.
"""
import pytest

from alpha_e2e import checks, config, exits, extrinsics
from alpha_e2e.substrate import h160_to_ss58


@pytest.mark.scenario
def test_disabling_alpha_transfers_preserves_both_tao_exit_rails(env):
    position_netuid = env.netuids[0]
    position_token_id = env.token_ids[0]
    position_hotkeys = env.subnet_hotkey_pubkeys(0)
    position_hotkey_ss58 = env.subnet_hotkey_ss58s(0)[0]

    receipt = env.deposit_and_wrap(
        position_netuid, position_hotkeys[0], position_hotkey_ss58,
        config.DEPOSIT_RAO, 1_500_000, "wrap for transfers-off setup failed",
    )
    position_shares = env.vault_shares(position_token_id)
    checks.assert_first_deposit_shares(
        position_shares, env.deposited(receipt, position_netuid), "transfers-off setup wrap",
    )

    seed_netuid = env.netuids[1]
    seed_mailbox_ss58 = h160_to_ss58(env.mailbox_address(seed_netuid))

    env.send_to_mailbox(seed_netuid, env.subnet_hotkey_ss58s(1)[0], config.DEPOSIT_RAO)
    seed_alpha = env.mailbox_deposit(seed_netuid)
    assert config.DEPOSIT_RAO - config.ROUNDING_DUST_SLOT_RAO <= seed_alpha <= config.DEPOSIT_RAO, (
        f"the mailbox holds {seed_alpha} RAO after a {config.DEPOSIT_RAO} RAO transfer"
    )

    for netuid in env.netuids:
        extrinsics.toggle_transfer(netuid, False)
        print(f"  netuid {netuid}: alpha transfers disabled")

    with pytest.raises(extrinsics.ExtrinsicError) as refused_transfer:
        extrinsics.transfer_stake(
            seed_mailbox_ss58, position_hotkey_ss58, position_netuid, config.DEPOSIT_RAO,
        )
    assert "TransferDisallowed" in str(refused_transfer.value), (
        f"transferStake reverted but not with TransferDisallowed: {refused_transfer.value}"
    )

    env.assert_vault_reverts_with(
        "AlphaTransfersDisabled(uint16)", 2_000_000,
        "unwrap (alpha rail) did NOT revert with transfers off",
        "unwrap(uint256,uint256,bytes32,uint256)",
        position_token_id, position_shares, env.wrapper_substrate_coldkey, 0, error_args=(position_netuid,),
    )

    receipt, sold_alpha = exits.unwrap_for_tao(
        env, position_token_id, position_shares, "unwrapForTao with transfers off", hotkeys=position_hotkeys,
    )
    assert env.vault_shares(position_token_id) == 0, "shares left after unwrapForTao"
    exits.assert_drained(env, position_token_id, position_hotkeys, receipt, "unwrapForTao with transfers off")
    print(f"  Deposit clone withdrawn as TAO: sold {sold_alpha} alpha RAO at the chain's quote")

    sold_alpha = exits.reclaim_mailbox_alpha_as_tao(env, seed_netuid, "reclaimMailboxAlphaAsTao with transfers off")
    print(f"  Mailbox withdrawn as TAO: sold {sold_alpha} alpha RAO at the chain's quote")

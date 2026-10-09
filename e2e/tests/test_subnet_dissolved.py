"""Scenario: subnet deregistration (dissolution).

Dissolving (deregistering) a subnet returns its staked alpha to holders as
native TAO. Two users wrap a shared position on one subnet, and raw alpha is
parked in a never-wrapped mailbox on another; the test dissolves both and
checks each user recovers their pro-rata share of the position, and the
parked (unprocessed) mailbox alpha is recoverable as native TAO too -- while
the alpha-selling exits no longer apply and a position on an untouched subnet
keeps exiting normally.

  Phase 6   two users wrap positions on the soon-dissolved subnet
  Phase 7   park raw alpha in a never-wrapped mailbox on a second subnet
  Phase 8   seed a control position on a subnet that will NOT be dissolved
  Phase 9   dissolve both the position's subnet and the mailbox's subnet
  Phase 10  alpha-selling exits revert -- dissolution left no alpha to sell
  Phase 11  both users recover their pro-rata slice of the refund as native TAO
  Phase 12  recover the never-wrapped mailbox as native TAO
  Phase 13  the untouched subnet still exits normally (dissolution was scoped)
"""
import pytest

from alpha_e2e import chain, checks, config, exits, extrinsics
from alpha_e2e.checks import run_observability_script
from alpha_e2e.substrate import h160_to_ss58, h160_to_substrate_b32


@pytest.mark.scenario
def test_dissolution_refunds_holders_and_mailboxes_without_affecting_other_subnets(env):
    # --- Phase 6: two users wrap positions on the soon-dissolved subnet ---------
    dissolved_netuid = env.netuids[0]
    dissolved_token_id = env.token_ids[0]
    dissolved_hotkey_pubkey = env.hotkey_pubkeys[0]
    dissolved_hotkey_ss58 = env.hotkey_ss58s[0]
    volume_block_start = chain.cast_block_number()

    # The deployer key doubles as a second share-holder so the dissolved payout
    # splits pro-rata.
    second_user_address = config.DEPLOYER_ADDRESS
    second_user_private_key = config.DEPLOYER_PRIVATE_KEY

    receipt = env.deposit_and_wrap(
        dissolved_netuid, dissolved_hotkey_pubkey, dissolved_hotkey_ss58,
        config.DEPOSIT_RAO, 1_500_000, "primary-user wrap failed",
    )
    first_user_shares = env.vault_shares(dissolved_token_id)
    checks.assert_first_deposit_shares(
        first_user_shares, env.deposited(receipt, dissolved_netuid, dissolved_hotkey_pubkey), "primary-user wrap",
    )
    env.deposit_and_wrap(
        dissolved_netuid, dissolved_hotkey_pubkey, dissolved_hotkey_ss58,
        config.DEPOSIT_RAO, 1_500_000, "second-user wrap failed",
        user=second_user_address, private_key=second_user_private_key,
    )
    second_user_shares = env.vault_shares(dissolved_token_id, second_user_address)
    assert second_user_shares != 0, f"no shares minted for user2 on netuid {dissolved_netuid}"
    dissolved_clone = env.clone_address(dissolved_token_id)
    assert chain.cast_balance_wei(dissolved_clone) == 0, (
        "clone holds native TAO before dissolution"
    )
    print(f"  netuid {dissolved_netuid} (tokenId {dissolved_token_id}): "
          f"user1 {first_user_shares} + user2 {second_user_shares} shares, "
          f"clone {dissolved_clone} backed by alpha")

    # --- Phase 7: park raw alpha in a never-wrapped mailbox on a second subnet ---
    parked_netuid = env.netuids[2]
    parked_hotkey_pubkey = env.hotkey_pubkeys[6]
    parked_hotkey_ss58 = env.hotkey_ss58s[6]
    parked_mailbox = env.mailbox_address(parked_netuid)
    parked_mailbox_coldkey = h160_to_substrate_b32(parked_mailbox)
    print(f"  User mailbox on netuid {parked_netuid}: {parked_mailbox}")

    extrinsics.transfer_stake(
        h160_to_ss58(parked_mailbox), parked_hotkey_ss58, parked_netuid, config.DEPOSIT_RAO,
    )
    parked_alpha = env.stake(parked_hotkey_pubkey, parked_mailbox_coldkey, parked_netuid)
    assert parked_alpha > 0, "mailbox has zero alpha after seeding"
    print(f"  Mailbox stake: {parked_alpha} RAO under {parked_hotkey_pubkey[:18]}...")

    # --- Phase 8: seed a control position on a subnet that will NOT be dissolved --
    surviving_netuid = env.netuids[1]
    surviving_token_id = env.token_ids[1]
    surviving_hotkeys = env.subnet_hotkey_pubkeys(1)

    env.deposit_and_wrap(
        surviving_netuid, surviving_hotkeys[0], env.hotkey_ss58s[3],
        config.DEPOSIT_RAO, 1_500_000, "wrap for the control position failed",
    )
    surviving_shares = env.vault_shares(surviving_token_id)
    assert surviving_shares != 0, f"no shares minted by wrap on netuid {surviving_netuid}"
    print(f"  netuid {surviving_netuid} (tokenId {surviving_token_id}): "
          f"{surviving_shares} shares")

    # --- Phase 9: dissolve both the position's subnet and the mailbox's subnet ----
    extrinsics.dissolve_network(dissolved_netuid)
    extrinsics.dissolve_network(parked_netuid)
    env.wait_for_dissolution_cleanup(dissolved_netuid)
    env.wait_for_dissolution_cleanup(parked_netuid)

    # Dissolution returns the position's and mailbox's alpha as native TAO to
    # their addresses, so those balances turn positive as the alpha is wiped.
    dissolved_clone_tao = chain.cast_balance_wei(dissolved_clone)
    parked_mailbox_tao = chain.cast_balance_wei(parked_mailbox)
    assert dissolved_clone_tao >= 1, "position clone received no TAO refund after dissolution"
    assert parked_mailbox_tao >= 1, "mailbox received no TAO refund after dissolution"
    assert env.vault_total_stake(dissolved_token_id) == 0, "totalStake nonzero after dissolution"

    share_price_probe = chain.probe_call(env.lens_address, "sharePrice(uint256)(uint256)", dissolved_token_id)
    share_price_output = share_price_probe.stdout + share_price_probe.stderr
    assert share_price_probe.returncode != 0 and (
        "SubnetDissolved" in share_price_output or chain.cast_sig("SubnetDissolved()") in share_price_output
    ), f"sharePrice did not revert as SubnetDissolved for the dissolved subnet: {share_price_output}"
    print(f"  Dissolved: position clone holds {dissolved_clone_tao} wei, mailbox "
          f"{parked_mailbox_tao} wei; alpha zeroed, sharePrice reverts")

    # --- Phase 10: alpha-selling exits revert - dissolution left no alpha to sell --
    env.assert_vault_reverts_with(
        "NothingToUnwrap()", 2_000_000, "unwrapForTao did NOT revert as NothingToUnwrap on the dissolved subnet",
        "unwrapForTao(uint256,uint256,uint256)", dissolved_token_id, first_user_shares, 0,
    )
    env.assert_vault_reverts_with(
        "ZeroAmount()", 1_500_000, "reclaimMailboxAlphaAsTao did NOT revert as ZeroAmount on wiped mailbox alpha",
        "reclaimMailboxAlphaAsTao(uint256,bytes32,uint256)",
        parked_netuid, parked_hotkey_pubkey, 0,
    )

    # --- Phase 11: both users recover their pro-rata slice as native TAO ----------
    clone_tao_before = chain.cast_balance_wei(dissolved_clone)
    total_shares = first_user_shares + second_user_shares
    _, previewed_tao = env.preview_unwrap(dissolved_token_id, first_user_shares)

    first_user_tao_before = env.user_tao_wei()
    first_receipt = env.vault_send(
        2_000_000, "user1 dissolved unwrap failed",
        "unwrap(uint256,uint256,bytes32,uint256)",
        dissolved_token_id, first_user_shares, env.wrapper_substrate_coldkey, 0,
    )
    assert env.vault_shares(dissolved_token_id) == 0, (
        "user1 shares not burned after the dissolved unwrap"
    )
    first_user_gain = checks.reconstructed_payout(
        first_user_tao_before, env.user_tao_wei(), first_receipt, "user1 dissolved payout",
    )
    assert first_user_gain == previewed_tao, "user1's refund differs from the preview"
    assert first_user_gain % config.WEI_PER_RAO == 0, "native TAO moves in whole RAO"
    # Flooring user1's refund to whole RAO leaves under one RAO extra behind for user2.
    checks.assert_value_per_share_kept(
        clone_tao_before, total_shares, chain.cast_balance_wei(dissolved_clone), second_user_shares,
        config.WEI_PER_RAO, "user1's refund changed user2's value per share",
    )

    expected_second_user_tao = chain.cast_balance_wei(dissolved_clone) // config.WEI_PER_RAO * config.WEI_PER_RAO
    second_user_tao_before = chain.cast_balance_wei(second_user_address)
    second_receipt = env.vault_send(
        2_000_000, "user2 dissolved unwrap failed",
        "unwrap(uint256,uint256,bytes32,uint256)",
        dissolved_token_id, second_user_shares, env.wrapper_substrate_coldkey, 0,
        private_key=second_user_private_key,
    )
    assert env.vault_shares(dissolved_token_id, second_user_address) == 0, (
        "user2 shares not burned after the dissolved unwrap"
    )
    second_user_gain = checks.reconstructed_payout(
        second_user_tao_before, chain.cast_balance_wei(second_user_address), second_receipt,
        "user2 dissolved payout",
    )
    assert second_user_gain == expected_second_user_tao, "the last holder did not receive the remaining refund"

    clone_tail = chain.cast_balance_wei(dissolved_clone)
    assert clone_tail < 2 * config.WEI_PER_RAO, (
        f"clone kept {clone_tail} wei after both users unwrapped; "
        "each exit may leave at most a sub-RAO tail"
    )
    print(f"  Pro-rata recovery: user1 +{first_user_gain} wei "
          f"user2 +{second_user_gain} wei; "
          f"clone tail {clone_tail} wei")

    volume_block_end = chain.cast_block_number()
    checks.assert_csv(
        run_observability_script(
            "get_volumes", "--token-id", str(dissolved_token_id),
            address_args=["--vault-address", env.vault_address],
            block_start=volume_block_start, block_end=volume_block_end,
        ),
        rows=1,
        column_eq={
            "token_id": str(dissolved_token_id),
            "user": "",
            "deposit_count": "2",
            "alpha_unwrap_count": "0",
            "tao_unwrap_count": "0",
            "dissolved_unwrap_count": "2",
            "unwrap_count": "2",
            "tao_from_alpha_sales_wei": "0",
        },
        column_positive=[
            "alpha_deposited_rao", "shares_minted", "dissolved_unwrap_shares_burned",
            "tao_from_dissolutions_wei", "shares_burned", "tao_received_wei",
        ],
    )
    print("  get_volumes reports dissolved TAO separately from live alpha volume")

    # --- Phase 12: recover the never-wrapped mailbox as native TAO -----------------
    parked_mailbox_tao_before = chain.cast_balance_wei(parked_mailbox)
    user_tao_before = env.user_tao_wei()
    mailbox_receipt = env.vault_send(
        2_000_000, "reclaimTaoFromMailbox failed",
        "reclaimTaoFromMailbox(uint256)", parked_netuid,
    )

    assert chain.cast_balance_wei(parked_mailbox) == 0, (
        "mailbox not fully drained after reclaimTaoFromMailbox"
    )
    gained = checks.reconstructed_payout(
        user_tao_before, env.user_tao_wei(), mailbox_receipt, "mailbox refund",
    )
    assert gained == parked_mailbox_tao_before, "mailbox reclaim paid less than the drained balance"
    print(f"  Never-wrapped mailbox recovered ({parked_mailbox_tao_before} wei): "
          f"user net +{gained} wei, mailbox drained to 0")

    # --- Phase 13: the untouched subnet still exits normally -----------------------
    receipt, sold_alpha = exits.unwrap_for_tao(
        env, surviving_token_id, surviving_shares, "unwrapForTao on the surviving subnet", hotkeys=surviving_hotkeys,
    )
    assert env.vault_shares(surviving_token_id) == 0, (
        "shares still outstanding after unwrapForTao on the live subnet"
    )
    exits.assert_drained(env, surviving_token_id, surviving_hotkeys, receipt, "unwrapForTao on the surviving subnet")
    print(f"  Surviving subnet sold {sold_alpha} alpha RAO at the chain's quote; "
          f"dissolution was scoped to netuid {dissolved_netuid}")

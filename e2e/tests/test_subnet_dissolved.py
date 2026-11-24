"""Scenario: subnet deregistration (dissolution).

Dissolving (deregistering) a subnet returns its staked alpha to holders as
native TAO. Two users wrap a shared position on one subnet, raw alpha sits in a
never-wrapped mailbox on another, and a third subnet holds a control position.
Both of the first two subnets are dissolved: the alpha-selling exits refuse, each
user redeems their pro-rata slice of the refund as native TAO, the mailbox's
refund is reclaimed in full, and the control position still exits normally.
"""
import pytest

from alpha_e2e import chain, checks, config, exits, extrinsics
from alpha_e2e.checks import assert_csv_rows, run_observability_script, volume_row


@pytest.mark.scenario
def test_dissolution_refunds_holders_and_mailboxes_without_affecting_other_subnets(env):
    dissolved_netuid = env.netuids[0]
    dissolved_token_id = env.token_ids[0]
    dissolved_hotkey_pubkey = env.subnet_hotkey_pubkeys(0)[0]
    dissolved_hotkey_ss58 = env.subnet_hotkey_ss58s(0)[0]
    volume_block_start = chain.cast_block_number()

    # The deployer key is the second holder, so the refund splits pro-rata.
    second_user_address = config.DEPLOYER_ADDRESS
    second_user_private_key = config.DEPLOYER_PRIVATE_KEY

    first_wrap = env.deposit_and_wrap(
        dissolved_netuid, dissolved_hotkey_pubkey, dissolved_hotkey_ss58,
        config.DEPOSIT_RAO, 1_500_000, "primary-user wrap failed",
    )
    first_deposited = env.deposited(first_wrap, dissolved_netuid)
    first_user_shares = env.vault_shares(dissolved_token_id)
    checks.assert_first_deposit_shares(first_user_shares, first_deposited, "primary-user wrap")
    second_wrap = env.deposit_and_wrap(
        dissolved_netuid, dissolved_hotkey_pubkey, dissolved_hotkey_ss58,
        config.DEPOSIT_RAO, 1_500_000, "second-user wrap failed",
        user=second_user_address, private_key=second_user_private_key,
    )
    second_deposited = env.deposited(second_wrap, dissolved_netuid, second_user_address)
    second_user_shares = checks.assert_wrap_kept_value_per_share(
        env, dissolved_token_id, second_wrap, env.subnet_hotkey_pubkeys(0), "second-user wrap",
    )
    assert env.vault_shares(dissolved_token_id, second_user_address) == second_user_shares, (
        "the second user should hold exactly the shares the wrap minted"
    )
    dissolved_clone = env.clone_address(dissolved_token_id)
    assert chain.cast_balance_wei(dissolved_clone) == 0, (
        "clone holds native TAO before dissolution"
    )
    print(f"  netuid {dissolved_netuid} (tokenId {dissolved_token_id}): "
          f"user1 {first_user_shares} + user2 {second_user_shares} shares, "
          f"clone {dissolved_clone} backed by alpha")

    parked_netuid = env.netuids[2]
    parked_mailbox = env.mailbox_address(parked_netuid)
    print(f"  User mailbox on netuid {parked_netuid}: {parked_mailbox}")

    env.send_to_mailbox(parked_netuid, env.subnet_hotkey_ss58s(2)[0], config.DEPOSIT_RAO)
    parked_alpha = env.mailbox_deposit(parked_netuid)
    assert config.DEPOSIT_RAO - config.ROUNDING_DUST_SLOT_RAO <= parked_alpha <= config.DEPOSIT_RAO, (
        f"the mailbox holds {parked_alpha} RAO after a {config.DEPOSIT_RAO} RAO transfer"
    )
    print(f"  Mailbox stake: {parked_alpha} RAO on its own hotkey")

    surviving_netuid = env.netuids[1]
    surviving_token_id = env.token_ids[1]
    surviving_hotkeys = env.subnet_hotkey_pubkeys(1)

    surviving_wrap = env.deposit_and_wrap(
        surviving_netuid, surviving_hotkeys[0], env.subnet_hotkey_ss58s(1)[0],
        config.DEPOSIT_RAO, 1_500_000, "wrap for the control position failed",
    )
    surviving_shares = env.vault_shares(surviving_token_id)
    checks.assert_first_deposit_shares(
        surviving_shares, env.deposited(surviving_wrap, surviving_netuid), "control position wrap",
    )
    print(f"  netuid {surviving_netuid} (tokenId {surviving_token_id}): "
          f"{surviving_shares} shares")

    extrinsics.dissolve_network(dissolved_netuid)
    extrinsics.dissolve_network(parked_netuid)
    env.wait_for_dissolution_cleanup(dissolved_netuid)
    env.wait_for_dissolution_cleanup(parked_netuid)

    dissolved_clone_tao = chain.cast_balance_wei(dissolved_clone)
    parked_mailbox_tao = chain.cast_balance_wei(parked_mailbox)
    assert dissolved_clone_tao > 0, "position clone received no TAO refund after dissolution"
    assert parked_mailbox_tao > 0, "mailbox received no TAO refund after dissolution"
    assert env.vault_total_stake(dissolved_token_id) == 0, "totalStake nonzero after dissolution"

    share_price_revert = chain.revert_data(env.lens_address, "sharePrice(uint256)", dissolved_token_id)
    assert share_price_revert == chain.encoded_call("SubnetDissolved()"), (
        f"sharePrice should revert as SubnetDissolved for the dissolved subnet, reverts with {share_price_revert}"
    )
    print(f"  Dissolved: position clone holds {dissolved_clone_tao} wei, mailbox "
          f"{parked_mailbox_tao} wei; alpha zeroed, sharePrice reverts")

    env.assert_vault_reverts_with(
        "SubnetDissolved()", 2_000_000, "unwrapForTao did NOT revert as SubnetDissolved on the dissolved subnet",
        "unwrapForTao(uint256,uint256,uint256)", dissolved_token_id, first_user_shares, 0,
    )
    env.assert_vault_reverts_with(
        "ZeroAmount()", 1_500_000, "reclaimMailboxAlphaAsTao did NOT revert as ZeroAmount on wiped mailbox alpha",
        "reclaimMailboxAlphaAsTao(uint256,uint256)",
        parked_netuid, 0,
    )

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
    checks.assert_floored_pro_rata(
        first_user_gain, clone_tao_before, first_user_shares, total_shares, config.WEI_PER_RAO,
        "user1's refund should be their slice of the clone's TAO, in whole RAO",
    )
    assert first_user_gain == previewed_tao, (
        f"user1's refund {first_user_gain} wei differs from the preview {previewed_tao}"
    )
    clone_tao_after_first = chain.cast_balance_wei(dissolved_clone)
    assert clone_tao_after_first == clone_tao_before - first_user_gain, (
        f"the clone paid out {clone_tao_before - clone_tao_after_first} wei for a {first_user_gain} wei refund"
    )

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
    checks.assert_floored_pro_rata(
        second_user_gain, clone_tao_after_first, second_user_shares, second_user_shares, config.WEI_PER_RAO,
        "the last holder should receive the remaining refund, in whole RAO",
    )

    clone_tail = chain.cast_balance_wei(dissolved_clone)
    assert clone_tail == clone_tao_after_first - second_user_gain, (
        f"the clone kept {clone_tail} wei after paying {second_user_gain} of {clone_tao_after_first}"
    )
    print(f"  Pro-rata recovery: user1 +{first_user_gain} wei "
          f"user2 +{second_user_gain} wei; "
          f"clone tail {clone_tail} wei")

    volume_block_end = chain.cast_block_number()
    assert_csv_rows(
        run_observability_script(
            "get_volumes", "--token-id", str(dissolved_token_id),
            address_args=["--vault-address", env.vault_address],
            block_start=volume_block_start, block_end=volume_block_end,
        ),
        [volume_row(
            dissolved_token_id, "",
            deposit_count=2, alpha_deposited_rao=first_deposited + second_deposited, shares_minted=total_shares,
            dissolved_unwrap_count=2, dissolved_unwrap_shares_burned=total_shares,
            tao_from_dissolutions_wei=first_user_gain + second_user_gain,
            unwrap_count=2, shares_burned=total_shares, tao_received_wei=first_user_gain + second_user_gain,
        )],
        "get_volumes should report dissolved TAO apart from live alpha volume",
    )

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
    assert gained == parked_mailbox_tao_before, "mailbox reclaim paid other than the drained balance"
    print(f"  Never-wrapped mailbox recovered ({parked_mailbox_tao_before} wei): "
          f"user net +{gained} wei, mailbox drained to 0")

    receipt, sold_alpha = exits.unwrap_for_tao(
        env, surviving_token_id, surviving_shares, "unwrapForTao on the surviving subnet", hotkeys=surviving_hotkeys,
    )
    assert env.vault_shares(surviving_token_id) == 0, (
        "shares still outstanding after unwrapForTao on the live subnet"
    )
    exits.assert_drained(env, surviving_token_id, surviving_hotkeys, receipt, "unwrapForTao on the surviving subnet")
    print(f"  Surviving subnet sold {sold_alpha} alpha RAO at the chain's quote; "
          f"dissolution was scoped to netuid {dissolved_netuid}")

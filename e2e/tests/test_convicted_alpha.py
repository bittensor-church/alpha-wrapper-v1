"""Scenario: convicted (conviction-locked) alpha.

Conviction locks bind a coldkey's subnet-wide alpha, and contract-controlled
coldkeys reject locked inflow (creation verifies the chain's rejection default).
A deposit dipping into locked mass therefore reverts at the depositor's own transferStake, before the vault is involved; the free
portion wraps normally; and vault flows -- rebalance, unwrap (including to a
coldkey that itself holds a lock), unwrapForTao -- never touch lock state.

  Phase 6   Alice locks all but a movable margin of her subnet stake
  Phase 7   depositing MORE than the movable amount is refused by the chain,
            and the following wrap reverts on the empty mailbox
  Phase 8   the movable portion of the locked wallet wraps normally
  Phase 9   unwrap pays out to a coldkey that HOLDS an active lock
  Phase 10  unwrapForTao works while a large lock exists on the subnet
"""
import pytest

from alpha_e2e import checks, config, exits, extrinsics, substrate
from alpha_e2e.substrate import h160_to_ss58, h160_to_substrate_b32

UNLOCKED_MARGIN_RAO = 30_000_000_000  # 30 alpha


def _alice_locked_alpha(netuid: int, hotkey_ss58: str) -> int:
    return extrinsics.get_lock(config.ALICE_COLDKEY_SS58, netuid, hotkey_ss58)


@pytest.mark.scenario
def test_convicted_alpha(env):
    test_netuid = env.netuids[0]
    test_token_id = env.token_ids[0]
    test_hotkey_pubkey = env.hotkey_pubkeys[0]
    test_hotkey_ss58 = env.hotkey_ss58s[0]

    subnet_hotkeys = env.subnet_hotkey_pubkeys(0)
    user_mailbox = env.mailbox_address(test_netuid)
    user_mailbox_coldkey = h160_to_substrate_b32(user_mailbox)
    user_mailbox_ss58 = h160_to_ss58(user_mailbox)
    alice_owner_hotkey_pubkey = substrate.read_hotkey_pubkey(
        config.ALICE_WALLET, config.ALICE_HOTKEY_NAME,
    )

    def alice_subnet_alpha() -> int:
        # Locks bind Alice's subnet-wide alpha across ALL her hotkeys, including
        # the subnet-owner hotkey. The subnet-wide TAO-value getter cannot size
        # the lock: it returns TAO value, not the alpha the lock is denominated in.
        return env.total_stake_across(
            config.ALICE_COLDKEY_PUBKEY, test_netuid,
            [alice_owner_hotkey_pubkey, *subnet_hotkeys],
        )

    # --- Phase 6: Alice locks all but the movable margin of her subnet stake ------
    alice_subnet_alpha_before_lock = alice_subnet_alpha()
    assert alice_subnet_alpha_before_lock >= 2 * UNLOCKED_MARGIN_RAO, (
        "Alice's subnet stake too small to lock meaningfully"
    )
    lock_amount_rao = alice_subnet_alpha_before_lock - UNLOCKED_MARGIN_RAO

    print(f"  Alice subnet total: {alice_subnet_alpha_before_lock} RAO; locking "
          f"{lock_amount_rao} RAO to {test_hotkey_ss58[:12]}... (margin {UNLOCKED_MARGIN_RAO})")
    extrinsics.lock_stake(test_hotkey_ss58, test_netuid, lock_amount_rao)

    initial_locked_alpha = _alice_locked_alpha(test_netuid, test_hotkey_ss58)
    assert initial_locked_alpha == lock_amount_rao, (
        f"lock not registered exactly (asked {lock_amount_rao}, stored {initial_locked_alpha})"
    )
    print(f"  Lock live on chain: {initial_locked_alpha} RAO locked "
          f"(movable margin ~ {UNLOCKED_MARGIN_RAO} RAO + emissions)")

    # --- Phase 7: depositing MORE than the movable amount is refused by the chain --
    # The chain clamps: a transfer within the movable amount passes legitimately,
    # so the refused transfer must exceed movable (which keeps growing with emissions).
    over_movable_amount = env.stake(test_hotkey_pubkey, config.ALICE_COLDKEY_PUBKEY, test_netuid)
    alice_movable_alpha = max(
        0, alice_subnet_alpha() - _alice_locked_alpha(test_netuid, test_hotkey_ss58),
    )
    assert over_movable_amount >= alice_movable_alpha + 2 * UNLOCKED_MARGIN_RAO, (
        f"premise broken: Alice's test-hotkey stake does not exceed movable "
        f"({alice_movable_alpha} RAO) by 2x margin"
    )

    mailbox_alpha_before = env.stake(test_hotkey_pubkey, user_mailbox_coldkey, test_netuid)
    assert mailbox_alpha_before == 0, (
        f"mailbox not virgin before the refused transfer ({mailbox_alpha_before} RAO)"
    )

    print(f"  Attempting to transfer {over_movable_amount} RAO "
          "(Alice's full test-hotkey stake) into the mailbox...")
    with pytest.raises(extrinsics.ExtrinsicError) as refused_transfer:
        extrinsics.transfer_stake(
            user_mailbox_ss58, test_hotkey_ss58, test_netuid, over_movable_amount,
        )
    assert "AccountRejectsLockedAlpha" in str(refused_transfer.value), (
        f"transferStake reverted but not with AccountRejectsLockedAlpha: "
        f"{refused_transfer.value}"
    )
    print("  Chain refused the over-movable transfer (mailbox rejects locked inflow by default)")

    env.assert_vault_reverts_with(
        "ZeroAmount()", 1_500_000, "wrap with no arrived deposit did NOT revert as ZeroAmount",
        "wrap(uint256,bytes32,uint256)", test_netuid, test_hotkey_pubkey, 0,
    )

    # --- Phase 8: the movable portion of the locked wallet wraps normally ----------
    movable_deposit_rao = UNLOCKED_MARGIN_RAO // 2
    receipt = env.deposit_and_wrap(
        test_netuid, test_hotkey_pubkey, test_hotkey_ss58, movable_deposit_rao,
        1_500_000, "wrap of the movable portion failed",
    )
    checks.assert_first_deposit_shares(
        env.vault_shares(test_token_id), env.deposited(receipt, test_netuid, test_hotkey_pubkey),
        "movable-portion wrap",
    )
    locked_alpha_after_movable_wrap = _alice_locked_alpha(test_netuid, test_hotkey_ss58)
    # Touching the lock re-persists its lazily-decayed locked amount (the decay is
    # about one part in a million per block); 99% is a generous floor here.
    assert locked_alpha_after_movable_wrap >= initial_locked_alpha // 100 * 99, (
        "Alice's lock shrank from a free-portion transfer"
    )
    assert initial_locked_alpha >= locked_alpha_after_movable_wrap, (
        "Alice's lock grew during a free-portion wrap (a lock migrated unexpectedly)"
    )

    # --- Phase 9: unwrap pays out to a coldkey that HOLDS an active lock -----------
    half_shares = env.vault_shares(test_token_id) // 2
    _, alice_received_alpha = exits.unwrap(
        env, test_token_id, half_shares, "unwrap to a lock-holding coldkey failed",
        hotkeys=[alice_owner_hotkey_pubkey, *subnet_hotkeys], coldkey=config.ALICE_COLDKEY_PUBKEY,
    )
    locked_alpha_after_unwrap = _alice_locked_alpha(test_netuid, test_hotkey_ss58)
    assert locked_alpha_after_unwrap >= initial_locked_alpha // 100 * 99, (
        "Alice's lock disturbed by receiving unwrapped alpha"
    )
    assert initial_locked_alpha >= locked_alpha_after_unwrap, (
        "Alice's lock grew from receiving unwrapped alpha (a lock arrived with the transfer)"
    )
    print(f"  Locked coldkey received {alice_received_alpha} RAO unlocked alpha; lock intact")

    # --- Phase 10: unwrapForTao works while a large lock exists on the subnet -------
    receipt, sold_alpha = exits.unwrap_for_tao(
        env, test_token_id, env.vault_shares(test_token_id), "unwrapForTao on a subnet with active locks",
        hotkeys=subnet_hotkeys,
    )
    assert env.vault_shares(test_token_id) == 0, "shares left after unwrapForTao"
    exits.assert_drained(env, test_token_id, subnet_hotkeys, receipt, "unwrapForTao on a subnet with active locks")
    print(f"  Remaining shares exited as TAO: sold {sold_alpha} alpha RAO at the chain's quote")

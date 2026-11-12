"""Scenario: convicted (conviction-locked) alpha.

Conviction locks bind a coldkey's subnet-wide alpha, and contract-controlled
coldkeys reject locked inflow (creation verifies the chain's rejection default).
Alice locks all but a movable margin of her subnet stake. A deposit dipping into
locked mass therefore reverts at her own transfer, before the vault is involved,
and the wrap that follows finds nothing to collect. The movable portion wraps
normally, and the vault flows that follow -- an unwrap to Alice's lock-holding
coldkey, a rebalance and an unwrapForTao -- leave her lock where its own decay
takes it.
"""
import pytest

from alpha_e2e import chain, checks, config, exits, extrinsics, substrate
from alpha_e2e.substrate import h160_to_ss58

UNLOCKED_MARGIN_RAO = 30_000_000_000
# The chain's DefaultUnlockRate: locked mass decays by exp(-blocks / 934_866).
UNLOCK_RATE_BLOCKS = 934_866


def _alice_locked_alpha(netuid: int, hotkey_ss58: str) -> int:
    return extrinsics.get_lock(config.ALICE_COLDKEY_SS58, netuid, hotkey_ss58)


@pytest.mark.scenario
def test_locked_alpha_never_enters_the_vault_and_vault_flows_leave_the_lock_alone(env):
    test_netuid = env.netuids[0]
    test_token_id = env.token_ids[0]
    test_hotkey_pubkey = env.subnet_hotkey_pubkeys(0)[0]
    test_hotkey_ss58 = env.subnet_hotkey_ss58s(0)[0]

    subnet_hotkeys = env.subnet_hotkey_pubkeys(0)
    user_mailbox = env.mailbox_address(test_netuid)
    user_mailbox_ss58 = h160_to_ss58(user_mailbox)
    alice_owner_hotkey_pubkey = substrate.read_hotkey_pubkey(
        config.ALICE_WALLET, config.ALICE_HOTKEY_NAME,
    )

    def alice_subnet_alpha() -> int:
        # Locks bind Alice's subnet-wide alpha across all her hotkeys, and the subnet-wide getter
        # returns TAO value, not the alpha the lock is denominated in.
        return env.total_stake_across(
            config.ALICE_COLDKEY_PUBKEY, test_netuid,
            [alice_owner_hotkey_pubkey, *subnet_hotkeys],
        )

    alice_subnet_alpha_before_lock = alice_subnet_alpha()
    assert alice_subnet_alpha_before_lock >= 2 * UNLOCKED_MARGIN_RAO, (
        "Alice's subnet stake too small to lock meaningfully"
    )
    lock_amount_rao = alice_subnet_alpha_before_lock - UNLOCKED_MARGIN_RAO

    print(f"  Alice subnet total: {alice_subnet_alpha_before_lock} RAO; locking "
          f"{lock_amount_rao} RAO to {test_hotkey_ss58[:12]}... (margin {UNLOCKED_MARGIN_RAO})")
    lock_block_floor = chain.cast_block_number()
    extrinsics.lock_stake(test_hotkey_ss58, test_netuid, lock_amount_rao)

    initial_locked_alpha = _alice_locked_alpha(test_netuid, test_hotkey_ss58)
    assert initial_locked_alpha == lock_amount_rao, (
        f"lock not registered exactly (asked {lock_amount_rao}, stored {initial_locked_alpha})"
    )

    def assert_lock_untouched(flow: str) -> None:
        locked = _alice_locked_alpha(test_netuid, test_hotkey_ss58)
        blocks = chain.cast_block_number() - lock_block_floor
        decay_bound = (initial_locked_alpha * blocks + UNLOCK_RATE_BLOCKS - 1) // UNLOCK_RATE_BLOCKS
        assert initial_locked_alpha - decay_bound <= locked <= initial_locked_alpha, (
            f"{flow}: Alice's lock holds {locked} alpha RAO; {blocks} blocks of decay allow "
            f"{initial_locked_alpha - decay_bound} to {initial_locked_alpha}"
        )
    print(f"  Lock live on chain: {initial_locked_alpha} RAO locked "
          f"(movable margin ~ {UNLOCKED_MARGIN_RAO} RAO + emissions)")

    # The refused transfer must exceed the movable amount, which emissions keep raising.
    over_movable_amount = env.stake(test_hotkey_pubkey, config.ALICE_COLDKEY_PUBKEY, test_netuid)
    alice_movable_alpha = max(
        0, alice_subnet_alpha() - _alice_locked_alpha(test_netuid, test_hotkey_ss58),
    )
    assert over_movable_amount >= alice_movable_alpha + 2 * UNLOCKED_MARGIN_RAO, (
        f"premise broken: Alice's test-hotkey stake does not exceed movable "
        f"({alice_movable_alpha} RAO) by 2x margin"
    )

    mailbox_alpha_before = env.mailbox_deposit(test_netuid)
    assert mailbox_alpha_before == 0, (
        f"mailbox not virgin before the refused transfer ({mailbox_alpha_before} RAO)"
    )

    print(f"  Attempting to transfer {over_movable_amount} RAO "
          "(Alice's full test-hotkey stake) into the mailbox...")
    with pytest.raises(extrinsics.ExtrinsicError) as refused_transfer:
        extrinsics.transfer_stake_and_hotkey(
            user_mailbox_ss58, test_hotkey_ss58, user_mailbox_ss58, test_netuid, over_movable_amount,
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

    movable_deposit_rao = UNLOCKED_MARGIN_RAO // 2
    receipt = env.deposit_and_wrap(
        test_netuid, test_hotkey_pubkey, test_hotkey_ss58, movable_deposit_rao,
        1_500_000, "wrap of the movable portion failed",
    )
    checks.assert_first_deposit_shares(
        env.vault_shares(test_token_id), env.deposited(receipt, test_netuid),
        "movable-portion wrap",
    )
    assert_lock_untouched("a free-portion wrap")

    half_shares = env.vault_shares(test_token_id) // 2
    _, alice_received_alpha = exits.unwrap(
        env, test_token_id, half_shares, "unwrap to a lock-holding coldkey failed",
        hotkeys=[alice_owner_hotkey_pubkey, *subnet_hotkeys], coldkey=config.ALICE_COLDKEY_PUBKEY,
    )
    assert_lock_untouched("an unwrap to the lock-holding coldkey")
    print(f"  Locked coldkey received {alice_received_alpha} RAO unlocked alpha; lock intact")

    env.vault_send(
        2_500_000, "rebalance on a subnet with active locks failed", "rebalance(uint256)", test_netuid,
        label="rebalance [active locks]",
    )
    assert_lock_untouched("a rebalance")

    receipt, sold_alpha = exits.unwrap_for_tao(
        env, test_token_id, env.vault_shares(test_token_id), "unwrapForTao on a subnet with active locks",
        hotkeys=subnet_hotkeys,
    )
    assert env.vault_shares(test_token_id) == 0, "shares left after unwrapForTao"
    exits.assert_drained(env, test_token_id, subnet_hotkeys, receipt, "unwrapForTao on a subnet with active locks")
    assert_lock_untouched("an unwrapForTao")
    print(f"  Remaining shares exited as TAO: sold {sold_alpha} alpha RAO at the chain's quote")

"""Vault exits measured against the chain.

Each exit lands in a block with no epoch on its subnet, so the stake read at that block
and the one before differs only by what the exit moved: an alpha exit must deliver
exactly what the clone gave up, and a TAO exit must pay for exactly what the seller's
stake lost. Pass every hotkey either side holds stake under on the subnet.
"""
from typing import List, Optional, Tuple

from . import chain, checks, config
from .environment import Environment, netuid_of


def unwrap(
    env: Environment, token_id: int, shares: int, message: str, *, hotkeys: List[str],
    coldkey: Optional[str] = None, private_key: Optional[str] = None,
    gas_limit: int = 2_500_000, label: Optional[str] = None,
    tolerance: int = config.ROUNDING_DUST_TOTAL_RAO,
) -> Tuple[dict, int]:
    """Alpha exit to `coldkey` (default: the wrapper user's); returns (receipt, alpha RAO
    delivered). `tolerance` covers the chain's per-move rounding; an exit that consolidates
    rotated-out stake makes more moves."""
    netuid = netuid_of(token_id)
    coldkey = coldkey or env.wrapper_substrate_coldkey
    receipt = env.vault_send_between_epochs(
        netuid, gas_limit, message, "unwrap(uint256,uint256,bytes32,uint256)",
        token_id, shares, coldkey, 1, private_key=private_key, label=label,
    )
    block = chain.receipt_block_number(receipt, message)
    delivered = env.stake_change(coldkey, netuid, hotkeys, block)
    released = -env.stake_change(env.clone_coldkey(token_id), netuid, hotkeys, block)
    assert abs(released - delivered) <= tolerance, (
        f"{message}: delivered {delivered} alpha RAO while the clone released {released}"
    )
    return receipt, delivered


def unwrap_for_tao(
    env: Environment, token_id: int, shares: int, message: str, *, hotkeys: List[str],
    min_tao_out: int = 0, excluded_slots: Optional[int] = None,
    holder: str = config.WRAPPER_USER_ADDRESS, private_key: Optional[str] = None,
    gas_limit: int = 2_500_000, label: Optional[str] = None,
) -> Tuple[dict, int]:
    """TAO exit by `holder`; asserts the payout against the chain's quote and the vault's own
    report, and returns (receipt, alpha RAO the clone sold)."""
    netuid = netuid_of(token_id)
    if excluded_slots is None:
        signature, args = "unwrapForTao(uint256,uint256,uint256)", (token_id, shares, min_tao_out)
    else:
        signature = "unwrapForTao(uint256,uint256,uint256,uint256)"
        args = (token_id, shares, min_tao_out, excluded_slots)
    balance_before = chain.cast_balance_wei(holder)
    receipt = env.vault_send_between_epochs(
        netuid, gas_limit, message, signature, *args, private_key=private_key, label=label,
    )
    balance_after = chain.cast_balance_wei(holder)
    alpha_sold = checks.assert_payout_near_quote(
        env, balance_before, balance_after, receipt, netuid, env.clone_coldkey(token_id), hotkeys,
        f"{message}: payout off the chain's quote",
    )
    checks.assert_payout_matches_emitted(
        balance_before, balance_after, receipt, f"{message}: paid other than it reported",
    )
    return receipt, alpha_sold


def reclaim_mailbox_alpha_as_tao(env: Environment, netuid: int, hotkey: str, message: str) -> int:
    """Sell the wrapper user's mailbox stake under `hotkey` for TAO; asserts the payout and
    the emptied mailbox, and returns the alpha RAO sold."""
    mailbox_coldkey = env.mailbox_coldkey(netuid)
    balance_before = env.user_tao_wei()
    receipt = env.vault_send_between_epochs(
        netuid, 1_500_000, message, "reclaimMailboxAlphaAsTao(uint256,bytes32,uint256)", netuid, hotkey, 0,
    )
    balance_after = env.user_tao_wei()
    alpha_sold = checks.assert_payout_near_quote(
        env, balance_before, balance_after, receipt, netuid, mailbox_coldkey, [hotkey],
        f"{message}: payout off the chain's quote",
    )
    checks.assert_payout_matches_emitted(
        balance_before, balance_after, receipt, f"{message}: paid other than it reported",
        checks.MAILBOX_TAO_RECLAIM,
    )
    block = chain.receipt_block_number(receipt, message)
    leftover = env.stake(hotkey, mailbox_coldkey, netuid, block)
    assert leftover <= config.ROUNDING_DUST_SLOT_RAO, f"{message}: the mailbox still holds {leftover} RAO"
    return alpha_sold


def assert_drained(env: Environment, token_id: int, hotkeys: List[str], receipt: dict, message: str) -> None:
    """Assert a full exit left the clone no more than rounding dust across `hotkeys`."""
    block = chain.receipt_block_number(receipt, message)
    leftover = env.total_stake_across(env.clone_coldkey(token_id), netuid_of(token_id), hotkeys, block)
    assert leftover <= config.ROUNDING_DUST_TOTAL_RAO, f"{message}: the clone kept {leftover} RAO"

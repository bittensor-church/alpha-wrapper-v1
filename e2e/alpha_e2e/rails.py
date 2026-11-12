"""Every rail a holder uses, run against a position whose slot resolves away from its attested hotkey.

A deposit chosen under the attested hotkey, a partial alpha exit, a partial TAO exit and a
rebalance each land in a block that stake reads either side of it can measure. Each must keep
the hotkey the vault has to skip at zero, mint and pay at the position's own rate, and agree
with the lens's previews at the block before it.
"""
from dataclasses import dataclass
from typing import List

from . import chain, checks, config, exits
from .environment import Environment


@dataclass(frozen=True)
class RailsRun:
    """The deposit's receipt and the alpha it collected, and the closing rebalance's receipt."""
    wrap_receipt: dict
    deposited: int
    rebalance_receipt: dict


def assert_rails_skip_hotkey(
    env: Environment, subnet_index: int, attested_pubkey: str, funding_ss58: str,
    skipped_pubkey: str, located: List[str], tag: str, context: str,
) -> RailsRun:
    """Run every rail with the deposit chosen under `attested_pubkey` and funded from Alice's stake
    under `funding_ss58`, asserting `skipped_pubkey` holds none of the clone's alpha after each.
    `located` must cover the clone's stake on the subnet; `tag` labels the gas rows."""
    netuid = env.netuids[subnet_index]
    token_id = env.token_ids[subnet_index]
    clone_coldkey = env.clone_coldkey(token_id)

    def assert_skipped(receipt: dict, step: str) -> None:
        block = chain.receipt_block_number(receipt, f"{context}: {step}")
        held = env.stake(skipped_pubkey, clone_coldkey, netuid, block)
        assert held == 0, f"{context}: the {step} left {held} alpha RAO on the hotkey the vault must skip"

    deposit = config.DEPOSIT_RAO // 10
    wrap_receipt = env.deposit_and_wrap(
        netuid, attested_pubkey, funding_ss58, deposit, 1_500_000, f"{context}: the deposit failed",
        label=f"wrap [{tag}]", min_shares_out=env.preview_wrap(token_id, deposit) * 95 // 100,
    )
    assert_skipped(wrap_receipt, "deposit")
    minted = checks.assert_wrap_kept_value_per_share(env, token_id, wrap_receipt, located, f"{context}: deposit")
    deposited = env.deposited(wrap_receipt, netuid)
    wrap_block = chain.receipt_block_number(wrap_receipt, f"{context}: deposit")
    quoted_shares = env.preview_wrap(token_id, deposited, block=wrap_block - 1)
    assert quoted_shares * 99 // 100 <= minted <= quoted_shares, (
        f"{context}: previewWrap quoted {quoted_shares} shares for {deposited} RAO, the wrap minted {minted}"
    )

    shares = env.vault_shares(token_id)
    exit_receipt, delivered = exits.unwrap(
        env, token_id, shares // 2, f"{context}: the partial exit failed", hotkeys=located, label=f"unwrap [{tag}]",
    )
    assert_skipped(exit_receipt, "partial exit")
    exit_block = chain.receipt_block_number(exit_receipt, f"{context}: partial exit")
    quoted_alpha, _ = env.preview_unwrap(token_id, shares // 2, block=exit_block - 1)
    assert abs(quoted_alpha - delivered) <= config.ROUNDING_DUST_TOTAL_RAO, (
        f"{context}: previewUnwrap quoted {quoted_alpha} RAO but the exit paid {delivered}"
    )

    tao_receipt, _ = exits.unwrap_for_tao(
        env, token_id, shares // 4, f"{context}: the TAO exit failed", hotkeys=located, label=f"unwrapForTao [{tag}]",
    )
    assert_skipped(tao_receipt, "TAO exit")

    rebalance_receipt = env.vault_send_between_epochs(
        netuid, 4_000_000, f"{context}: rebalance failed", "rebalance(uint256)", netuid, label=f"rebalance [{tag}]",
    )
    assert_skipped(rebalance_receipt, "rebalance")
    return RailsRun(wrap_receipt, deposited, rebalance_receipt)

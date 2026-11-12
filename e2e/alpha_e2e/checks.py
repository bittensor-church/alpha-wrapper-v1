"""Shared assertion helpers for balance deltas, share accounting, gas budgets, and CSV output.

These encode the suite's cross-cutting measurement rules: what a vault call moved is
read off chain stake at the blocks either side of it, shares are judged by the alpha
behind each one before and after a call, TAO payouts are judged against the chain's own
alpha->TAO quote at the block before the exit, gas budgets separate designed pre-check
reverts from attempted-and-burned precompile dispatches, and the observability scripts'
CSV output is asserted row by row.
"""
import csv
import io
from dataclasses import dataclass
from typing import Dict, List, Optional

from . import chain, config
from .environment import Environment


def find_strays(env: Environment, token_id: int, recover: bool = False) -> List[dict]:
    """The rows `scripts/find_strays.py` reports for the token: hotkey, stake_rao, dry_run.
    With `recover`, the script also sends `recoverStray` for the piles it accepts."""
    report = run_observability_script(
        "find_strays", "--token-id", str(token_id), *(["--recover"] if recover else []),
        address_args=["--vault-address", env.vault_address],
        extra_env={"RECOVER_PRIVATE_KEY": config.WRAPPER_USER_PRIVATE_KEY},
    )
    return csv_rows(report)


def run_observability_script(
    script_name: str, *extra_args: str,
    address_args: List[str],
    block_start: Optional[int] = None, block_end: Optional[int] = None,
    extra_env: Optional[dict] = None,
) -> str:
    """Run scripts/<script_name>.py and return its CSV stdout. Pass the block
    window for the event readers; omit it for the state readers that take none."""
    cmd = ["python3", f"scripts/{script_name}.py", "--rpc-url", config.RPC_URL, *address_args]
    if block_start is not None:
        cmd += ["--block-start", str(block_start), "--block-end", str(block_end)]
    cmd += list(extra_args)
    return chain.run(cmd, extra_env=extra_env).stdout


def min_tao_out_for(quote_rao: int) -> int:
    """Half a pre-call alpha->TAO quote, in wei: a slippage floor that a dividend
    landing before the exit can only lift the payout further above, while a payout
    that halves is still rejected."""
    return quote_rao * config.WEI_PER_RAO // 2


def assert_gas_within(receipt: dict, bound: int, message: str) -> None:
    """Assert the transaction consumed at most `bound` gas. A rejected precompile
    dispatch consumes all forwarded gas, so staying far under the limit separates
    a designed pre-check revert (or a healthy call) from an attempted-and-burned
    dispatch."""
    gas_used = chain.receipt_gas_used(receipt)
    assert gas_used is not None, f"{message}: could not parse gasUsed"
    assert gas_used <= bound, f"{message} (consumed {gas_used} gas, bound {bound})"


def assert_first_deposit_shares(shares: int, deposited_rao: int, message: str) -> None:
    """A deposit into an empty position mints exactly 1e9 shares per alpha RAO."""
    expected = deposited_rao * config.SHARES_PER_RAO_AT_FIRST_DEPOSIT
    assert shares == expected, (
        f"{message}: minted {shares} shares for a first deposit of {deposited_rao} RAO; expected "
        f"1e9 shares per RAO = {expected}"
    )


def assert_pro_rata(amount: int, total: int, part: int, whole: int, slack: int, message: str) -> None:
    """Assert `amount` is the `part / whole` slice of `total`, to `slack` units of `total`."""
    drift = abs(amount * whole - total * part)
    assert drift <= slack * whole, (
        f"{message}: {amount} against {part}/{whole} of {total} (slack {slack})"
    )


def assert_floored_pro_rata(
    amount: int, total: int, part: int, whole: int, quantum: int, message: str, floors: int = 1,
) -> None:
    """Assert `amount` is the `part / whole` slice of `total` rounded down to a multiple of `quantum`,
    after `floors` integer divisions that each lose under one unit of the slice."""
    shortfall = total * part - amount * whole
    assert amount % quantum == 0 and 0 <= shortfall < (quantum + floors - 1) * whole, (
        f"{message}: {amount} against {part}/{whole} of {total}, floored to {quantum} after {floors} division(s)"
    )


def assert_value_per_share_kept(
    backing_before: int, supply_before: int, backing_after: int, supply_after: int, slack: int, message: str,
) -> None:
    """Assert a call left each share worth what it was worth before, to `slack` backing units."""
    assert_pro_rata(
        backing_after, backing_before, supply_after, supply_before, slack,
        f"{message}: {backing_after} left for {supply_after} shares after {backing_before} backed {supply_before}",
    )


def assert_wrap_kept_value_per_share(
    env: Environment, token_id: int, wrap_receipt: dict, hotkeys: List[str], message: str,
) -> int:
    """Assert a deposit into a funded position minted at the position's own rate: the alpha behind
    each share is the same before and after the wrap. Returns the shares minted. `hotkeys` must
    cover the clone's stake on the subnet."""
    netuid = env.netuid_of(token_id)
    block = chain.receipt_block_number(wrap_receipt, message)
    clone_coldkey = env.clone_coldkey(token_id)
    supply_before = env.vault_total_supply(token_id, block=block - 1)
    supply_after = env.vault_total_supply(token_id, block=block)
    backing_before = env.total_stake_across(clone_coldkey, netuid, hotkeys, block - 1)
    backing_after = env.total_stake_across(clone_coldkey, netuid, hotkeys, block)
    assert supply_before != 0 and backing_before != 0, f"{message}: the position was empty before the wrap"
    landed = backing_after - backing_before
    slack = config.SHARE_MATH_ROUNDING_RAO + config.ROUNDING_DUST_SLOT_RAO * (
        1 + (landed + backing_before - 1) // backing_before
    )
    assert_value_per_share_kept(backing_before, supply_before, backing_after, supply_after, slack, message)
    return supply_after - supply_before


def reconstructed_payout(
    balance_before_wei: int, balance_after_wei: int, receipt: dict, message: str,
) -> int:
    """The caller's balance delta plus the gas it paid, at the base fee going
    into its block: dust-scale payouts are smaller than gas, so the raw delta
    alone proves nothing."""
    gas_used = chain.receipt_gas_used(receipt)
    assert gas_used is not None, f"{message}: could not parse gasUsed for payout reconstruction"
    gas_price_wei = chain.cast_base_fee_wei(chain.receipt_block_number(receipt, message) - 1)
    return balance_after_wei - balance_before_wei + gas_used * gas_price_wei


@dataclass(frozen=True)
class TaoSale:
    """Where a call that pays TAO reports the TAO it paid: the event's signature and the
    data-word index of the amount."""
    event: str
    tao_word: int


VAULT_TAO_EXIT = TaoSale("UnwrappedForTao(address,uint256,uint256,uint256,uint256,uint256)", 3)
MAILBOX_TAO_RECLAIM = TaoSale("MailboxAlphaSoldForTao(address,uint256,uint256,uint256)", 1)


@dataclass(frozen=True)
class TaoExitReport:
    """What the vault's `UnwrappedForTao` event says a TAO exit did."""
    shares_burned: int
    shares_refunded: int
    alpha_sold: int
    tao_out_wei: int


def tao_exit_report(receipt: dict, message: str) -> TaoExitReport:
    return TaoExitReport(*(chain.event_word(receipt, VAULT_TAO_EXIT.event, word, message) for word in range(4)))


def assert_payout_matches_emitted(
    balance_before_wei: int, balance_after_wei: int, receipt: dict, message: str,
    sale: TaoSale = VAULT_TAO_EXIT,
) -> None:
    """Assert the caller actually received what the call reported paying, to the RAO. The event
    is the vault's own claim; the balance delta is the chain's, so the two are independent."""
    payout = reconstructed_payout(balance_before_wei, balance_after_wei, receipt, message)
    emitted = chain.event_word(receipt, sale.event, sale.tao_word, message)
    assert 0 <= emitted - payout < config.WEI_PER_RAO, (
        f"{message} (emitted {emitted} wei, received {payout} wei)"
    )


def assert_payout_near_quote(
    env: Environment, balance_before_wei: int, balance_after_wei: int, receipt: dict,
    netuid: int, seller_coldkey: str, seller_hotkeys: List[str], message: str,
) -> int:
    """Assert the call paid within `config.PAYOUT_QUOTE_TOLERANCE_PERCENT` of the chain's quote,
    at the block before it, for the alpha the seller's stake lost in the call's block. Returns
    that alpha (RAO).

    The call must have landed clear of an epoch (Environment.vault_send_between_epochs), so
    the seller's stake changed only by the sale."""
    payout = reconstructed_payout(balance_before_wei, balance_after_wei, receipt, message)
    sale_block = chain.receipt_block_number(receipt, message)
    alpha_sold = -env.stake_change(seller_coldkey, netuid, seller_hotkeys, sale_block)
    quote_wei = env.alpha_to_tao_quote(netuid, alpha_sold, block=sale_block - 1) * config.WEI_PER_RAO
    allowed_wei = quote_wei * config.PAYOUT_QUOTE_TOLERANCE_PERCENT // 100
    assert abs(payout - quote_wei) <= allowed_wei, (
        f"{message} (payout {payout} wei for {alpha_sold} alpha RAO, quoted {quote_wei} wei at block "
        f"{sale_block - 1}: off by {payout - quote_wei} wei, allowed {allowed_wei})"
    )
    return alpha_sold


def csv_rows(csv_text: str) -> List[dict]:
    """The rows of one observability-script invocation's CSV output."""
    return list(csv.DictReader(io.StringIO(csv_text)))


def assert_csv_rows(csv_text: str, expected: List[Dict[str, object]], message: str) -> List[dict]:
    """Assert the CSV (one observability-script invocation) holds exactly the `expected` rows, in
    any order, on the columns they name; values compare as text, case-insensitively, so hex
    and checksummed addresses match. Returns the parsed rows."""
    parsed = csv_rows(csv_text)
    columns = sorted({column for row in expected for column in row})

    def comparable(row: Dict[str, object]) -> tuple:
        return tuple(str(row[column]).lower() for column in columns)

    assert sorted(map(comparable, parsed)) == sorted(map(comparable, expected)), (
        f"{message}: expected rows {expected}, got {parsed}"
    )
    return parsed


def volume_row(token_id: int, user: str, **counts: object) -> dict:
    """A `get_volumes` row with every column zero except the ones given."""
    row = {
        "token_id": token_id, "user": user,
        "deposit_count": 0, "alpha_deposited_rao": 0, "shares_minted": 0,
        "alpha_unwrap_count": 0, "alpha_unwrap_shares_burned": 0, "alpha_unwrapped_rao": 0,
        "tao_unwrap_count": 0, "tao_unwrap_shares_burned": 0, "tao_unwrap_shares_refunded": 0,
        "alpha_sold_for_tao_rao": 0, "tao_from_alpha_sales_wei": 0,
        "dissolved_unwrap_count": 0, "dissolved_unwrap_shares_burned": 0, "tao_from_dissolutions_wei": 0,
        "unwrap_count": 0, "shares_burned": 0, "tao_received_wei": 0,
    }
    row.update(counts)
    return row

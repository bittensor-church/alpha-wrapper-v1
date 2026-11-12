"""Scenario: the vault stays live through every dust state.

Two churn cycles exercise withdrawal remainders, skipped rebalances, sale
leftovers, and balances on rotated-out validators. Each eligible call must
succeed within its gas budget and deliver or sell exactly what the clone gave
up. The closing ledger must balance both ways: what was deposited and what the
epochs between calls emitted onto the clone, against what was delivered, sold
and left behind, up to the chain's per-move rounding.
"""
import pytest

from alpha_e2e import chain, config, exits
from alpha_e2e.checks import assert_gas_within, min_tao_out_for


class ChurnLedger:
    """Deposits, withdrawals, and rotations on one subnet, tracking the closing-ledger
    totals (alpha RAO) and every hotkey a delivery can land under. Every call lands clear
    of an epoch, so the clone's stake grows between two calls only by emission."""

    def __init__(self, env, netuid, token_id, floor, hotkey_pubkeys):
        self.env = env
        self.netuid = netuid
        self.token_id = token_id
        self.floor = floor
        self.hotkey_pubkeys = list(hotkey_pubkeys)
        self.clone_coldkey = env.clone_coldkey(token_id)
        self.deposited_alpha_total = 0
        self.delivered_alpha_total = 0
        self.sold_alpha_total = 0
        self.emitted_alpha_total = 0
        self.rounding_allowance = 0
        self.last_call_block = chain.cast_block_number()
        assert self.backing(self.last_call_block) == 0, "the ledger must open on an empty clone"

    def backing(self, block=None) -> int:
        return self.env.total_stake_across(self.clone_coldkey, self.netuid, self.hotkey_pubkeys, block)

    def _record_call(self, receipt: dict, label: str) -> None:
        """Book the emission the clone earned since the previous call, up to the block before this one."""
        block = chain.receipt_block_number(receipt, label)
        self.emitted_alpha_total += self.backing(block - 1) - self.backing(self.last_call_block)
        self.last_call_block = block

    def boundary_alpha(self) -> int:
        _, boundary = self.env.floor_boundary(self.netuid, self.floor)
        return boundary

    def deposit_step(self, label: str, hotkey_pubkey: str, hotkey_ss58: str,
                     amount_rao: int) -> None:
        receipt = self.env.deposit_and_wrap(
            self.netuid, hotkey_pubkey, hotkey_ss58, amount_rao,
            1_500_000, f"{label}: wrap failed",
        )
        assert_gas_within(receipt, config.WRAP_GAS_BOUND, f"{label}: wrap")
        self._record_call(receipt, f"{label}: wrap")
        self.deposited_alpha_total += self.env.deposited(receipt, self.netuid)
        self.rounding_allowance += config.CONSOLIDATION_ROUNDING_TOLERANCE_RAO
        print(f"  {label}: wrapped {amount_rao} alpha RAO")

    def unwrap_for_alpha_step(self, label: str, percent: int, tolerance: int = config.ROUNDING_DUST_TOTAL_RAO) -> None:
        burn = self.env.vault_shares(self.token_id) * percent // 100
        receipt, delivered = exits.unwrap(
            self.env, self.token_id, burn, f"{label}: unwrap failed", hotkeys=self.hotkey_pubkeys,
            tolerance=tolerance,
        )
        assert_gas_within(receipt, config.UNWRAP_GAS_BOUND, f"{label}: unwrap")
        self._record_call(receipt, f"{label}: unwrap")
        self.delivered_alpha_total += delivered
        self.rounding_allowance += tolerance
        print(f"  {label}: unwrapped {percent}% of shares, delivered {delivered} alpha RAO")

    def unwrap_for_tao_step(self, label: str, percent: int) -> None:
        burn = self.env.vault_shares(self.token_id) * percent // 100
        min_tao_out = min_tao_out_for(self.env.alpha_to_tao_quote(self.netuid, self.backing() * percent // 100))
        receipt, alpha_sold = exits.unwrap_for_tao(
            self.env, self.token_id, burn, f"{label}: TAO exit", hotkeys=self.hotkey_pubkeys,
            min_tao_out=min_tao_out,
        )
        assert_gas_within(receipt, config.UNWRAP_GAS_BOUND, f"{label}: TAO exit")
        self._record_call(receipt, f"{label}: TAO exit")
        self.sold_alpha_total += alpha_sold
        self.rounding_allowance += config.ROUNDING_DUST_TOTAL_RAO
        print(f"  {label}: sold {percent}% of shares for TAO")

    def churn_cycle(
        self, round_number: int,
        primary_pubkey: str, primary_ss58: str,
        secondary_pubkey: str, secondary_ss58: str,
    ) -> None:
        label = f"Cycle {round_number}"
        print(f"\n=== Churn cycle {round_number} ===")

        boundary = self.boundary_alpha()
        self.deposit_step(label, primary_pubkey, primary_ss58, boundary * 9 // 2)
        self.unwrap_for_alpha_step(label, 80)
        self.deposit_step(label, primary_pubkey, primary_ss58, boundary * 5 // 2)

        self.env.set_validator(self.netuid, secondary_pubkey)
        print(f"  {label}: rotated {primary_pubkey[:18]}... out for {secondary_pubkey[:18]}...")

        self.unwrap_for_alpha_step(
            f"{label} (over the rotated-out balances)", 50, tolerance=config.CONSOLIDATION_ROUNDING_TOLERANCE_RAO,
        )
        rotated_out_leftover = self.env.stake(primary_pubkey, self.clone_coldkey, self.netuid)
        assert rotated_out_leftover <= config.ROUNDING_DUST_SLOT_RAO, (
            f"{label}: rotated-out validator still holds stake ({rotated_out_leftover} RAO)"
        )
        assert not self.env.hotkey_in_last_seen(self.token_id, primary_pubkey), (
            f"{label}: rotated-out validator still present in lastSeenHotkeys"
        )
        print(f"  {label}: withdrawal consolidated the rotated-out balances")

        self.deposit_step(label, secondary_pubkey, secondary_ss58, self.boundary_alpha() * 3)
        self.unwrap_for_tao_step(label, 40)


@pytest.mark.scenario
def test_holders_can_exit_after_two_cycles_of_dust_and_validator_rotation(env):
    floor = env.chain_min_stake_tao()
    print(f"  vault floor = {floor} RAO")

    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    hotkey_a_pubkey, hotkey_b_pubkey, hotkey_c_pubkey = env.subnet_hotkey_pubkeys(0)
    hotkey_a_ss58, hotkey_b_ss58, hotkey_c_ss58 = env.subnet_hotkey_ss58s(0)

    ledger = ChurnLedger(
        env, netuid, token_id, floor,
        [hotkey_a_pubkey, hotkey_b_pubkey, hotkey_c_pubkey],
    )

    ledger.deposit_step(
        "Bootstrap deposit", hotkey_a_pubkey, hotkey_a_ss58,
        ledger.boundary_alpha() * 3 // 2,
    )

    ledger.churn_cycle(
        1, hotkey_a_pubkey, hotkey_a_ss58, hotkey_b_pubkey, hotkey_b_ss58,
    )
    ledger.churn_cycle(
        2, hotkey_b_pubkey, hotkey_b_ss58, hotkey_c_pubkey, hotkey_c_ss58,
    )

    ledger.unwrap_for_tao_step("Closing", 100)
    assert env.vault_shares(token_id) == 0, "Closing: shares not fully burned"
    leftover_stake = ledger.backing(ledger.last_call_block)
    assert leftover_stake <= config.ROUNDING_DUST_TOTAL_RAO, (
        f"Closing: stake left behind after the full exit ({leftover_stake} RAO)"
    )

    taken_in = ledger.deposited_alpha_total + ledger.emitted_alpha_total
    paid_out = ledger.delivered_alpha_total + ledger.sold_alpha_total + leftover_stake
    assert abs(taken_in - paid_out) <= ledger.rounding_allowance, (
        f"Closing: deposited {ledger.deposited_alpha_total} + emitted {ledger.emitted_alpha_total} against "
        f"delivered {ledger.delivered_alpha_total} + sold {ledger.sold_alpha_total} + left {leftover_stake}, "
        f"off by {taken_in - paid_out} (rounding allowance {ledger.rounding_allowance})"
    )
    print(f"  Ledger closed: deposited {ledger.deposited_alpha_total}, emitted {ledger.emitted_alpha_total}, "
          f"delivered {ledger.delivered_alpha_total}, sold {ledger.sold_alpha_total} alpha RAO")

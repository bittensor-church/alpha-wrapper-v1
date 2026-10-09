"""Scenario: the vault stays live through every dust state.

Two churn cycles exercise withdrawal remainders, skipped rebalances, sale
leftovers, and balances on rotated-out validators. Each eligible call must
succeed within its gas budget, deliver or sell exactly what the clone gave up,
and the closing ledger must account for every deposited RAO up to the chain's
per-move rounding.
"""
import pytest

from alpha_e2e import chain, config, exits
from alpha_e2e.checks import assert_gas_within, assert_value_per_share_kept, min_tao_out_for


class ChurnLedger:
    """Deposits, withdrawals, and rotations on one subnet, tracking the closing-ledger
    totals (alpha RAO) and every hotkey a delivery can land under."""

    def __init__(self, env, netuid, token_id, chain_min_stake, hotkey_pubkeys):
        self.env = env
        self.netuid = netuid
        self.token_id = token_id
        self.chain_min_stake = chain_min_stake
        self.hotkey_pubkeys = list(hotkey_pubkeys)
        self.deposited_alpha_total = 0
        self.delivered_alpha_total = 0
        self.sold_alpha_total = 0
        # The chain may round away up to this much across the calls made so far.
        self.rounding_allowance = 0
        self._clone_coldkey = None

    @property
    def clone_coldkey(self) -> str:
        # The clone only exists after the first wrap, so resolve it lazily.
        if self._clone_coldkey is None:
            self._clone_coldkey = self.env.clone_coldkey(self.token_id)
        return self._clone_coldkey

    def backing(self, block=None) -> int:
        return self.env.total_stake_across(self.clone_coldkey, self.netuid, self.hotkey_pubkeys, block)

    def floor_boundary_alpha(self) -> int:
        _, boundary = self.env.floor_boundary(self.netuid, self.chain_min_stake)
        return boundary

    def deposit_step(self, label: str, hotkey_pubkey: str, hotkey_ss58: str,
                     amount_rao: int) -> None:
        receipt = self.env.deposit_and_wrap(
            self.netuid, hotkey_pubkey, hotkey_ss58, amount_rao,
            1_500_000, f"{label}: wrap failed",
        )
        assert_gas_within(receipt, config.WRAP_GAS_BOUND, f"{label}: wrap")
        self.deposited_alpha_total += self.env.deposited(receipt, self.netuid, hotkey_pubkey)
        self.rounding_allowance += config.CONSOLIDATION_ROUNDING_TOLERANCE_RAO
        print(f"  {label}: wrapped {amount_rao} alpha RAO")

    def unwrap_for_alpha_step(self, label: str, percent: int, tolerance: int = config.ROUNDING_DUST_TOTAL_RAO) -> None:
        burn = self.env.vault_shares(self.token_id) * percent // 100
        receipt, delivered = exits.unwrap(
            self.env, self.token_id, burn, f"{label}: unwrap failed", hotkeys=self.hotkey_pubkeys,
            tolerance=tolerance,
        )
        assert_gas_within(receipt, config.UNWRAP_GAS_BOUND, f"{label}: unwrap")
        self.delivered_alpha_total += delivered
        self.rounding_allowance += tolerance
        print(f"  {label}: unwrapped {percent}% of shares, delivered {delivered} alpha RAO")

    def unwrap_for_tao_step(self, label: str, percent: int) -> None:
        supply_before = self.env.vault_total_supply(self.token_id)
        shares_before = self.env.vault_shares(self.token_id)
        burn = shares_before * percent // 100
        min_tao_out = min_tao_out_for(self.env.alpha_to_tao_quote(self.netuid, self.backing() * percent // 100))
        receipt, alpha_sold = exits.unwrap_for_tao(
            self.env, self.token_id, burn, f"{label}: TAO exit", hotkeys=self.hotkey_pubkeys,
            min_tao_out=min_tao_out,
        )
        assert_gas_within(receipt, config.UNWRAP_GAS_BOUND, f"{label}: TAO exit")
        # The refund rounds to whole shares, worth up to one share of alpha.
        exit_block = chain.receipt_block_number(receipt, label)
        backing = self.backing(exit_block - 1)
        slack = config.ROUNDING_DUST_TOTAL_RAO + (backing + supply_before - 1) // supply_before
        assert_value_per_share_kept(
            backing, supply_before, self.backing(exit_block),
            self.env.vault_total_supply(self.token_id, block=exit_block), slack,
            f"{label}: the TAO exit changed the remaining shares' value",
        )
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

        boundary = self.floor_boundary_alpha()
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

        self.deposit_step(label, secondary_pubkey, secondary_ss58, boundary * 3)
        self.unwrap_for_tao_step(label, 40)


@pytest.mark.scenario
def test_holders_can_exit_after_two_cycles_of_dust_and_validator_rotation(env):
    chain_min_stake = env.chain_min_stake_tao()
    print(f"  chain minimum stake = {chain_min_stake} RAO")

    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    hotkey_a_pubkey, hotkey_b_pubkey, hotkey_c_pubkey = env.subnet_hotkey_pubkeys(0)
    hotkey_a_ss58, hotkey_b_ss58, hotkey_c_ss58 = env.hotkey_ss58s[:config.VALIDATORS_PER_SUBNET]

    ledger = ChurnLedger(
        env, netuid, token_id, chain_min_stake,
        [hotkey_a_pubkey, hotkey_b_pubkey, hotkey_c_pubkey],
    )

    # --- Fixture position ---------------------------------------------------------
    ledger.deposit_step(
        "Bootstrap deposit", hotkey_a_pubkey, hotkey_a_ss58,
        ledger.floor_boundary_alpha() * 3 // 2,
    )

    ledger.churn_cycle(
        1, hotkey_a_pubkey, hotkey_a_ss58, hotkey_b_pubkey, hotkey_b_ss58,
    )
    ledger.churn_cycle(
        2, hotkey_b_pubkey, hotkey_b_ss58, hotkey_c_pubkey, hotkey_c_ss58,
    )

    # --- Full exit and closing ledger ------------------------------------------------
    ledger.unwrap_for_tao_step("Closing", 100)
    assert env.vault_shares(token_id) == 0, "Closing: shares not fully burned"
    leftover_stake = ledger.backing()
    assert leftover_stake <= config.ROUNDING_DUST_TOTAL_RAO, (
        f"Closing: stake left behind after the full exit ({leftover_stake} RAO)"
    )

    # Emissions only add to the clone, so everything deposited came back out, delivered or
    # sold, less the dust left behind and what the chain rounded away.
    paid_out = ledger.delivered_alpha_total + ledger.sold_alpha_total
    assert paid_out >= ledger.deposited_alpha_total - leftover_stake - ledger.rounding_allowance, (
        f"Closing: ledger shortfall (delivered {ledger.delivered_alpha_total} + sold "
        f"{ledger.sold_alpha_total} < deposited {ledger.deposited_alpha_total} - leftover "
        f"{leftover_stake} - rounding {ledger.rounding_allowance})"
    )
    print(f"  Ledger closed: deposited {ledger.deposited_alpha_total}, delivered "
          f"{ledger.delivered_alpha_total}, sold {ledger.sold_alpha_total} alpha RAO")

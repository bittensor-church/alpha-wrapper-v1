# Observability scripts

Python tools for vault events and state. They load ABIs from `out/`; build the
contracts before using them. Only `find_strays.py --recover` sends transactions.

| Script | Output |
| --- | --- |
| `get_deposits.py` | Deposits |
| `get_unwraps.py` | Live alpha exits, including actual alpha payout |
| `get_rebalances.py` | Weight-alignment moves |
| `get_subnet_proxies.py` | Clone creation |
| `get_validator_updates.py` | Registry updates |
| `get_volumes.py` | Alpha/TAO exit metrics, optionally filtered by user |
| `get_vault_state.py` | Token state and lens quotes |
| `plan_tao_exit.py` | Pre-flight for a TAO exit: per-slot quotes, the exclusion mask, a dry run |
| `find_strays.py` | CSV of vault alpha under hotkeys the record does not name, with a `recoverStray` dry run per pile; `--recover` sends the calls, largest pile first |

`get_vault_state.py` and `plan_tao_exit.py` require `--lens-address` and
`--vault-address`. Use a trusted lens: checking its `vault()` catches a mismatch,
not fabricated quotes. `find_strays.py` reads the vault and the chain's staking and
address-mapping precompiles; `--recover` signs with `RECOVER_PRIVATE_KEY` from the
environment.

`get_validator_updates.py` decodes `PlaceholderValidatorRegistry.ValidatorUpdated` events,
with `count` equal to one. `get_vault_state.py` reads optional validator columns
through the generic `IValidatorRegistry` ABI.

Units: `_rao` columns are alpha at 9 decimals; `_wei` columns are native TAO at
18 decimals. Shares are raw ERC-1155 units. Alpha payouts, alpha requested for sale
and actual TAO proceeds are separate metrics, never summed across units. Burn columns
are gross; the shares a TAO exit mints back for alpha it left unsold are reported
separately as `tao_unwrap_shares_refunded` and stay out of `shares_minted`.

`common.py` supplies shared web3, ABI and CSV helpers to these tools and the
[e2e harness](../e2e/README.md). Recovery monitoring requirements are in the
[watcher runbook](../docs/hotkey-swaps.md).

# End-to-end tests

Pytest scenarios drive a real Subtensor localnet through Foundry, btcli and
Substrate extrinsics.

## Requirements

- Localnet at `ws://127.0.0.1:9944` / `http://127.0.0.1:9944`. CI runs
  `ghcr.io/raofoundation/subtensor-localnet:v481`, pinned by digest in
  `.github/workflows/e2e.yml`; use the same image locally.
- Dev Alice funded, as the localnet genesis does. Bootstrap funds every other
  account it uses from Alice.
- `cast` and `forge` on PATH.
- Python dependencies from `e2e/install-deps.sh`, including btcli.
- Keys: the suite keeps its own wallets under `e2e/.wallets`, so btcli wallets
  you already have stay untouched; `ALPHA_E2E_WALLET_PATH` moves that root.
  Bootstrap generates the dev Alice wallet there when it is absent, and stops if
  a different coldkey already holds that name.

## Run

From the repository root:

```bash
cd e2e
python3 -m pytest tests/test_full_flow.py -v -m scenario
```

Use one scenario module per fresh chain. Modules share subnet and contract state
through the session-scoped `env` fixture; running several against one long-lived
chain is unsupported. CI gives each scenario its own container.

`chain_ops.py` is the manual CLI for the same chain operations; run it from `e2e/`
(`cd e2e && python3 chain_ops.py --help`) so it can import `alpha_e2e`.

## Layout and coverage

`alpha_e2e/` holds the harness:

- `config.py`: localnet constants, dev keys, amounts and rounding allowances.
- `substrate.py`: address derivation and wallet-file readers.
- `chain.py`: cast/forge/btcli wrappers and block waits.
- `extrinsics.py`: Substrate extrinsics and storage reads.
- `validators.py`: Basic registry updates.
- `environment.py`: the deployed-localnet handle with getters and vault actions.
- `checks.py`: shared assertions (payouts, gas, CSV output).
- `exits.py`: exits measured against the chain: what a holder receives must match
  what the clone gave up in the same block.
- `incidents.py`: staged hotkey incidents for the recovery scenarios.
- `bootstrap.py`: one-time localnet setup.
- `fixtures.py`: the `env` and `recovery_window` fixtures; a scenario overrides
  `recovery_window` to deploy with a different window.

`conftest.py` switches to the repository root and registers the fixtures;
`pytest.ini` configures imports and the `scenario` marker.

Scenario files in `tests/` cover:

- `test_full_flow.py`: deposits, alpha and TAO exits (including a planned exit from
  `scripts/plan_tao_exit.py`), both mailbox reclaims, emissions, rotation and observability.
- `test_transfers_off.py`, `test_convicted_alpha.py`: disabled transfers and locks.
- `test_locked_deposit.py`: poisoned candidates are rejected before deployment
  and a fresh UID creates protected mailboxes and subnet clones, each an owned
  hotkey (a mailbox its own, a subnet clone its owner contract's), so coldkey swaps and
  locked-alpha transfers into them are refused on the real chain; an honest
  deposit still wraps and exits.
- `test_reject_hotkey_growth.py`: a candidate that already stakes is rejected, a
  stranger cannot add a hotkey (hotkey 0x0 included) to a mailbox's or clone's
  staking list after creation, a crumb sent under a listed validator keeps its
  entry after a rotation, and deposits land before and after a full exit.
- `test_empty_token_write_off.py`: a crumb keeps the attested validator listed after the
  last exit, so a gift to the emptied token lands, is swept and written off; the token
  stays open and the next deposit wraps without a registry update.
- `test_retained_entries_recovery.py`: with such a crumb retained, a stranger cuts
  the trail behind a validator's rename; the watcher parks the position, an owner
  update releases, and deposits and exits continue.
- `test_subnet_dissolved.py`: refunds and mailbox recovery.
- `test_min_stake_floor.py`, `test_dust_dos.py`, `test_min_stake_liveness.py`:
  minimums, top-ups, dust and repeated position changes.
- `test_claimable_tao.py`: forced-sale proceeds become claimable, and the swept
  position's loss is written off once a short recovery window expires.
- `test_parked_stake.py`: a rename that leaves the stake and the owner record behind,
  where exits keep paying from the old name and follow the successor once the owner
  names it; and a rename that carries the stake, which exits follow before the registry
  changes.
- `test_parked_recovery.py`: a stranger cuts the trail behind a rename; the watcher
  parks the position, exits pay from the parking hotkey, an owner update releases.
- `test_parking_isolation.py`: two subnets park on the one parking hotkey; each keeps
  its own balance, the other keeps trading, and each releases on its own owner update.
- `test_subnet_generation.py`: a rewritten registration block leaves the token and its
  exits untouched; dissolving and re-registering the netuid yields a new token, and the
  old one redeems its dissolution refund.
- `test_validator_coldkey_swap.py`: a validator swaps its coldkey; wraps, rebalances and
  exits continue without a new attestation.
- `test_staking_list_cap.py`: a clone's staking list walked to its last admitted
  entry, where a rebalance and a deposit onto a fresh validator are refused;
  `replaceClone` moves the position, the deposit lands, `unstuckStake` brings a gift
  sent to the retired clone into the backing and the token exits. Gas rows: deposit and
  `previewUnwrap` on the fresh clone; deposit, partial exit and `previewUnwrap` on the
  full list; the replacement; deposit, `previewUnwrap`, `unstuckStake` and full exit on
  the successor.
Each module's docstring describes its sequence. These scenarios exercise specific
recovery conditions, not an unconditional exit guarantee; see the
[design](../docs/hotkey-swaps.md).

Bootstrap creates three subnets, nine validators, the contracts and funded test
accounts once per scenario process.

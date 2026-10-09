# End-to-end tests

Pytest scenarios drive a real Subtensor localnet through Foundry, btcli and
Substrate extrinsics.

## Requirements

- Localnet at `ws://127.0.0.1:9944` / `http://127.0.0.1:9944`. CI runs
  `ghcr.io/raofoundation/subtensor-localnet:main`, pinned by digest in
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
  and a fresh UID creates protected mailboxes and subnet clones that own their
  own hotkeys, so coldkey swaps and locked-alpha transfers into them are refused
  on the real chain; an honest deposit still wraps and exits.
- `test_subnet_dissolved.py`: refunds and mailbox recovery.
- `test_min_stake_floor.py`, `test_dust_dos.py`, `test_min_stake_liveness.py`:
  minimums, top-ups, dust and repeated position changes.
- `test_claimable_tao.py`: forced-sale proceeds become claimable, and the swept
  position's loss is written off once a short recovery window expires.
- `test_parked_stake.py`: a funded hotkey left without an owner, where partial exits
  wait for the owner to replace the name and the vault then claims the key; and a
  rename that carries the stake, which exits follow before the registry changes.
- `test_parked_recovery.py`: a stranger cuts the trail behind a rename; the watcher
  parks the position, exits pay from the parking hotkey, an owner update releases.
- `test_parking_isolation.py`: two subnets park on the one parking hotkey; each keeps
  its own balance, the other keeps trading, and each releases on its own owner update.
- `test_subnet_generation.py`: a rewritten registration block leaves the token and its
  exits untouched; dissolving and re-registering the netuid yields a new token, and the
  old one redeems its dissolution refund.
Each module's docstring describes its sequence. These scenarios exercise specific
recovery conditions, not an unconditional exit guarantee; see the
[design](../docs/hotkey-swaps.md).

Bootstrap creates three subnets, nine validators, the contracts and funded test
accounts once per scenario process.

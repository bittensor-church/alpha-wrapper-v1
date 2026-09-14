# alpha-wrapper

ERC-1155 shares of Bittensor staked alpha, with alpha and native-TAO exits.

## Documentation

- [Overview](docs/overview.md): contracts, shares and allocation.
- [User guide](docs/user-guide.md): deposits, exits and mailbox recovery.
- [Hotkey swaps](docs/hotkey-swaps.md): the empty-slot issue, automatic handling
  and watcher-assisted recovery.
- [Edge cases](docs/edge-cases.md): dissolution, minimums, disabled transfers and dust.
- [Security model](docs/security-model.md): authority, liveness dependencies and loss policy.
- [Deployment](docs/deployment.md): deploying the registry and vault set, and runtime compatibility.

## Layout

- `src/`: vault, read-only lens, clones, registry, shared stake operations, math
  and precompile interfaces.
- `test/`: Foundry tests and chain mocks.
- `script/DeployAlpha.s.sol`: deployment; configure the registry separately first
  and pass `PARKING_HOTKEY`, an unused 32-byte account id the vault claims for
  its own coldkey at deployment.
- [scripts/](scripts/README.md): read-only chain observability.
- [e2e/](e2e/README.md): localnet scenarios and their Python harness.

## Custom validator registry

`BasicValidatorRegistry` is an example validator registry provided as a stub
for building a custom implementation. Use it as a starting point and adapt it
to your validator selection and management requirements.

## Build and test

Dependencies are git submodules:

```bash
git submodule update --init --recursive
forge build
forge test
```

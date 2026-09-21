# alpha-wrapper

`alpha-wrapper` is an open-source suite of EVM smart contracts from Church of Rao
for projects building with Bittensor-native subnet alpha tokens. It wraps staked
alpha in transferable ERC-1155 shares, so an application can offer its users
exposure to staked alpha without giving up a clear route back to either staked
alpha or native TAO.

We believe the Bittensor EVM ecosystem deserves a robust, reusable alpha wrapper
rather than each project rebuilding this critical infrastructure. Church of Rao is
releasing the code under the MIT license for the community to inspect, use, adapt
and improve.

This repository is a source release. No contracts from this repository are
currently deployed on a public network, and Church of Rao does not plan to deploy
or operate them. Integrators can deploy their own instance or use an existing
deployment whose validator registry and staking policy suit their needs.

## Security review

The contracts have undergone internal review, including AI-assisted analysis with
Anthropic's Claude Fable 5.1, OpenAI's GPT-5.6 Sol, and Moonshot AI's Kimi K3
at max reasoning effort. Community review is underway, and an independent
commercial security audit is forthcoming.

No independent audit has yet been completed; users and integrators should conduct
their own review before relying on these contracts.

## What it does

- Mints ERC-1155 shares backed by alpha staked on a Bittensor subnet.
- Separates validator-selection and staking policy from the vault, letting
  integrators choose their own governance and security controls.
- Lets holders redeem shares for staked alpha, or sell their backing for native
  TAO through an opt-in market-sale exit.
- Isolates each subnet registration in its own vault-controlled account, so a
  recycled netuid does not mix a new position with an old dissolved one.
- Accounts separately for native TAO that reaches a position, including
  dissolution refunds and claimable TAO.
- Handles Bittensor-specific operational hazards including hotkey swaps,
  deregistration and dissolution, stake minimums, rounding and dust, disabled
  alpha transfers, conviction-locked alpha, and missing-backing recovery.

`AlphaVault` itself has no admin and no upgrade path. Its validator registry,
recovery window and parking hotkey are also immutable once deployed. The registry has
its own governance model, chosen by each integrator and described below.

## Validator registry

The vault uses the small `IValidatorRegistry` interface, which lets projects
implement their own validator-selection strategy and security controls without
modifying the wrapper.
For example, a registry can use a multisig, timelock, attestations, an automated
selection policy, or another governance model appropriate for its users.

Reallocating stake can have material economic consequences for holders and may
create legal, regulatory and liability considerations for the people or entities
that control it, depending on the service and jurisdiction. Each integrator must
consciously choose its validator strategy, governance and controls, and obtain
its own legal advice.

This repository includes `BasicValidatorRegistry` as a minimal reference
implementation. It maintains one validator hotkey at 100% weight per subnet. Its
owner can replace that hotkey to rotate the vault's stake. Ownership uses
OpenZeppelin `Ownable2Step`: a nominated successor must explicitly accept before
control transfers, and ownership renunciation is disabled.

`BasicValidatorRegistry` is usable, but its owner key is a critical security
boundary. Operators must protect it with appropriate key management and have a
recovery plan. A lost owner key can permanently prevent registry updates; a
compromised owner can select poor or malicious validator destinations. Integrators
who need a different risk model should implement their own registry.

## Documentation

- [Overview](docs/overview.md): contracts, shares and allocation.
- [User guide](docs/user-guide.md): deposits, exits and mailbox recovery.
- [Source flow guide](docs/source-flow-guide.md): position lifecycle and control flow.
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

## Build and test

Dependencies are git submodules:

```bash
git submodule update --init --recursive
forge build
forge test
```

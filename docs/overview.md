# How it works

The wrapper keeps Bittensor alpha staked and issues transferable ERC-1155 shares.
A live position can normally redeem for staked alpha or sell it for native TAO.
Recovery, chain minimums and subnet state can temporarily prevent exits.
Emissions raise the backing behind each share.

## Contracts

- `AlphaVault`: deposits, shares, exits and permissionless maintenance.
- `AlphaVaultLens`: read-only backing and payout quotes.
- `SubnetClone`: one vault-controlled coldkey per subnet registration, isolating
  that position's stake and TAO from other positions, replaced by a fresh one
  once its staking list is full.
- `CloneOwner`: a throwaway contract that owns one subnet clone's account as a
  hotkey, so the staking-list entry that ownership adds lands on its list
  instead of the vault's.
- `DepositMailbox`: one accepted address per user and netuid. The vault only
  credits the caller's own mailbox.
- `CloneFactory`: a vault-owned deployer that checks each candidate account
  before deployment.
- `BasicValidatorRegistry`: one target hotkey per subnet at 100% weight; see
  the [README](../README.md#validator-registry).

A token id is `(registrations << 16) | netuid`, where `registrations` is the
chain's registration counter for that netuid, so a recycled netuid is a
different token with its own clone.

Read the [source flow guide](source-flow-guide.md) for the position lifecycle
and transaction ordering, the [user guide](user-guide.md) for transactions,
[Hotkey swaps and recovery](hotkey-swaps.md) for swaps and the watcher, and the
[security model](security-model.md) for trust and loss assumptions.

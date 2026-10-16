# Deployment

Church of Rao does not plan to deploy or operate these contracts. Each integrator
must choose its validator-selection strategy, registry governance and operational
controls before deploying a vault.

1. Choose or implement an `IValidatorRegistry`. The included
   `BasicValidatorRegistry` is the simplest example.
2. Deploy and configure the registry for every subnet in scope.
3. Deploy the vault set with `script/DeployAlpha.s.sol`, pointed at that registry.
4. Run the verification checks below, then record the addresses and code hashes.

## Registry

`BasicValidatorRegistry(initialOwner)` assigns each subnet one validator at 100%
weight. Updates take effect immediately. Ownership transfers use OpenZeppelin
`Ownable2Step`; renunciation is disabled.

```sh
forge create src/BasicValidatorRegistry.sol:BasicValidatorRegistry \
  --rpc-url <url> --private-key <key> --broadcast \
  --constructor-args <initialOwner>

cast send <registry> 'setValidator(uint256,bytes32)' <netuid> <hotkey> \
  --rpc-url <url> --private-key <owner-key>
```

The hotkey must have an owner record. Downstream `IValidatorRegistry`
implementations must reject duplicate hotkeys before publishing a set; the
vault does not check them.

## Vault set

The deployment script reads four environment variables:

| Variable | Meaning | Default |
| --- | --- | --- |
| `VALIDATOR_REGISTRY` | Address of the deployed registry. | required |
| `VAULT_URI` | ERC-1155 metadata URI, with `{id}` substitution. | `https://example.com/metadata/{id}.json` |
| `RECOVERY_WINDOW` | Length of the recovery window, in seconds. | 21600 (6 hours) |
| `PARKING_HOTKEY` | An unused 32-byte account id the vault claims for its own coldkey. | required |

Choose a fresh random `PARKING_HOTKEY`. The constructor claims it with
`tryAssociateHotkey` and confirms the result; deployment reverts
`ParkingHotkeyUnavailable` when another coldkey already owns that account.

```sh
forge script script/DeployAlpha.s.sol --rpc-url <url> --private-key <key> --broadcast
```

The script broadcasts from whichever signer the command line supplies; a
keystore account (`--account <name>`) or hardware wallet works in place of the
raw key.

The broadcast deploys the `DepositMailbox` logic, the `SubnetClone` logic, the
`AlphaVault` whose constructor deploys its own `CloneFactory`, and
`AlphaVaultLens(vault)`. Forge also deploys the `VaultAllocation` library and
links its address into the vault bytecode, so each vault is bound to one library
deployment. Deploying by hand needs the same link, passed as
`--libraries src/libraries/VaultAllocation.sol:VaultAllocation:<address>`.
`VaultAllocation` is the only linked library; the other libraries under
`src/libraries/` compile into the contracts that use them and need no address.

Every vault parameter is immutable: `validatorRegistry`, `recoveryWindow`,
`parkingHotkey` and `cloneFactory` are fixed at deployment and the vault has no
admin or upgrade path. Changing any of them means deploying a new vault, and a
rebuilt library means a new vault as well.

## Verification after deployment

- `lens.vault()` returns the vault address.
- `vault.validatorRegistry()`, `vault.recoveryWindow()` and
  `vault.parkingHotkey()` return the intended values.
- `getHotkeyOwner(parkingHotkey)` on the staking precompile `0x0805` returns the
  vault's own coldkey, which is `addressMapping(vault)` on the address-mapping
  precompile `0x080C`.
- The library address embedded in the deployed vault bytecode equals the
  deployed `VaultAllocation` address.
- Every address, its runtime code hash and the commit it was built from go into
  the table at the end of this page.

## Runtime compatibility

The vault reads and writes chain state through precompiles. It requires a
chain fully compatible with Subtensor runtime 478 for the precompile functions
below, honoring the rule next to each, with no breaking change to those
functions introduced since.

| Precompile | Function | Rule relied on |
| --- | --- | --- |
| Staking `0x0805` | `getStake` | Returns the alpha held by a (hotkey, coldkey, netuid) triple, a chain u64 encoded as ABI uint256. |
| Staking `0x0805` | `getHotkeyOwner` | Reports no owner record once an all-subnet hotkey swap carries the stake away, and stake operations require that record. |
| Staking `0x0805` | `getHotkeySuccessor` | Names the key a swap carried a hotkey's stake to. Subnet re-registration can erase the edge, so no edge does not prove there was no swap. |
| Staking `0x0805` | `getColdkeyLock` | Reports the conviction-locked alpha an account holds on a subnet, rolled forward to the current block. A same-subnet transfer carries the lock along once the sender's unlocked alpha is spent. |
| Staking `0x0805` | `getRejectLockedAlpha` | Accounts reject incoming locked alpha by default, and this flag reports that setting. A coldkey swap into an account with no stake copies the source's flag. |
| Staking `0x0805` | `getColdkeyRoot` | Reports the first coldkey of an account's swap lineage, absent for an account that never received a swap. Every swap copies the source's root onto the destination, so a validator's hotkeys stay under one root across its coldkey swaps and an account that receives a swap takes the incoming root. |
| Staking `0x0805` | `getOwnedHotkeys` | Lists the hotkeys an account owns; an uncontaminated clone candidate owns none. |
| Staking `0x0805` | `getDefaultMinStake` | The minimum a partial unstake enforces, in RAO; transfers and moves have a lower minimum, so the vault applies this one to every move as its conservative floor. |
| Staking `0x0805` | `getNominatorMinRequiredStake` | The TAO spot-value minimum, in RAO, a nominator may hold; a partial unstake that leaves less force-sells the remainder. |
| Staking `0x0805` | `moveStake` | A same-subnet move enforces the chain's transfer minimum, which is the lower of the two minimums. |
| Staking `0x0805` | `transferStake` | Delivers alpha to another coldkey on the same subnet; the chain's transfer minimum applies. |
| Staking `0x0805` | `removeStake` | A partial unstake enforces the default minimum stake and lowers the caller's `getStake` by at most the requested amount; a full drain of a position clears it. |
| Subnet `0x0803` | `getNetworkRegistrationBlock` | Zero while a netuid is unregistered. |
| Subnet `0x0803` | `getRegisteredSubnetCounter` | Steps on every registration and survives dissolution, so it tells subnet generations apart. |
| Subnet `0x0803` | `isSubnetDissolving` | Reports a subnet whose dissolution is under way. |
| Subnet `0x0803` | `getSubnetCapacityConfig` | Its tenth field is the owner's alpha-transfer switch. |
| Neuron `0x0804` | `tryAssociateHotkey` | Assigns the caller's coldkey as owner only when the hotkey has none, and succeeds silently otherwise. |
| Alpha `0x0808` | `getAlphaPrice` | Prices alpha in TAO, scaled by 1e18. |
| Alpha `0x0808` | `simSwapAlphaForTao` | Quotes the post-fee, post-slippage TAO a sale of a given alpha amount returns, in RAO. |
| Address mapping `0x080C` | `addressMapping` | Returns the substrate coldkey an EVM address controls. |

Two further rules sit outside any single function: the chain refuses a coldkey
swap into an account that is itself a hotkey, which is what keeps mailboxes and
subnet clones clean, and a rejected precompile call consumes all forwarded gas,
which is why the vault checks conditions before calling.

## Deployed artifacts

Nothing is deployed on a public network yet. Each deployment adds a row.

| Network | Contract | Address | Code hash | Deployed at commit |
| --- | --- | --- | --- | --- |
| | | | | |

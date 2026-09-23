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

The vault reads and writes chain state through precompiles. A runtime must
provide each function below and honor the rule next to it.

| Precompile | Function | Rule relied on | Known minimum source commit |
| --- | --- | --- | --- |
| Staking `0x0805` | `getStake` | Returns the alpha held by a (hotkey, coldkey, netuid) triple, a chain u64 encoded as ABI uint256. | `b61dd30202ff6e970a18b5a5231b62183b6ba972` |
| Staking `0x0805` | `getHotkeyOwner` | Reports no owner record once an all-subnet hotkey swap removes it, and stake operations require that record. | `d3f40e44bda9019c606aeb0c907bb52ba7fe386c` |
| Staking `0x0805` | `getHotkeySuccessor` | Names the key a swap carried a hotkey's stake to. | `d3f40e44bda9019c606aeb0c907bb52ba7fe386c` |
| Staking `0x0805` | `getColdkeyLock` | Reports the conviction-locked alpha an account holds on a subnet. | `cda8fd76ad2a7014cac632933237abf1ddaa9b30` |
| Staking `0x0805` | `getRejectLockedAlpha` | Accounts reject incoming locked alpha by default, and this flag reports that setting. | `cda8fd76ad2a7014cac632933237abf1ddaa9b30` |
| Staking `0x0805` | `getColdkeyRoot` | Reports whether an account carries coldkey-swap history. | `d3f40e44bda9019c606aeb0c907bb52ba7fe386c` |
| Staking `0x0805` | `getOwnedHotkeys` | Lists the hotkeys an account owns; an uncontaminated clone candidate owns none. | `d3f40e44bda9019c606aeb0c907bb52ba7fe386c` |
| Staking `0x0805` | `getDefaultMinStake` | The minimum a partial unstake enforces; the vault applies it to every move as its conservative floor. | `c1463f2cc62e7de70aa3379ee53cfc5f060bde42` |
| Staking `0x0805` | `getNominatorMinRequiredStake` | The minimum a nominator may hold; the chain can sweep smaller positions into TAO. | `7b541095b057a68e0090d8348bdc96a70dc56be8` |
| Staking `0x0805` | `moveStake` | A same-subnet move enforces the chain's transfer minimum, which is the lower of the two minimums. | `6b86ebf30d3fb83f9d43ed4ce713c43204394e67` |
| Staking `0x0805` | `transferStake` | Delivers alpha to another coldkey on the same subnet; the chain's transfer minimum applies. | `6b86ebf30d3fb83f9d43ed4ce713c43204394e67` |
| Staking `0x0805` | `removeStake` | A partial unstake enforces the default minimum stake; a full drain of a position clears it. | `b61dd30202ff6e970a18b5a5231b62183b6ba972` |
| Subnet `0x0803` | `getNetworkRegistrationBlock` | Zero while a netuid is unregistered. | `06032d518fbaead1ddc2039e9e6aa55715026364` |
| Subnet `0x0803` | `getRegisteredSubnetCounter` | Steps on every registration and survives dissolution, so it tells subnet generations apart. | `d3f40e44bda9019c606aeb0c907bb52ba7fe386c` |
| Subnet `0x0803` | `isSubnetDissolving` | Reports a subnet whose dissolution is under way. | `9c8e26e7fccc76327ab5204f7978aa2e4d86efd6` |
| Subnet `0x0803` | `getSubnetCapacityConfig` | Its tenth field is the owner's alpha-transfer switch. | `d3f40e44bda9019c606aeb0c907bb52ba7fe386c` |
| Neuron `0x0804` | `tryAssociateHotkey` | Assigns the caller's coldkey as owner only when the hotkey has none, and succeeds silently otherwise. | `d3f40e44bda9019c606aeb0c907bb52ba7fe386c` |
| Alpha `0x0808` | `getAlphaPrice` | Prices alpha in TAO, scaled by 1e18. | `52378dc3e911cdfc7b8e3cf1160a6e0e4dde4fd6` |
| Alpha `0x0808` | `simSwapAlphaForTao` | Quotes the TAO a sale of a given alpha amount returns. | `e9bbb6134984b1f9f63f5e55408faad7628eb059` |
| Address mapping `0x080C` | `addressMapping` | Returns the substrate coldkey an EVM address controls. | `f74d69ed52e66c42476c94cdbeac8018f5c5567b` |

Two further rules sit outside any single function: the chain refuses a coldkey
swap into an account that is itself a hotkey, which is what keeps mailboxes and
subnet clones clean, and a rejected precompile call consumes all forwarded gas,
which is why the vault checks conditions before calling.

The behavior above is tested against Subtensor source commit
`14cde6410fe8ec81a940e290c56f94a632a0988d`.
A runtime that breaks any rule above is unsuitable for deployment.

## Deployed artifacts

Nothing is deployed on a public network yet. Each deployment adds a row.

| Network | Contract | Address | Code hash | Deployed at commit |
| --- | --- | --- | --- | --- |
| | | | | |

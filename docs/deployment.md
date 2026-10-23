# Deployment

Each integrator deploys and operates its own vault, and chooses its
validator-selection strategy, registry governance and operational controls first.

1. Choose or implement an `IValidatorRegistry`. The included
   `BasicValidatorRegistry` is the simplest example.
2. Deploy and configure the registry for every subnet in scope.
3. Deploy the vault set with `script/DeployAlpha.s.sol`, pointed at that registry.
4. Run the verification checks below, then record the addresses and code hashes.

## Registry

`BasicValidatorRegistry(initialOwner)` assigns each subnet one validator at 100%
weight. Updates take effect immediately. Ownership transfers use OpenZeppelin
`Ownable2Step`.

```sh
forge create src/BasicValidatorRegistry.sol:BasicValidatorRegistry \
  --rpc-url <url> --private-key <key> --broadcast \
  --constructor-args <initialOwner>

cast send <registry> 'setValidator(uint256,bytes32)' <netuid> <hotkey> \
  --rpc-url <url> --private-key <owner-key>
```

The hotkey must have an owner record. Downstream `IValidatorRegistry`
implementations must reject duplicate hotkeys before publishing a set.

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
`src/libraries/` compile into the contracts that use them.

Every vault parameter is immutable: `validatorRegistry`, `recoveryWindow`,
`parkingHotkey` and `cloneFactory` are fixed at deployment. Changing any of them,
or rebuilding the library, means deploying a new vault.

## Verification after deployment

- `lens.vault()` returns the vault address.
- `vault.validatorRegistry()`, `vault.recoveryWindow()` and
  `vault.parkingHotkey()` return the intended values.
- `getHotkeyOwner(parkingHotkey)` on the staking precompile `0x0805` returns the
  vault's own coldkey, which is `addressMapping(vault)` on the address-mapping
  precompile `0x080C`, and `getRejectStakingHotkeyGrowth` of that coldkey is true.
- The library address embedded in the deployed vault bytecode equals the
  deployed `VaultAllocation` address.
- Every address, its runtime code hash and the commit it was built from go into
  the table at the end of this page.

## Runtime compatibility

The vault reads and writes chain state through precompiles. It requires a
chain whose precompile functions below behave as in Subtensor runtime 481,
honoring the rule next to each.

| Precompile | Function | Rule relied on |
| --- | --- | --- |
| Staking `0x0805` | `getStake` | Returns the alpha held by a (hotkey, coldkey, netuid) triple, a chain u64 encoded as ABI uint256. |
| Staking `0x0805` | `getHotkeyOwner` | Reports a hotkey's owner record, which an all-subnet hotkey swap carrying the stake away clears; stake operations require that record. |
| Staking `0x0805` | `getHotkeySuccessor` | Names the key a swap carried a hotkey's stake to. |
| Staking `0x0805` | `getColdkeyLock` | Reports the conviction-locked alpha an account holds on a subnet. |
| Staking `0x0805` | `getRejectLockedAlpha` | Accounts reject incoming locked alpha by default, and this flag reports that setting. |
| Staking `0x0805` | `getColdkeyRoot` | Reports whether an account carries coldkey-swap history. |
| Staking `0x0805` | `getOwnedHotkeys` | Lists the hotkeys an account owns; a clone candidate that owns any is contaminated. |
| Staking `0x0805` | `getDefaultMinStake` | The minimum a partial unstake enforces; the vault applies it to every move as its conservative floor. |
| Staking `0x0805` | `getNominatorMinRequiredStake` | The minimum a nominator may hold; the chain can sweep smaller positions into TAO. |
| Staking `0x0805` | `moveStake` | A same-subnet move enforces the chain's transfer minimum, which is the lower of the two minimums. A move onto a hotkey the caller does not list is refused once its staking list holds 256 entries. |
| Staking `0x0805` | `transferStake` | Delivers alpha to another coldkey on the same subnet; the chain's transfer minimum applies. The receiver always admits a hotkey it already lists; otherwise only while its list is under the third-party cap and, once it refuses list growth, only a hotkey it owns. |
| Staking `0x0805` | `transferStakeAndHotkey` | Delivers alpha to another coldkey on the same subnet onto a different hotkey, under the same admission rule and minimum. |
| Staking `0x0805` | `setRejectStakingHotkeyGrowth` | Makes the calling account refuse staking-list growth by other accounts; a hotkey it associates to itself still joins its list. |
| Staking `0x0805` | `getRejectStakingHotkeyGrowth` | Reports that flag; the chain default is to allow growth. |
| Staking `0x0805` | `getStakingHotkeys` | Reports an account's staking list length and one page of at most 64 entries. An entry stays while the account holds stake under that hotkey on any subnet, or a root-dividend record for the pair; dissolving a subnet removes the stake there and leaves the entry. |
| Staking `0x0805` | `removeStake` | A partial unstake enforces the default minimum stake and lowers the caller's `getStake` by at most the requested amount; a full drain of a position clears it, on any subnet. |
| Subnet `0x0803` | `getNetworkRegistrationBlock` | Zero while a netuid is unregistered. |
| Subnet `0x0803` | `getRegisteredSubnetCounter` | Steps on every registration and survives dissolution, so it tells subnet generations apart. |
| Subnet `0x0803` | `isSubnetDissolving` | Reports a subnet whose dissolution is under way. |
| Subnet `0x0803` | `getSubnetCapacityConfig` | Its tenth field is the owner's alpha-transfer switch. |
| Neuron `0x0804` | `tryAssociateHotkey` | Assigns the caller's coldkey as owner only when the hotkey has none, and succeeds silently otherwise. A newly owned hotkey joins the caller's staking list, so the call is refused once that list holds 256 entries. |
| Runtime configuration `0x0812` | `getBalancesConstants` | Its first value is the existential deposit in EVM wei: an account's balance hides that much, and a transfer that would leave a fresh account below it is refused. |
| Alpha `0x0808` | `getAlphaPrice` | Prices alpha in TAO, scaled by 1e18. |
| Alpha `0x0808` | `simSwapAlphaForTao` | Quotes the TAO a sale of a given alpha amount returns. |
| Address mapping `0x080C` | `addressMapping` | Returns the substrate coldkey an EVM address controls. |

Two further rules sit outside any single function: the chain refuses a coldkey
swap into an account that is itself a hotkey, which is what keeps mailboxes and
subnet clones clean, and a rejected precompile call consumes all forwarded gas,
which is why the vault checks conditions before calling.

## Deployed artifacts

Each deployment adds a row.

| Network | Contract | Address | Code hash | Deployed at commit |
| --- | --- | --- | --- | --- |
| | | | | |

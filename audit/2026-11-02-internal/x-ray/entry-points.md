# Entry Point Map

> alpha-wrapper | 25 entry points | 13 permissionless | 11 role-gated (vault-only) | 1 admin-only

Scan source: `entry_points.py src` found 34 non-view external/public functions in 7 files; 9 of them are `VaultAllocation` external-library functions, which revert on direct call and are listed as downstream calls, not entry points. `CloneBase.initialize()` is a one-time initializer (see end).

---

## Protocol Flow Paths

### Setup (Deployer / Registry Owner)

`new BasicValidatorRegistry(owner)` → `setValidator(netuid, hotkey)` ◄── hotkey has an owner record
→ `new AlphaVault(uri, mailboxLogic, subnetLogic, registry, recoveryWindow, parkingHotkey)` ◄── parkingHotkey ownerless at deploy; vault claims it and sets reject-growth on its own list
→ `new AlphaVaultLens(vault)`

### Depositor Flow

`[setup above]` → `createMailbox(netuid, uid)` ◄── subnet registered, not dissolving; first caller also deploys the subnet clone
→ [user transfers alpha to the mailbox coldkey on Substrate, staked under the mailbox's own hotkey]
→ `wrap(netuid, chosenHotkey, minSharesOut)` ◄── deposit ≥ floor, transfers enabled, hotkey in set, not parked, backing intact, mailbox unlocked
    ├─→ `unwrap(tokenId, shares, coldkey, minAlphaOut)` ◄── live: transfers enabled + intact; dissolved: generation gone
    ├─→ `unwrapForTao(tokenId, shares, minTaoOut[, excludedSlots])` ◄── intact, pool pays each slot
    ├─→ ERC-1155 `safeTransferFrom` → `claimTao(tokenId, recipient)` ◄── TAO arrived on the clone
    └─→ `claimTao(tokenId, recipient)`

### Mailbox Reclaim

`createMailbox(netuid, uid)` → [alpha or TAO sits in the mailbox]
    ├─→ `reclaimAlphaFromMailbox(netuid, destColdkey)` ◄── transfers enabled; locked deposit only to a lock-accepting coldkey
    ├─→ `reclaimMailboxAlphaAsTao(netuid, minTaoOut)` ◄── deposit unlocked
    └─→ `reclaimTaoFromMailbox(netuid)` ◄── mailbox TAO balance > 0

### Maintenance (Anyone / Keeper)

`[wrap above]` → `setValidator` (owner, optional) → `rebalance(netuid)` ◄── not parked, no retired attested entry

### Recovery (Watcher)

`[wrap above]` → [validator hotkey swap or chain sweep leaves located backing < tracked]
→ `syncBacking(tokenId)` ◄── declares the shortfall; secures located piles on parking; starts the window
→ `recoverStray(tokenId, source)` ◄── `source` holds vault alpha the record does not name (repeatable)
→ `syncBacking(tokenId)` ◄── full coverage → cleared; or `block.timestamp ≥ shortSince + recoveryWindow` → write-off
→ `setValidator(netuid, hotkey)` (owner; bumps nonce) → `wrap` / `rebalance` / `unwrap` releases the parked position

### Clone Replacement (Anyone)

`[wrap above]` → [clone staking list ≥ 128 entries] → `replaceClone(tokenId, uid)` ◄── transfers enabled, intact, not dissolved

---

## Permissionless

All `AlphaVault` entry points are `external nonReentrant` with no caller restriction beyond ownership of the shares or mailbox being acted on.

### `AlphaVault.wrap()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant |
| Caller | Depositor who prepared a mailbox |
| Parameters | netuid (user-controlled), chosenHotkey (user-controlled, must be in registry set), minSharesOut (user-controlled) |
| Call chain | `→ currentTokenId() → VaultReads.resolveValidators() → _openBacking() → VaultAllocation.assignActives() → VaultAllocation.admitDeposit() → VaultAllocation.collectDeposit() → DepositMailbox.transferStakeAndHotkey() → [SubnetClone.setRejectStakingHotkeyGrowth()] → VaultAllocation.consolidateRotatedStake() → VaultAllocation.rebalance() → SubnetClone.moveStake() → _settle() → _mint()` |
| State modified | `_slots[tokenId]`, `recovery[tokenId]` (delete when released), ERC-1155 supply/balances, `cumulativeTaoPerShare`/`taoLiability`/`taoIndexDebt`/`claimableTao` via `_update` |
| Value flow | Alpha: mailbox coldkey → clone coldkey (chain stake transfer); shares minted to caller |
| Reentrancy guard | yes |

### `AlphaVault.createMailbox()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant |
| Caller | Depositor |
| Parameters | netuid (user-controlled), uid (user-controlled salt) |
| Call chain | `→ currentTokenId() → VaultAllocation.deployMissingClone() → CloneFactory.deploySubnetClone() → CloneFactory.deployCloneOwner() → SubnetClone.initialize() → VaultAllocation.deployMissingMailbox() → CloneFactory.deployMailbox() → DepositMailbox.initialize()` |
| State modified | `subnetClone[tokenId]` (first caller), `_mailboxes[msg.sender][netuid]` |
| Value flow | None (deploys contracts; clones claim hotkeys on chain) |
| Reentrancy guard | yes |

### `AlphaVault.unwrap()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant |
| Caller | Share holder |
| Parameters | tokenId (user-controlled), shares (user-controlled), userSubstrateColdkey (user-controlled), minAlphaOut (user-controlled) |
| Call chain | live: `→ _openBacking() → VaultAllocation.assignActives() → VaultAllocation.consolidateRotatedStake() → _burn() → VaultAllocation.deliverAndAlign() / deliver() → SubnetClone.moveStake() → SubnetClone.flush() → _settle()`; dissolved: `→ _burn() → SubnetClone.unwrapTao()` |
| State modified | ERC-1155 supply/balances, `_slots[tokenId]`, `recovery[tokenId]`, TAO index fields via `_update` |
| Value flow | Alpha: clone coldkey → user coldkey (live); TAO: clone → caller (dissolved) |
| Reentrancy guard | yes |

### `AlphaVault.unwrapForTao()` (two overloads)

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant |
| Caller | Share holder |
| Parameters | tokenId, shares, minTaoOut (user-controlled); excludedSlots (user-controlled bitmask over recorded slots) |
| Call chain | `→ _openBacking() → _burn() → VaultAllocation.sellForTao() → SubnetClone.sellAlphaForTao() [per slot] → VaultReads.fetchBalances() → _reanchor() → [_mint() refund] → SubnetClone.unwrapTao()` |
| State modified | ERC-1155 supply/balances, `_slots[tokenId].active/tracked`, `taoLiability` (temporary bump around refund mint), `recovery[tokenId]` (delete at zero supply), TAO index fields |
| Value flow | Alpha sold to pool from clone; TAO: clone → caller |
| Reentrancy guard | yes |

### `AlphaVault.claimTao()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant |
| Caller | Share holder (current or former) |
| Parameters | tokenId (user-controlled), recipient (user-controlled) |
| Call chain | `→ _syncTao() → _checkpoint() → SubnetClone.unwrapTao()` |
| State modified | `cumulativeTaoPerShare`, `taoLiability`, `taoIndexDebt`, `claimableTao` |
| Value flow | TAO: clone → recipient |
| Reentrancy guard | yes |

### `AlphaVault.reclaimAlphaFromMailbox()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant |
| Caller | Mailbox owner |
| Parameters | netuid (user-controlled), destSubstrateColdkey (user-controlled) |
| Call chain | `→ _requireMailbox() → StakeOps.flush() → DepositMailbox.flush() → IStaking.transferStake()` |
| State modified | None in vault |
| Value flow | Alpha: mailbox coldkey → destination coldkey |
| Reentrancy guard | yes |

### `AlphaVault.reclaimMailboxAlphaAsTao()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant |
| Caller | Mailbox owner |
| Parameters | netuid (user-controlled), minTaoOut (user-controlled) |
| Call chain | `→ _requireMailbox() → StakeOps.sell() → DepositMailbox.sellAlphaForTao() → IStaking.removeStake() → DepositMailbox.unwrapTao()` |
| State modified | None in vault |
| Value flow | Alpha sold to pool; TAO: mailbox → caller |
| Reentrancy guard | yes |

### `AlphaVault.reclaimTaoFromMailbox()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant |
| Caller | Mailbox owner |
| Parameters | netuid (user-controlled) |
| Call chain | `→ _requireMailbox() → DepositMailbox.unwrapTao()` |
| State modified | None |
| Value flow | TAO: mailbox → caller |
| Reentrancy guard | yes |

### `AlphaVault.rebalance()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant |
| Caller | Anyone (keeper) |
| Parameters | netuid (user-controlled) |
| Call chain | `→ currentTokenId() → VaultReads.resolveValidators() → _openBacking() → VaultAllocation.assignActives() → VaultAllocation.consolidateRotatedStake() → VaultAllocation.rebalance() → SubnetClone.moveStake() → _settle()` |
| State modified | `_slots[tokenId]`, `recovery[tokenId]` (delete when released) |
| Value flow | Alpha moves between the clone's own hotkeys |
| Reentrancy guard | yes |

### `AlphaVault.syncBacking()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant |
| Caller | Anyone (watcher) |
| Parameters | tokenId (user-controlled) |
| Call chain | `→ VaultReads.resolveBacking() → [_reanchor()] or → _secureBacking() → _gather() → VaultAllocation.consolidateRotatedStake() → SubnetClone.moveStake() → _startRecovery() / _finishRecovery()` |
| State modified | `_slots[tokenId]` (rewritten to parking layout or collapsed to one slot), `recovery[tokenId]` |
| Value flow | Alpha moves from located hotkeys onto `parkingHotkey` within the clone |
| Reentrancy guard | yes |

### `AlphaVault.recoverStray()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant |
| Caller | Anyone (watcher) |
| Parameters | tokenId (user-controlled), source (user-controlled hotkey) |
| Call chain | no shortfall: `→ _openBacking() → _annex() → _gather() → VaultAllocation.consolidateRotatedStake() → SubnetClone.moveStake() → _reanchor()`; shortfall: `→ _secureBacking() → _gather() → …` |
| State modified | `_slots[tokenId].active/tracked` (annex path only) |
| Value flow | Alpha moves from `source` onto the home slot or parking within the clone |
| Reentrancy guard | yes |

### `AlphaVault.replaceClone()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant |
| Caller | Anyone |
| Parameters | tokenId (user-controlled), uid (user-controlled salt) |
| Call chain | `→ _openBacking() → VaultReads.replacementOpen() → VaultAllocation.replaceClone() → VaultClones.deployProtectedClone() → CloneFactory.deploySubnetClone() → CloneFactory.deployCloneOwner() → SubnetClone.initialize() → SubnetClone.setRejectStakingHotkeyGrowth() → StakeOps.flush() [per above-floor slot] → SubnetClone.transferAllTao() → _reanchor()` |
| State modified | `subnetClone[tokenId]`, `_slots[tokenId].active/tracked` |
| Value flow | Alpha (above-floor slots) and all TAO: old clone → successor clone |
| Reentrancy guard | yes |

---

## Role-Gated

### `onlyWrapper` (the vault, as the clone's `wrapper`)

| Contract | Function | Parameters | State Modified / Effect |
|----------|----------|------------|-------------------------|
| CloneBase (DepositMailbox, SubnetClone) | `flush(destinationColdkey, hotkey, netuid, amount)` | all protocol-derived | `IStaking.transferStake` from the clone coldkey |
| CloneBase (DepositMailbox, SubnetClone) | `unwrapTao(to, amount)` | protocol-derived | Native TAO sent from the clone |
| CloneBase (DepositMailbox, SubnetClone) | `sellAlphaForTao(hotkey, netuid, amount)` | protocol-derived | `IStaking.removeStake` from the clone |
| DepositMailbox | `transferStakeAndHotkey(destColdkey, fromHotkey, toHotkey, netuid, amount)` | protocol-derived | `IStaking.transferStakeAndHotkey` mailbox → clone |
| SubnetClone | `moveStake(fromHotkey, toHotkey, netuid, amount)` | protocol-derived | `IStaking.moveStake` within the clone |
| SubnetClone | `setRejectStakingHotkeyGrowth(enabled)` | protocol-derived | Chain flag on the clone coldkey |
| SubnetClone | `transferAllTao(destination)` | protocol-derived | Whole native balance to the successor |

### `onlyVault` (CloneFactory)

| Contract | Function | Parameters | State Modified / Effect |
|----------|----------|------------|-------------------------|
| CloneFactory | `deployMailbox(user, netuid, uid)` | user, uid user-controlled via `createMailbox` | CREATE2 clone after `_requireClean` |
| CloneFactory | `deploySubnetClone(tokenId, netuid, uid)` | uid user-controlled | CREATE2 clone after `_requireClean` |
| CloneFactory | `deployCloneOwner(hotkey, netuid)` | protocol-derived | CREATE2 `CloneOwner` that claims the clone's coldkey as its hotkey |

---

## Admin-Only

| Contract | Function | Parameters | State Modified |
|----------|----------|------------|----------------|
| BasicValidatorRegistry | `setValidator(netuid, hotkey)` | netuid, hotkey (owner-provided) | `_hotkeys[netuid]`, `nonces[netuid]++` (instant, no delay) |
| BasicValidatorRegistry | `transferOwnership(newOwner)` / `acceptOwnership()` (OpenZeppelin Ownable2Step) | newOwner | `_pendingOwner`, `_owner` |
| BasicValidatorRegistry | `renounceOwnership()` | — | Always reverts `RenunciationDisabled` |

`AlphaVault`, `AlphaVaultLens`, `CloneFactory` and the clones have no admin functions and no upgrade path.

---

## Initialization

| Contract | Function | Notes |
|----------|----------|-------|
| CloneBase (DepositMailbox, SubnetClone) | `initialize()` | No modifier; first caller becomes `wrapper`. Called by the vault in the same transaction as CREATE2 deployment (`VaultClones._initializeClone`), and the factory is `onlyVault`, so no external window exists. Implementation contracts latch `initialized = true` in their constructor. |
| CloneOwner | constructor | Claims the subnet clone's coldkey as its hotkey at deployment. |
| AlphaVault | constructor | Claims `parkingHotkey`, verifies ownership, sets reject-growth on its own list, deploys `CloneFactory`. |

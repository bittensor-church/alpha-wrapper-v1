# Run 1 — solidity-auditor

<!--RUN pass=1 of=1 stamp=20261102-194757 sha=b986e47 agents=12/12-->

Pass 1 of 1 · 2026-11-02 · `b986e47` · 12/12 agents returned.

## Findings

<!--F key=vaultreads|resolvebacking|stranger-cuts-swap-edge conf=75 kind=FINDING agents=1-->

[75] **Anyone can cut the swap edge of a vacated hotkey and park the position**

`VaultReads.resolveBacking` · Confidence: 75

**Description**
After a validator's all-subnet swap, any account claims the vacated attested hotkey and swaps it for 0.001 TAO, so the successor edge points at an empty key, every priced call reverts BackingShortfall and the position parks until a watcher names the real location and the registry republishes.

**Fix**

```diff
     function recoverStray(uint256 tokenId, bytes32 source) external nonReentrant {
         ...
         if (recovery[tokenId].shortSince == 0) {
-            (, VaultReads.Backing memory backing) = _openBacking(tokenId, coldkey, netuid);
-            if (VaultMath.contains(backing.hotkeys, source)) revert NothingToRecover();
-            _annex(tokenId, clone, coldkey, backing.hotkeys, sources);
-            return;
+            VaultReads.Slot[] memory slots = _slots[tokenId];
+            VaultReads.Backing memory backing = VaultReads.resolveBacking(slots, coldkey, netuid);
+            uint256 shortIndex = VaultReads.firstShortOf(backing.short);
+            if (shortIndex != VaultReads.NO_SHORT_SLOT) {
+                // A short slot may be re-anchored onto a caller-named hotkey that covers its expectation.
+                uint256 located = IStaking(STAKING_PRECOMPILE).getStake(source, coldkey, netuid);
+                if (!VaultReads.coversTracked(located, slots[shortIndex].tracked)) revert NothingToRecover();
+                if (VaultMath.contains(backing.hotkeys, source)) revert NothingToRecover();
+                backing.hotkeys[shortIndex] = source; backing.balances[shortIndex] = located;
+                _reanchor(tokenId, backing.hotkeys, backing.balances);
+                emit BackingRecovered(tokenId, source, located);
+                return;
+            }
+            if (VaultMath.contains(backing.hotkeys, source)) revert NothingToRecover();
+            _annex(tokenId, clone, coldkey, backing.hotkeys, sources);
+            return;
         }
```

<!--/F-->

<!--F key=vaultreads|resolvevalidators|duplicate-attested-hotkeys conf=75 kind=FINDING agents=2-->

[75] **A duplicate hotkey in the validator set counts one balance twice**

`VaultReads.resolveValidators` · Confidence: 75

**Description**
A registry that returns the same hotkey in two entries makes `assignActives` and `_settle` record two slots on one balance, so a minority holder withdraws up to twice their share from the other holders.

**Fix**

```diff
     function resolveValidators(IValidatorRegistry registry, uint16 netuid) internal view returns (ValidatorSet memory set) {
         (bytes32[] memory hotkeys, uint16[] memory weights) = registry.getValidators(netuid);
         if (hotkeys.length == 0) revert NoValidatorFound();
         if (hotkeys.length > MAX_VALIDATORS) revert ValidatorSetTooLarge(hotkeys.length);
         if (hotkeys.length != weights.length) revert ValidatorSetMalformed();
+        for (uint256 i; i < hotkeys.length;) {
+            if (hotkeys[i] == bytes32(0)) revert ValidatorSetMalformed();
+            for (uint256 j = i + 1; j < hotkeys.length;) {
+                if (hotkeys[i] == hotkeys[j]) revert ValidatorSetMalformed();
+                unchecked { ++j; }
+            }
+            unchecked { ++i; }
+        }
         set = ValidatorSet({ hotkeys: hotkeys, weights: weights });
     }
```

<!--/F-->

<!--F key=vaultreads|resolvevalidators|unvalidated-weight-sum conf=75 kind=FINDING agents=4-->

[75] **Weights that sum above 10000 make every priced call revert**

`VaultReads.resolveValidators` · Confidence: 75

**Description**
The vault never checks that the registry's weights sum to 10000, so a set such as [6000, 6000, 1] makes `_alignToWeights` underflow and every wrap, rebalance and alpha unwrap reverts until the registry republishes.

**Fix**

```diff
         if (hotkeys.length != weights.length) revert ValidatorSetMalformed();
+        uint256 weightSum;
+        for (uint256 i; i < weights.length;) { weightSum += weights[i]; unchecked { ++i; } }
+        if (weightSum != VaultMath.BPS_BASE) revert ValidatorSetMalformed();
         set = ValidatorSet({ hotkeys: hotkeys, weights: weights });
```

<!--/F-->

<!--F key=vaultallocation|replaceclone|over-restrictive-floor-abandons-stake conf=75 kind=FINDING agents=2-->

[75] **replaceClone abandons piles the chain would move**

`VaultAllocation.replaceClone` · Confidence: 75

**Description**
The vault floors same-subnet moves at `getDefaultMinStake` (2 000 000 RAO) while the chain floors them at `DefaultMinTransfer` (100 000 RAO), so any caller of `replaceClone` drops every slot worth between the two from the record and the holders lose it.

**Fix**

```diff
+    /// @dev The chain's same-subnet transfer minimum (DefaultMinTransfer); no precompile exposes it.
+    uint256 internal constant MIN_TRANSFER_TAO_RAO = 100_000;
+
     function replaceClone(CloneFactory factory, Context memory context, bytes32[] memory hotkeys,
         uint256[] memory balances, bytes32 uid) external returns (address successor) {
         ...
         for (uint256 i; i < hotkeys.length;) {
-            if (balances[i] != 0 && !StakeOps.isBelowFloorAtReadPrice(balances[i], context.alphaPriceE18)) {
+            if (balances[i] != 0
+                && (context.alphaPriceE18 == 0
+                    || StakeOps.taoValue(balances[i], context.alphaPriceE18) >= MIN_TRANSFER_TAO_RAO)) {
                 StakeOps.flush(context.clone, hotkeys[i], successorColdkey, context.netuid, balances[i]);
             }
             unchecked { ++i; }
         }
```

<!--/F-->

## Leads

<!--F key=clonebase|initialize|dust-forces-retained-stake-on-subnet-swap kind=LEAD agents=4-->

- **Dust on another subnet makes the clone keep its stake on the old hotkey at a per-subnet swap** — `CloneBase.initialize` — Code smells: the clone rejects list growth, the chain admits third-party stake onto any hotkey the clone already lists on any netuid (`stake_utils.rs:1568-1585`), and a per-subnet swap retains a growth-rejecting staker whose coldkey holds alpha under the old hotkey elsewhere (`stake_utils.rs:1534-1565`, `swap_hotkey.rs:789`) — A stranger plants dust under an attested hotkey on another subnet, so the validator's per-subnet swap leaves the vault's alpha on the old key and it earns nothing until the registry publishes the successor. The old key keeps its owner record (`swap_hotkey.rs:772` is commented out), so the stake stays movable; the all-subnet swap removes the owner record but passes an empty retained set (`swap_hotkey.rs:655-664`) and moves every staker, so the agents' "retained and ownerless" freeze is not reachable on this runtime.

<!--/F-->

<!--F key=stakeops|ensurehotkeyhasowner|vault-staking-list-cap kind=LEAD agents=4-->

- **Every ownerless-hotkey claim adds a permanent entry to the vault's own staking list** — `StakeOps.ensureHotkeyHasOwner` — Code smells: `tryAssociateHotkey` runs as the vault coldkey, `create_account_if_non_existent` pushes the hotkey onto the vault's `StakingHotkeys` (cap 256), the vault never stakes so nothing prunes the list — After 255 claims over the vault's lifetime every later claim reverts and stake under an ownerless hotkey cannot move for any token. We did not find an attacker path that forces claims at that rate.

<!--/F-->

<!--F key=clonefactory|requireclean|swap-reservation-not-checked kind=LEAD agents=3-->

- **A reserved candidate address fails inside the precompile instead of as CloneContaminated** — `CloneFactory._requireClean` — Code smells: `_requireClean` checks owner, root, owned hotkeys, lock and list but not a live coldkey-swap destination reservation; `CloneOwner`'s constructor and the mailbox's `_claimOwnHotkey` then revert in `tryAssociateHotkey` and burn the forwarded gas — An attacker who front-runs a revealed uid reserves the predicted clone or mailbox address for 0.1 TAO, so `createMailbox` or `replaceClone` fails once. The caller retries with a fresh uid, as the docs describe.

<!--/F-->

<!--F key=subnetclone|unwraptao|evm-balance-hides-existential-deposit kind=LEAD agents=7-->

- **The EVM balance hides the 500 RAO existential deposit on every clone** — `SubnetClone.unwrapTao` — Code smells: frontier `account_basic` returns `reducible_balance(Preservation::Preserve)`, so `clone.balance` is free minus 500 RAO; the vault prices `taoOut`, `unreservedTao` and `_syncTao` from that value — The first 500 RAO that reaches each clone is invisible to the vault and is never paid out. Six agents raised the inverse worry that a payout could reap the clone and strand `taoLiability`; the Preserve read means the vault can never spend below the deposit, so that path does not exist. Value is dust.

<!--/F-->

<!--F key=alphavault|replaceclone|stranded-alpha-on-replaced-clone kind=LEAD agents=2-->

- **replaceClone leaves vault alpha on unrecorded hotkeys of the old clone with no way back** — `AlphaVault.replaceClone` — Code smells: `VaultAllocation.replaceClone` flushes only `backing.hotkeys`; `subnetClone[tokenId]` is the only clone pointer the vault keeps; `recoverStray` and `syncBacking` read only the successor — Any caller can run `replaceClone` before the watcher recovers strays, so swap residue above the floor on the old clone becomes unreachable. The 128-entry precondition needs validator-side swap splits; we did not show an outsider reaches it.

<!--/F-->

<!--F key=alphavault|recoverstray|missing-retired-hotkey-guard kind=LEAD agents=1-->

- **recoverStray claims a retired slot-0 hotkey for the vault and clears the retired flag** — `AlphaVault.recoverStray` — Code smells: `_annex` picks `home = hotkeys[0]` without `StakeOps.hasOwner`, and `StakeOps.move` claims the destination; the next `assignActives` then sees a funded slot with an owner, so `retired` clears — Any caller turns a retired attested hotkey into a vault-owned receiving hotkey, so later wraps allocate alpha where no validator earns. We did not prove this is worse than the documented idle slot.

<!--/F-->

<!--F key=alphavault|wrap|stranded-stake-at-zero-supply kind=LEAD agents=1-->

- **Alpha recorded while no shares exist goes to the virtual shares** — `AlphaVault.wrap` — Code smells: `sharesFor(preStake, 0, deposit)` prices existing clone alpha into the 1e9 virtual shares; `recoverStray` after a full exit, a discarded sub-floor remainder and alpha found after a full write-off all leave such alpha — With 1e12 RAO on record and a 1e9 RAO first deposit the depositor gets 1e6 shares that redeem for 1e9, so the 1e12 stays in the clone and no later share can claim it. We found no path where an attacker gains from this.

<!--/F-->

<!--F key=alphavault|wrap|write-off-recapitalization-reaches-supply-cap kind=LEAD agents=1-->

- **Three full write-offs push totalSupply to SUPPLY_CAP and close deposits** — `AlphaVault.wrap` — Code smells: after a full write-off `preStake == 0`, so `sharesFor(0, S, d) = d × (S + 1e9)`; 1e18 → 1e27 → 1e36 → 1e45 with 1-alpha deposits — Each deposit after a full write-off multiplies supply by the deposit size, so the third recapitalization reaches `SUPPLY_CAP` and the token refuses deposits until the subnet re-registers. Holders can still exit; not attacker-triggerable without a real backing loss.

<!--/F-->

<!--F key=vaultallocation|collectdeposit|list-head-landing kind=LEAD agents=1-->

- **A deposit onto a zero-stake target lands on whatever hotkey heads the clone's list** — `VaultAllocation.collectDeposit` — Code smells: `getStakingHotkeys(coldkey, 0, 1)[0]` is the landing hotkey, `ensureHotkeyHasOwner(landing)` reverts when a third party reserved it, and a third party keeps any once-listed hotkey on the list by staking to it on another netuid — An attacker who makes the list head ownerless and reserves it blocks every deposit onto a new validator until the list head changes. We did not find a cheap way to make the list head ownerless, because swaps rename entries in place.

<!--/F-->

<!--F key=alphavault|unwrapfromlivesubnet|reserved-destination-gas-burn kind=LEAD agents=1-->

- **A reserved holder coldkey makes the alpha exit burn its gas** — `AlphaVault._unwrapFromLiveSubnet` — Code smells: `_flushMeasured` forwards `transferStake(userColdkey, …)` with no destination check; the chain refuses a destination held in `ColdkeySwapDestinationReservations`, which anyone reserves for 0.1 TAO; no precompile exposes the reservation by destination — An attacker reserves a holder's coldkey as a swap destination, so that holder's `unwrap` and `reclaimAlphaFromMailbox` fail and burn the forwarded gas. The holder can release the reservation or exit to another coldkey.

<!--/F-->

<!--F key=vaultallocation|sellablechunk|full-slot-simulation-dependency kind=LEAD agents=1-->

- **A partial sale simulates the whole slot even for a small chunk** — `VaultAllocation._sellableChunk` — Code smells: the leftover bound calls `simSwapAlphaForTao(netuid, balance)` on the full slot balance; a failed simulation is a precompile error that consumes the forwarded gas — A slot the pool cannot quote in full makes every partial sale of that slot revert, even for a chunk it would sell. We did not find the pool input that fails the full-balance simulation while a smaller chunk would sell; the exclusion mask is the escape hatch.

<!--/F-->

<!--F key=alphavault|unwrapfromdissolvedsubnet|sub-ed-refund-dropped kind=LEAD agents=1-->

- **A dissolution refund below the existential deposit is dropped by the chain** — `AlphaVault._unwrapFromDissolvedSubnet` — Code smells: dissolution credits the clone with `let _ = Self::transfer_tao_from_subnet(...)` and ignores the error; `transfer_tao` uses allow-death semantics with a 500 RAO existential deposit — A dissolved subnet that owes the clone less than 500 RAO pays nothing and holders redeem nothing. At most 500 RAO per clone; we did not confirm the clone account's existence state at that moment.

<!--/F-->

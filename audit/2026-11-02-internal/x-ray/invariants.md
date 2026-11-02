# Invariant Map

> alpha-wrapper | 38 guards | 20 inferred | 5 not enforced on-chain

---

## 1. Enforced Guards (Reference)

Per-call preconditions. Heading IDs below (`G-N`) are anchor targets from x-ray.md attack surfaces.

#### G-1
`if (awaitingAttestation(tokenId)) revert Parked()` · `AlphaVault.sol:123` · Deposits must not land on a parked position until the registry has published a set newer than the one in force at parking, so new money is not staked onto a hotkey the registry has already lost.

#### G-2
`if (clone == address(0)) revert SubnetCloneNotPrepared()` · `AlphaVault.sol:134` · A deposit needs a protected, clean clone coldkey to land on; without it there is no isolated account for the position.

#### G-3
`if (totalSupply(tokenId) + shares > SUPPLY_CAP) revert SupplyCapExceeded()` · `AlphaVault.sol:156` · Keeps `earnedAt` flooring loss below one native RAO quantum and keeps every whole-RAO TAO arrival indexable.

#### G-4
`if (balanceOf(msg.sender, tokenId) < shares) revert InsufficientShares()` · `AlphaVault.sol:170` · Burn authority is the caller's own balance; the same predicate guards the TAO exit at `AlphaVault.sol:203`.

#### G-5
`if (minAlphaOut != 0) revert SlippageExceeded(0)` · `AlphaVault.sol:174` · A dissolved position pays TAO, not alpha; a nonzero alpha floor is a stale intent and must not be silently satisfied with TAO.

#### G-6
`if (excludedSlots >> hotkeys.length != 0) revert SlotMaskOutOfRange()` · `AlphaVault.sol:210` · The exclusion mask must name only recorded slots so a caller cannot pass a mask that silently means something else after the record shrinks.

#### G-7
`if (total == 0) revert NothingToUnwrap()` · `AlphaVault.sol:213` · With no located alpha the TAO exit has nothing to sell; burning shares against zero would forfeit a later recovery claim.

#### G-8
`uint256 sold = total - VaultMath.sumBalances(postBalances)` (checked subtraction) · `AlphaVault.sol:231` · The chain's forced dust sale must not increase this caller's payout at remaining holders' expense; an underflow rejects a sale that swept more than the record held.

#### G-9
`if (taoOut == 0) revert WithdrawTooSmall()` and `if (taoOut < minTaoOut) revert SlippageExceeded(taoOut)` · `AlphaVault.sol:226-227` · The payout is measured as the clone's TAO delta, so slippage is bounded against what actually arrived, not a quote.

#### G-10
`if (amount == 0) revert ZeroAmount()` / `if (amount == 0) revert ClaimBelowNativePrecision()` · `AlphaVault.sol:262-264` · A claim pays whole RAO only; sub-RAO residue stays reserved in `taoLiability` for the holder.

#### G-11
`if (retired != bytes32(0) && _holdsRotatedOutStake(backing, actives)) revert AttestedHotkeyRetired(retired)` · `AlphaVault.sol:284` · Consolidation onto an attested entry with no usable receiving hotkey would forward gas to a chain call that refuses; the exit is held unless nothing needs consolidating.

#### G-12
`if (retired != bytes32(0) && shares != supply) revert AttestedHotkeyRetired(retired)` · `AlphaVault.sol:305` · A partial alpha exit must leave the remainder weight-aligned; only a full-supply exit may skip alignment onto an unusable entry.

#### G-13
`if (VaultAllocation.isBelowFloor(assets, alphaPriceE18)) revert WithdrawTooSmall()` · `AlphaVault.sol:310` · The chain refuses a transfer below its TAO-denominated minimum and burns the forwarded gas; refuse it first.

#### G-14
`if (backing == 0) revert NothingToUnwrap()` · `AlphaVault.sol:325` · A dissolved position with no unreserved TAO refund has nothing to redeem; shares must not be burned for nothing.

#### G-15
`if (awaitingAttestation(tokenId)) revert Parked()` · `AlphaVault.sol:340` · Weight alignment onto a stale attestation would move parked backing back onto the hotkey the registry already lost.

#### G-16
`if (_slots[tokenId].length == 0) revert NothingToRecover()` · `AlphaVault.sol:428` · A position that never settled has no record to recover against; strays on such a clone have no owner position.

#### G-17
`if (VaultMath.contains(backing.hotkeys, source)) revert NothingToRecover()` · `AlphaVault.sol:433` · A recorded hotkey is live backing, not a stray; annexing it would double-count.

#### G-18
`if (source == parkingHotkey) revert NothingToRecover()` · `AlphaVault.sol:437` · During recovery the parking hotkey is the destination; collecting from it into itself is a no-op that would still pass the `parked > before` test on emissions.

#### G-19
`if (parked <= before) revert NothingToRecover()` · `AlphaVault.sol:440` · A recovery call must move alpha onto parking; otherwise it emits a false `BackingRecovered`.

#### G-20
`if (!VaultReads.replacementOpen(coldkey)) revert StakingListHasRoom()` · `AlphaVault.sol:456` · A clone is replaced only at half the chain's staking-list cap; earlier replacement would strand sub-floor piles for no liveness gain.

#### G-21
`if (exposed > VaultReads.TRACKED_SLACK_RAO) revert BackingNotSecured()` · `AlphaVault.sol:487` · The recovery clock may start only once every located pile above the floor sits on parking; otherwise the window could expire while recoverable alpha was never secured.

#### G-22
`if (balance <= before) revert NothingToRecover()` · `AlphaVault.sol:521` · Annexing a stray must raise the home slot's balance; a zero-delta call would re-anchor the record for nothing.

#### G-23
`if (!_followedSwap(slots, backing.hotkeys)) revert BackingUnchanged()` · `AlphaVault.sol:551` · `syncBacking` on an intact position may only write a followed swap into the record; any other call is a no-op and should say so.

#### G-24
`if (block.timestamp >= state.shortSince + recoveryWindow)` write-off branch · `AlphaVault.sol:571` · The deficit is written off only after the fixed window; partial returns before expiry collect without resetting the clock.

#### G-25
`if (parked <= before) revert BackingUnchanged()` · `AlphaVault.sol:576` · Inside the window a sync must collect something or revert, so `BackingRecovered` is never emitted for a zero delta.

#### G-26
`if (recovery[tokenId].shortSince != 0) revert ShortfallOnFile()` · `AlphaVault.sol:594` · Every priced operation is shut while a declared shortfall is open, so no deposit or exit is priced against unresolved backing.

#### G-27
`if (VaultReads.lockedAlphaOf(coldkey, netuid) != 0) revert LockedBacking()` · `AlphaVault.sol:595` · Conviction-locked alpha priced as backing would let locked stake be exited by others; the lock blocks the clone as a whole.

#### G-28
`revert BackingShortfall(netuid, slots[shortIndex].active, slots[shortIndex].tracked)` · `VaultReads.sol:182-184` (via `AlphaVault.sol:598`) · An undeclared shortfall freezes pricing until a watcher parks or writes it off; expiry alone never authorizes a deposit or exit to book a loss implicitly.

#### G-29
`if (retired != bytes32(0)) revert AttestedHotkeyRetired(retired)` · `AlphaVault.sol:606` · Deposits and rebalances need every attested entry to have a usable receiving hotkey before any gas is forwarded to the chain.

#### G-30
`if (initialized) revert AlreadyInitialized()` · `CloneBase.sol:21` · One-shot: the first caller becomes `wrapper`; the implementation sets `initialized = true` in its constructor so only fresh clones can be claimed.

#### G-31
`if (msg.sender != wrapper) revert NotWrapper()` · `CloneBase.sol:17` · Every stake move, sale, transfer and TAO payout a clone signs is authorized by the vault alone.

#### G-32
`if (msg.sender != vault) revert NotVault()` · `CloneFactory.sol:23` · Only the vault may mint clone addresses, so no third party can pre-create a contaminated account at a vault-predictable address.

#### G-33
`if (owned || swapped || getOwnedHotkeys(coldkey).length != 0 || lockedAlphaOf != 0 || stakingHotkeyCount != 0) revert CloneContaminated(candidate)` · `CloneFactory.sol:57-60` · A pre-poisoned candidate (coldkey-swap history, locks, roles, list entries) could carry locked alpha into backing; the caller retries with a fresh UID.

#### G-34
`if (!VaultReads.ownedBy(coldkey, owner) || !staking.getRejectLockedAlpha(coldkey)) revert CloneProtectionFailed(clone)` · `VaultClones.sol:44-46` · Confirms the account became a hotkey (unswappable) and refuses locked alpha before its address is published.

#### G-35
`if (hotkeys.length == 0) revert NoValidatorFound(); if (hotkeys.length > MAX_VALIDATORS) revert ValidatorSetTooLarge(); if (hotkeys.length != weights.length) revert ValidatorSetMalformed()` · `VaultReads.sol:53-55` · Bounds the slot record and loop costs to ten entries per position; the vault trusts the registry for everything else about the set.

#### G-36
`if (ownGeneration && dissolving) revert SubnetInDissolutionBlackoutPeriod()` · `VaultReads.sol:79` · Pricing an incomplete dissolution refund would misallocate it between early and late exiters.

#### G-37
`if (!transfersEnabled) revert AlphaTransfersDisabled(netuid)` · `VaultReads.sol:100` · A transfer the chain refuses burns all forwarded gas; alpha exits and wraps stop here while TAO routes stay open.

#### G-38
`if (!StakeOps.hasOwner(hotkey)) revert OwnerlessHotkey(hotkey)` · `BasicValidatorRegistry.sol:33` · A published hotkey must be stakeable at publish time; the vault re-checks at use time because the owner record can vanish later.

---

## 2. Inferred Invariants (Single-Contract)

Inferred invariants are derived from structural analysis of the source code. Each block below cites one of five extraction methods in its `Derivation` field: Δ-pair, guard lift, state-machine edge, temporal predicate, or NatSpec-stated global property. Each block is classified as `Conservation` · `Bound` · `Ratio` · `StateMachine` · `Temporal`.

---

#### I-1

`Conservation` · On-chain: **Yes**

> `taoLiability[t]` ≥ Σ over accounts of (`claimableTao[t][a]` + pending index earnings) — reserved TAO always covers every settled and unsettled claim.

**Derivation** — Δ-pair: `AlphaVault.sol:665` `cumulativeTaoPerShare[tokenId] += indexIncrease; taoLiability[tokenId] += liabilityIncrease` where `liabilityIncrease = mulDiv(indexIncrease, supply, 1e36, Ceil)` (`VaultMath.sol:94`) ↔ `AlphaVault.sol:264` `claimableTao[...] = entitlement - amount; taoLiability[tokenId] = liability - amount`. Ceil rounding on the liability side and the `backedEntitlement` cap at `AlphaVault.sol:261` close the residue gap.

**If violated** — A claim pays from TAO that backs a dissolved-subnet redemption or another holder's claim.

---

#### I-2

`Bound` · On-chain: **Yes**

> `subnetClone[t].balance` ≥ `taoLiability[t]` at the end of every vault call.

**Derivation** — guard-lift: liability grows only by `indexableTao` of the unreserved part of the live balance (`VaultReads.sol:104-108`, `AlphaVault.sol:661-665`); it shrinks together with a payout of the same amount (`AlphaVault.sol:264-267`). Write sites of liability: `:243-244` (temporary `+= taoOut; -= taoOut` around the refund mint, net zero), `:264`, `:665`. Write sites of balance: `CloneBase.unwrapTao` (claim `:267`, dissolved exit `:332`, TAO exit `:251`, all ≤ unreserved or ≤ liability) and `SubnetClone.transferAllTao` (`VaultAllocation.sol:96`, whole balance to the successor the mapping now points at).

**If violated** — `claimTao` reverts on `sendValue` for the last claimants.

---

#### I-3

`Bound` · On-chain: **No**

> `totalSupply(t)` ≤ `SUPPLY_CAP` (1e45) for every token.

**Derivation** — guard-lift: `AlphaVault.sol:156` guards the deposit mint at `:158`. Write sites of supply: `_mint` at `:158` (guarded), refund `_mint` at `:243` (**unguarded**), burns at `:219`, `:296`, `:311`, `:329`. The refund mint uses `sharesFor(total - assets, supply - shares, unsold)` which at `supply - shares == 0` and `total - assets == 0` is `unsold × 1e9` (`VaultMath.sol:21`); the chain's 64-bit stake bound keeps this below the cap in practice, but no code enforces it.

**If violated** — `earnedAt` flooring loss exceeds one RAO per holder and sub-RAO arrivals stop being indexable.

---

#### I-4

`StateMachine` · On-chain: **Yes**

> `recovery[t]` cycles Intact `{0,0}` → Short `{ts,0}` → Parked `{0,nonce}` → Intact `{0,0}`; it never holds both `shortSince != 0` and `parkedAtNonce != 0`.

**Derivation** — edge: `{0,0}`@`AlphaVault.sol:548` (precondition `state.shortSince == 0`) → `{block.timestamp, 0}`@`:501`; `{ts,0}` → `{0, nonce}`@`:510` (`_finishRecovery`, reached from `:559`, `:569`, `:573`); `{0,nonce}` → `{0,0}`@`:627` when the registry nonce moved or supply is zero, and @`:247` when supply is zero. No write sets both fields nonzero.

**If violated** — `awaitingAttestation` and `_openBacking` would disagree about whether the position is priced.

---

#### I-5

`Temporal` · On-chain: **Yes**

> A write-off can only occur at or after `shortSince + recoveryWindow`, and `shortSince` is set once per recovery episode and never refreshed by partial returns.

**Derivation** — temporal: `AlphaVault.sol:571` `block.timestamp >= state.shortSince + recoveryWindow`. `shortSince` write sites: `:501` (only on the `shortSince == 0` branch) and `:510` (reset to zero). The check is read-then-not-updated inside the episode.

**If violated** — Holders could be written down before the fixed window the docs promise, or a watcher could extend the window by partial recoveries.

---

#### I-6

`Bound` · On-chain: **Yes**

> Outside recovery, `_slots[t].length` ≤ `MAX_VALIDATORS` (10); inside recovery it is ≤ 2·`MAX_VALIDATORS` + 1 and collapses to exactly 1 at finish.

**Derivation** — guard-lift: `VaultReads.sol:54` bounds the attested set; `_settle` (`AlphaVault.sol:619-623`) pops to and writes exactly `attestedHotkeys.length` slots; `_startRecovery` (`:492-500`) writes `1 + |hotkeys ≠ parking|` where `hotkeys = concat(resolved, novelSources(resolved, raw))` (`:466-468`) with both arrays ≤ 10; `_finishRecovery` (`:508`) pops to 1; `_reanchor` never changes length.

**If violated** — The `excludedSlots` mask check at `:210` and the gas of every record walk lose their bound.

---

#### I-7

`Ratio` · On-chain: **Yes**

> Deposit shares = ⌊deposit × (supply + 1e9) / (preStake + 1)⌋ and exit assets = ⌊shares × (stake + 1) / (supply + 1e9)⌋; both round against the caller.

**Derivation** — `VaultMath.sol:20-25`; the `preStake` snapshot at `AlphaVault.sol:151-152` is taken **after** all moves settle (`_settle` at `:150`), so emissions landing between the mailbox read and settlement are priced into the pre-deposit stake, not credited to the depositor. `assetsFor` in `_unwrapFromLiveSubnet` (`:306`) uses post-consolidation balances fetched at `:291`.

**If violated** — Round-trip wrap→unwrap could mint value from rounding.

---

#### I-8

`Ratio` · On-chain: **Yes**

> A full-supply TAO exit is priced at exactly the located total (no virtual offset), every other TAO exit at `assetsFor`.

**Derivation** — `AlphaVault.sol:216-217` `assets = shares == supply ? total : VaultMath.assetsFor(total, supply, shares)`. The exception exists so a full-supply sale is a floor-exempt full drain of each slot (`VaultAllocation.sol:105-106`).

**If violated** — The last holder leaves sub-floor dust the chain cannot move, or a partial exit receives alpha arrived at zero supply.

---

#### I-9

`StateMachine` · On-chain: **Yes**

> `_mailboxes[user][netuid]` is a one-shot latch: zero → one address, never rewritten.

**Derivation** — edge: `VaultClones.sol:24-25` `if (mailbox != address(0)) return mailbox;` → `:29` `mailboxes[msg.sender][netuid] = mailbox`. Only write site.

**If violated** — A user's deposit address would change under them and alpha sent to the old one would be unreachable through `_requireMailbox`.

---

#### I-10

`StateMachine` · On-chain: **Yes**

> `subnetClone[t]` moves zero → clone → successor → …, never back to zero; the live clone is always a vault-initialized, protected account.

**Derivation** — edge: `VaultClones.sol:15-18` (`if (clone != address(0)) return` → `subnetClone[tokenId] = clone`) and `AlphaVault.sol:459` `subnetClone[tokenId] = successor` after `VaultClones.deployProtectedClone` (`VaultAllocation.sol:86`). No `delete`.

**If violated** — Shares would reference an account the vault does not control.

---

#### I-11

`Bound` · On-chain: **Yes**

> After every balance change, `taoIndexDebt[t][a]` == `earnedAt(balanceOf(a,t), cumulativeTaoPerShare[t])` for both parties, and every pre-transfer pending amount is in `claimableTao`.

**Derivation** — `AlphaVault.sol:682-701`: `_checkpoint` on both parties before `super._update`, `_settleIndexDebt` on both after. `index != 0` short-circuit means the invariant holds vacuously while no TAO was ever indexed.

**If violated** — A transfer would let the receiver claim TAO earned before they held shares, or the sender would lose accrued TAO.

---

#### I-12

`Bound` · On-chain: **Yes**

> While `shortSince != 0`, `_slots[t][0]` is the parking slot carrying the entire pooled `tracked` obligation and every other slot has `tracked == 0`.

**Derivation** — `AlphaVault.sol:492-497` writes slot 0 as `(parking, parking, expected)` and all others with `tracked = 0`; `_reanchor` is unreachable during recovery because `_openBacking` reverts `ShortfallOnFile` (`:594`) and `syncBacking` only re-anchors on the `shortSince == 0` branch (`:551`).

**If violated** — `_totalTracked` at `:566` would compare located parking against a double-counted expectation.

---

#### I-13

`Bound` · On-chain: **Yes**

> Every recovery-window write (`_startRecovery`) is preceded by a successful `_secureBacking`, so located backing above the floor sits on parking before the clock starts.

**Derivation** — guard-lift of `AlphaVault.sol:487` (`BackingNotSecured`): the only call to `_startRecovery` (`:561`) is after `_secureBacking` at `:557`, which returns early (without the exposed check) only when a pile is below the floor.

**If violated** — A watcher could start the write-off clock while recoverable alpha was still exposed on a swapped hotkey.

---

#### I-14

`Conservation` · On-chain: **No**

> The amount of alpha the vault moves between its own hotkeys in consolidation, gather and rebalance leaves the position's total unchanged; only chain rounding may lower it.

**Derivation** — Negative conservation: `consolidateRotatedStake`, `_rollRotatedStake`, `_gatherAndFlush` and `_rebalanceStep` write **no** vault storage; the record is rebuilt from chain reads at `_settle` (`AlphaVault.sol:621-623`) and `_reanchor`. There is no on-chain check that `Σ tracked` after settle ≥ `Σ tracked` before minus payout.

**If violated** — A silent loss on an internal hop (chain rounding, a forced dust sale on `moveStake`) is written into the record as the new truth without an event.

---

#### I-15

`Bound` · On-chain: **No**

> No two slots of one token ever resolve to the same backing hotkey.

**Derivation** — guard-lift of `SwappedHotkeyStillAttested` at `VaultAllocation.sol:175`, `:230`, `:243` (assignment time) and the shared-successor rejection at `VaultReads.sol:158` (resolution time). Write sites of `active`: `_settle` (`:623`, from `actives` — guarded), `_reanchor` (`:647`, from resolved `backing.hotkeys` — guarded by `:158`), `_startRecovery` (`:496`, from `_collectionHotkeys` which dedups via `novelSources` — but `resolved` itself may contain duplicates only if `:158` failed). A registry that publishes the same hotkey twice (not checked in `VaultReads.resolveValidators:51-57`) produces two slots on one balance.

**If violated** — One balance backs two slots and an exit is paid twice from the same alpha (docs: "a hotkey counted twice can overpay an exit").

---

#### I-16

`Bound` · On-chain: **Yes**

> `recovery[t]` is `{0,0}` whenever `totalSupply(t) == 0` after a live-path burn.

**Derivation** — guard-lift: `AlphaVault.sol:247` (TAO exit), `:627` (every `_settle`), `:509` (`nonce = 0` when supply is zero, so `parkedAtNonce = 0`). The dissolved-subnet burn at `:329` does not touch `recovery`, but `isDissolved` positions never enter `_openBacking`, so the field is inert there.

**If violated** — A fresh first depositor after a full exit would inherit a `Parked` revert from a previous generation of holders.

---

#### I-17

`Bound` · On-chain: **Yes**

> A deposit lands only on a hotkey the clone already lists, or on the chosen target with the growth flag lifted for exactly that call.

**Derivation** — `VaultAllocation.sol:63-76`: if `target` has stake it lands there; else the first listed hotkey (`listed[0]`); else `setRejectStakingHotkeyGrowth(false)` → transfer → `setRejectStakingHotkeyGrowth(true)`. The flag flip is bracketed in one call with no external callback between (`:68`, `:76`).

**If violated** — A stranger could land alpha onto the clone's list during the lifted window and fill the list that admits deposits.

---

#### I-18

`Bound` · On-chain: **Yes**

> The parking hotkey always has a reserved place on every clone's staking list.

**Derivation** — `VaultReads.sol:39-42` `admitsMove`: a move onto a hotkey the clone does not yet list is admitted only while `count + 2 <= MAX_STAKING_HOTKEYS`, so one entry stays free; a move onto `parking` is always admitted. Every move goes through `StakeOps.move` (`:31-35`) except `moveAdmitted` callers that already proved admission (`VaultAllocation.sol:293-294`, `:335`).

**If violated** — Recovery could not park a position whose clone list a stranger filled, so the write-off clock could never start.

---

#### I-19

`Temporal` · On-chain: **Yes**

> A parked position stays parked until `validatorRegistry.nonces(netuid)` differs from `parkedAtNonce`.

**Derivation** — temporal predicate on storage: `AlphaVault.sol:112-113` `parkedAtNonce != 0 && nonces(netuid) == parkedAtNonce`; clearing write site `:627` is conditioned on `!awaitingAttestation`.

**If violated** — Deposits would re-stake onto the hotkey the registry lost before the owner made a fresh decision.

---

#### I-20

`Bound` · On-chain: **Yes**

> `claimTao` pays only whole RAO (multiples of 1e9 wei) and never more than `taoLiability[t]`.

**Derivation** — guard-lift of `AlphaVault.sol:261-264` (`backedEntitlement`, `toNativeQuantum`); the only payout write site for claims is `:267`. Dissolved exits apply the same quantum at `:327`.

**If violated** — Native transfers truncate sub-RAO wei, so the vault would record a payout the chain did not make.

---

**Categories:**
- **Conservation**: Two or more storage variables change by equal-and-opposite amounts in the same function body.
- **Bound**: A guard on a storage variable, lifted to a global property and checked across every write site.
- **Ratio**: A storage value or payout is defined as a formula of other values; snapshot ordering noted.
- **StateMachine**: A storage variable transitions through discrete values with no reverse path, or a documented cycle.
- **Temporal**: A condition depends on `block.timestamp` or an external monotonic counter held in storage.

---

## 3. Inferred Invariants (Cross-Contract)

Trust assumptions that span contract boundaries. Each block cites both caller-side and callee-side code.

---

#### X-1

On-chain: **No**

> The validator set the registry returns contains no duplicate hotkeys.

**Caller side** — `VaultReads.sol:51-57` checks length, cap and shape only; `VaultAllocation.sol:164-181` assigns one active per attested entry assuming distinctness; `_alignToWeights` (`VaultAllocation.sol:247-270`) targets per index.

**Callee side** — `BasicValidatorRegistry.sol:41-47` returns a single entry, so distinctness holds for this registry; any other `IValidatorRegistry` implementation is unchecked.

**If violated** — Two slots on one hotkey: double-counted backing (see I-15) and a rebalance that moves alpha between a hotkey and itself.

---

#### X-2

On-chain: **No**

> Registry weights sum to `BPS_BASE` (10 000).

**Caller side** — `VaultAllocation.sol:255-260` computes `targets[i] = total × w_i / 10000` for all but the last slot and assigns `total - assigned` to the last; `assigned > total` reverts on underflow, `assigned < total` silently gives the last slot the remainder.

**Callee side** — `BasicValidatorRegistry.sol:47` `weights[0] = VaultMath.BPS_BASE`. No check in `resolveValidators`.

**If violated** — A registry publishing weights summing above 10 000 blocks every wrap, rebalance and partial alpha exit until re-published; below 10 000 over-allocates the last entry.

---

#### X-3

On-chain: **Yes**

> `nonces(netuid)` strictly increases on every published set and never decreases.

**Caller side** — `AlphaVault.sol:113` compares equality to `parkedAtNonce`; `:510` snapshots it at parking.

**Callee side** — `BasicValidatorRegistry.sol:35` `++nonces[netuid]` is the only write; no decrement, no reset.

**If violated** — A parked position could be released by a nonce that wraps or is reset without a fresh owner decision.

---

#### X-4

On-chain: **Yes**

> A clone's `wrapper` is the vault, set in the same transaction that deploys it.

**Caller side** — `VaultClones.sol:26-28` and `:35-38`: deploy via factory then `CloneBase(clone).initialize()` inside the vault's delegatecalled library, so `msg.sender` at `CloneBase.sol:22` is the vault.

**Callee side** — `CloneBase.sol:15` implementation latches `initialized = true`; `:21` refuses a second `initialize`. `CloneFactory.sol:23` `onlyVault` means no one else can produce the clone address first.

**If violated** — A third party would own every stake operation of a position.

---

#### X-5

On-chain: **Yes**

> `CloneFactory.vault` is the `AlphaVault` instance that uses it.

**Caller side** — `AlphaVault.sol:79` `cloneFactory = new CloneFactory(...)` in the constructor.

**Callee side** — `CloneFactory.sol:20` `vault = msg.sender`, immutable.

**If violated** — Another contract could mint protected clone addresses whose `_requireClean` outcome the vault trusts.

---

#### X-6

On-chain: **Yes**

> A hotkey the registry publishes has an owner record at publish time, but the vault re-derives usability at every use.

**Caller side** — `VaultAllocation.sol:172-179` computes `usable` from `StakeOps.hasOwner` and successor edges at call time and reports the first unusable entry as `retired`; `AlphaVault.sol:284`, `:305`, `:606` act on it.

**Callee side** — `BasicValidatorRegistry.sol:33` `if (!StakeOps.hasOwner(hotkey)) revert OwnerlessHotkey(hotkey)` at publish only; nothing re-checks on the registry side when an all-subnet swap later removes the record.

**If violated** — Not applicable: the caller does not rely on the callee check; the invariant records that the two checks are independent.

---

#### X-7

On-chain: **Yes**

> A clone's TAO balance can be drained only by the vault, and only to a share holder, a claimant, or the token's successor clone.

**Caller side** — `AlphaVault.sol:251`, `:267`, `:332` (`unwrapTao` to `msg.sender`/`recipient`), `VaultAllocation.sol:96` (`transferAllTao` to the successor coldkey the vault just deployed).

**Callee side** — `CloneBase.sol:35-37` and `SubnetClone.sol:17-19` are `onlyWrapper`; `SubnetClone` has no `receive` restriction, so TAO may arrive from anyone but leave only through these two.

**If violated** — TAO refunds and claims would be stealable from the clone.

---

## 4. Economic Invariants

Higher-order properties derived from combinations of §2 and §3 invariants.

---

#### E-1

On-chain: **Yes**

> Absent chain-side loss, wrap→unwrap round trips never create alpha: a holder gets back at most what they deposited plus their pro-rata share of emissions.

**Follows from** — `I-7` (both ratios round against the caller) + `I-3` (virtual offsets bound first-depositor inflation while the cap holds).

**If violated** — Share inflation at the expense of other holders.

---

#### E-2

On-chain: **Yes**

> Total claimable TAO across all holders never exceeds the TAO the clone actually holds.

**Follows from** — `I-1` + `I-2` + `I-20` + `X-7`.

**If violated** — Last claimants cannot be paid.

---

#### E-3

On-chain: **Yes**

> Loss from a hotkey swap the watcher cannot repair falls on the holders of record at write-off time; alpha recovered later belongs to the holders of record at recovery time.

**Follows from** — `I-4` + `I-5` + `I-12` + `I-19` (recovery collapses the record to parking, deposits reopen only after a newer attestation, and `recoverStray` with no shortfall on file annexes into live backing at `AlphaVault.sol:430-435`).

**If violated** — Either early exiters escape a loss that later arrives, or late depositors capture a recovery they did not fund. The docs name the second as the accepted late-recovery attack when watchers miss the window.

---

#### E-4

On-chain: **No**

> Every slot's backing is counted exactly once in `totalStake`, so share price reflects real alpha.

**Follows from** — `I-15` + `X-1`. Both are On-chain=No for a non-`BasicValidatorRegistry` registry, so this property depends on registry governance publishing distinct hotkeys.

**If violated** — Exits are overpaid from other holders' alpha.

---

#### E-5

On-chain: **Yes**

> A deposit cannot be priced against, and cannot be paid out of, backing the vault has not located.

**Follows from** — `G-26` + `G-28` (lifted: every entry to `_openBacking`) + `I-13`.

**If violated** — Depositors buy into a position whose recorded backing is missing, or exits drain the remaining located alpha ahead of a write-down.

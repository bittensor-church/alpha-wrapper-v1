# X-Ray Report

> alpha-wrapper | 1552 nSLOC | b986e47 (`master`) | Foundry | 02/11/26

---

## 1. Protocol Overview

**What it does:** Wraps alpha staked on a Bittensor subnet into transferable ERC-1155 shares, keeping the alpha staked under vault-controlled Substrate accounts and redeemable for staked alpha or native TAO.

- **Users**: Depositors who stake alpha through a per-user mailbox and receive shares; holders who redeem, sell for TAO or claim stray TAO; permissionless watchers who run rebalance, swap recovery and clone replacement.
- **Core flow**: `createMailbox` → send alpha to the mailbox coldkey → `wrap` moves it onto the attested validator hotkey inside a per-subnet clone and mints shares priced on located backing.
- **Key mechanism**: Share price = located chain stake under the clone coldkey (read live from the staking precompile) with virtual offsets; a per-token slot record (`logical`, `active`, `tracked`) follows at most one hotkey swap per slot and freezes pricing on any shortfall.
- **Token model**: One ERC-1155 id per subnet registration `(registrations << 16) | netuid`; alpha is backing, native TAO reaching a clone is tracked separately through a per-share claim index.
- **Admin model**: `AlphaVault` has no admin, no pause and no upgrade path; the pluggable `IValidatorRegistry` chooses validators. The reference `BasicValidatorRegistry` has one `Ownable2Step` owner who publishes one hotkey per subnet instantly.

For a visual overview of the protocol's architecture, see the [architecture diagram](architecture.svg).

### Contracts in Scope

| Subsystem | Key Contracts | nSLOC | Role |
|-----------|--------------|------:|------|
| Vault | AlphaVault, VaultErrors | 563 | Shares, deposits, exits, TAO index, swap recovery state machine |
| Allocation libraries | VaultAllocation, VaultReads, StakeOps, VaultMath, VaultClones | 617 | Hotkey assignment, consolidation, weight alignment, sales, chain reads, share math |
| Clones | SubnetClone, DepositMailbox, CloneBase, CloneOwner, CloneFactory | 112 | Vault-controlled Substrate accounts that sign stake operations; CREATE2 deployment with contamination checks |
| Registry | BasicValidatorRegistry | 30 | Reference validator set: one hotkey at 100% per subnet |
| Lens | AlphaVaultLens | 140 | Read-only quotes and backing status |

Interfaces (`src/interfaces/`, 93 nSLOC) describe Subtensor precompiles and the registry; excluded from scope totals above.

### How It Fits Together

The core trick: the vault never holds alpha itself — each subnet registration gets a `SubnetClone` whose Substrate coldkey holds the stake, and the vault re-derives backing from live `getStake` reads against a stored slot record rather than from internal accounting, so chain emissions, swaps and sweeps show up as price changes or as frozen "shortfall" states.

### Deposit

```
Depositor → AlphaVault.wrap(netuid, chosenHotkey, minSharesOut)
  ├─ VaultReads.resolveValidators(registry)            — attested set (≤10 hotkeys + bps weights)
  ├─ _openBacking()                                      — revert on ShortfallOnFile / LockedBacking / BackingShortfall
  │   └─ VaultReads.resolveBacking(slots)                — getStake per slot; follow one swap hop if it covers `tracked`
  ├─ VaultAllocation.assignActives()                     — receiving hotkey per attested entry; collision → revert
  ├─ VaultAllocation.admitDeposit(mailboxColdkey)        — floor check at spot price, lock check
  ├─ VaultAllocation.collectDeposit()                    — *mailbox.transferStakeAndHotkey → clone coldkey*; may lift
  │                                                        the clone's reject-growth flag for this one call
  ├─ VaultAllocation.consolidateRotatedStake()           — roll dropped-hotkey piles onto the richest slot
  ├─ VaultAllocation.rebalance()                         — SubnetClone.moveStake toward bps targets (skips sub-floor)
  ├─ _settle()                                           — *record rewritten from getStake; recovery cleared if released*
  └─ _mint(sharesFor(preStake, supply, deposit))         — *preStake = settled total − deposit*; SUPPLY_CAP check
```

### Alpha exit

```
Holder → AlphaVault.unwrap(tokenId, shares, coldkey, minAlphaOut)
  ├─ VaultReads.isDissolved(tokenId)                     — blackout revert while dissolving
  ├─ [dissolved] _unwrapFromDissolvedSubnet              — pro-rata of clone TAO minus taoLiability → SubnetClone.unwrapTao
  └─ [live] _unwrapFromLiveSubnet
      ├─ _openBacking(); assignActives() unless parked   — parked positions pay from parkingHotkey only
      ├─ consolidateRotatedStake()                       — RevertBelowFloor policy
      ├─ assets = assetsFor(Σ balances, supply, shares)  — floor check → WithdrawTooSmall
      ├─ _burn(shares)                                   — *before any stake move*
      ├─ VaultAllocation.deliverAndAlign()               — gather onto the largest slot → SubnetClone.flush → user coldkey;
      │                                                    alphaOut measured as recipient getStake delta; then re-align
      └─ _settle()
```

### TAO exit

```
Holder → AlphaVault.unwrapForTao(tokenId, shares, minTaoOut[, excludedSlots])
  ├─ _openBacking(); assets = shares == supply ? total : assetsFor(...)
  ├─ _burn(shares)
  ├─ VaultAllocation.sellForTao()                        — round 1: full-slot drains (floor-exempt); round 2: partial chunks
  │   └─ _sellableChunk()                                — simSwapAlphaForTao quotes; leftover must clear nominator min
  ├─ sold = total − Σ postBalances                       — *checked subtraction rejects a sale that swept others' alpha*
  ├─ _reanchor(); refundShares for unsold alpha          — *taoLiability += taoOut around _mint so the refund's TAO sync
  │                                                        does not index the sale proceeds*
  └─ SubnetClone.unwrapTao(msg.sender, taoOut)           — *after* all state writes
```

### Swap recovery

```
Watcher → AlphaVault.syncBacking(tokenId)
  ├─ [no shortfall on file] resolveBacking → intact? write followed swap (_reanchor) : _secureBacking
  │   └─ _secureBacking: _gather(all located hotkeys → parkingHotkey, LeaveBelowFloor); exposed ≤ 1000 RAO or revert
  │       ├─ covers tracked → _finishRecovery (slots → [parking]; parkedAtNonce = registry nonce)
  │       └─ else → _startRecovery (slots → [parking:expected, others:0]; shortSince = now)
  └─ [shortfall on file] _secureBacking again → covers ? cleared : (window expired ? write-off : partial collect)
Watcher → recoverStray(tokenId, source)                 — annex into live backing (no shortfall) or collect onto parking
Registry owner → setValidator(netuid, hotkey)            — nonce bump releases the parked position on the next wrap/rebalance/unwrap
```

---

## 2. Threat & Trust Model

### Protocol Threat Profile

> Protocol classified as: **Liquid Staking** with **Yield Aggregator / Vault** characteristics

Stake-and-mint-derivative, an external validator set, an exchange rate derived from live staked balances and a slashing-like loss path (hotkey swaps, nominator sweeps, write-offs) are liquid-staking signals; share-based accounting with virtual offsets, `totalAssets`-style live balance reads and donation sensitivity are vault signals. There is no lending, AMM or governance logic in scope; the pool interaction is a one-directional market sale through the alpha precompile.

### Actors & Adversary Model

| Actor | Trust Level | Capabilities |
|-------|-------------|-------------|
| Registry owner (`BasicValidatorRegistry`) | Bounded (can only choose the validator hotkey) | `setValidator` is instant with no timelock; redirects 100% of every position's stake on that subnet at the next wrap/rebalance/exit, and its nonce bump releases parked positions. `Ownable2Step` protects the seat only; renounce disabled. |
| Depositor / holder | Bounded (own mailbox, own shares) | `wrap`, `unwrap`, `unwrapForTao`, `claimTao`, mailbox reclaims. Chooses `chosenHotkey` within the set and the `excludedSlots` mask. |
| Watcher / keeper | Bounded (permissionless, no funds authority) | `rebalance`, `syncBacking`, `recoverStray`, `replaceClone`. Timing of these calls decides when a shortfall is declared, when it is written off, and which piles stay behind on clone replacement. |
| Validator (attested hotkey holder) | Bounded (controls the hotkey, not the coldkey) | Can swap the hotkey (per-subnet or all-subnet), re-register the old one to erase a successor edge, reserve ownerless hotkeys as coldkey-swap destinations, and steer emissions. Cannot move the clone's stake directly. |
| Subnet owner | Bounded (chain-level switches) | Can disable alpha transfers (blocks wraps and alpha exits; TAO routes remain) and trigger dissolution. |
| Subtensor runtime / root | Trusted | Minimums, sweeps, dissolution refunds, precompile semantics. Source of truth for every balance read. |

**Adversary Ranking** (ordered by threat level for this protocol type, adjusted by git evidence):

1. **Validator operator** — controls the attested hotkey the vault's record follows; swaps, re-registrations and reservations are the mechanism behind every recovery path and 8 of the 10 fix-scored commits.
2. **Compromised registry owner** — one key instantly redirects all stake on a subnet; the vault has no override and no delay.
3. **Pool-price manipulator** — spot `getAlphaPrice` gates every floor test and `simSwapAlphaForTao` sizes partial sales; a mover of the pool can flip floor outcomes for other users within a block.
4. **Griefing watcher / third-party staker** — anyone can time `syncBacking`, `replaceClone` and `rebalance`, and anyone can land alpha or TAO on a clone or reserve a hotkey the vault needs.
5. **Share-inflation / donation attacker** — virtual offsets exist, but backing is a live balance read that third-party alpha can raise.

See [entry-points.md](entry-points.md) for the full permissionless entry point map.

### Trust Boundaries

- **Registry → vault** — `VaultReads.resolveValidators:51-57` checks only length, cap and shape; distinct hotkeys and weights summing to 10 000 are trusted (docs state this). No timelock anywhere; the worst instant action is `setValidator` onto a hostile hotkey, executed by the next permissionless `rebalance`. *Git signal: 9 commits touch registry/attestation code, 4 fix-scored.*

- **Vault → clones** — `CloneBase.onlyWrapper:17` and `CloneFactory.onlyVault:23`; `wrapper` is set by the first `initialize` call, which the vault makes in the deployment transaction (`VaultClones.sol:26-28`, `:35-38`). The clone is the only signer of stake moves, sales, transfers and TAO payouts.

- **Vault → Subtensor precompiles** — every balance, owner record, successor edge, lock and price is a live read with no staleness or sanity bound; the vault's defence is to pre-check conditions so a refused precompile call does not burn forwarded gas. The runtime is pinned only by the e2e localnet image (`docs/deployment.md`, runtime compatibility table).

- **Chain → vault (unsolicited state)** — anyone can send TAO or alpha to a clone or mailbox, claim an ownerless hotkey, or reserve it as a coldkey-swap destination; `CloneFactory._requireClean:52-60` filters this at creation, `_openBacking:593-598` and `collectDeposit:63-70` filter it afterwards.

### Key Attack Surfaces

- **Receiving-hotkey resolution after swaps** &nbsp;&#91;[I-15](invariants.md#i-15), [X-1](invariants.md#x-1), [X-6](invariants.md#x-6)&#93; — `VaultAllocation.assignActives:164-181` and `_receivingHotkey:226-245` pick a live hotkey per attested entry from the record, the attested name and a one-hop successor, with exclusivity enforced by three `SwappedHotkeyStillAttested` reverts; `VaultReads._followSwap:154-162` resolves independently with a shared-successor rule. Worth tracing the two resolvers against each other for an ordering of swap, re-registration and attestation reuse where they disagree about which balance a slot owns.

- **Recovery clock and write-off** &nbsp;&#91;[I-4](invariants.md#i-4), [I-5](invariants.md#i-5), [I-12](invariants.md#i-12), [I-13](invariants.md#i-13), [E-3](invariants.md#e-3)&#93; — `syncBacking:539-579` starts, collects into and finalizes one fixed window; `_secureBacking:473-488` may return early with piles left below the floor; `_finishRecovery:506-513` collapses the record. Worth checking the `LeaveBelowFloor` early return against the `exposed` check it skips, and what `_totalTracked` compares against after `_startRecovery` has zeroed every non-parking slot.

- **TAO exit refund and liability juggling** &nbsp;&#91;[I-3](invariants.md#i-3), [I-8](invariants.md#i-8), [I-1](invariants.md#i-1)&#93; — `_unwrapForTao:201-252` burns, sells, re-anchors, then mints refund shares at `sharesFor(total − assets, supply − shares, unsold)` while temporarily adding `taoOut` to `taoLiability`. Worth confirming the refund rate at `supply − shares == 0`, the full-exit sub-floor discard, and whether an `excludedSlots` mask can shape `unsold` to the caller's advantage.

- **Consolidation roller and gather hops** &nbsp;&#91;[I-14](invariants.md#i-14), [I-18](invariants.md#i-18)&#93; — `consolidateRotatedStake:302-316` / `_rollRotatedStake:319-336` move one growing pile through every rotated-out source, and `_gatherAndFlush:366-394` hops the delivery pile across slots; both re-read the chain each hop and rely on `isBelowFloorAtAnyPrice`. Worth tracing chain-side rounding and the lower same-subnet move minimum against the record rewritten at `_settle`, and the `home` vs `richestHotkey` choice in `chooseRichestSlot:184-212`.

- **Deposit landing path** &nbsp;&#91;[I-17](invariants.md#i-17)&#93; — `collectDeposit:57-80` lands on `listed[0]` when the target has no stake and otherwise lifts the clone's reject-growth flag for one transfer; `landed` is measured as a balance delta on the landing hotkey. Worth checking what `listed[0]` can be (a stranger's gift on a still-listed hotkey, the parking hotkey) and whether third-party alpha arriving on it in the same block inflates `landed`.

- **Spot price as the floor oracle** — `StakeOps.isBelowFloorAtReadPrice/AtAnyPrice:55-63` and `_sellableChunk:134-156` read `getAlphaPrice` and `simSwapAlphaForTao` with no bound; `WithdrawTooSmall`, `GatherBelowFloor`, `ConsolidationBelowFloor` and skipped rebalance steps all flip on it. Worth checking which other-user operations a single-block price move can force to revert or to leave piles behind (`replaceClone:84-97` drops sub-floor slots from the record).

- **Registry owner operational power** — `BasicValidatorRegistry.setValidator:30-37` is instant and unbounded; the vault re-stakes everything on the next permissionless `rebalance`. Not pausable, no delay, no second signer in the reference implementation. The attack surface is the owner key.

- **Permissionless maintenance timing** &nbsp;&#91;[G-20](invariants.md#g-20), [G-24](invariants.md#g-24)&#93; — `replaceClone:447-463` (anyone, leaves sub-floor piles behind), `syncBacking` write-off at expiry (anyone), `rebalance` (anyone, moves at a price of the caller's choosing). Worth checking whether a caller can profit from or impose loss through the moment they call.

- **Share math at empty and near-empty states** &nbsp;&#91;[I-7](invariants.md#i-7), [E-1](invariants.md#e-1)&#93; — `VaultMath.sharesFor/assetsFor:20-25` with `VIRTUAL_SHARES = 1e9`, `VIRTUAL_ASSETS = 1`; `wrap:151-152` derives `preStake` after moves; `_unwrapFromLiveSubnet:294-300` burns worthless shares at zero alpha. Worth confirming the first deposit after a full write-off, and third-party alpha on a tracked hotkey as a donation vector.

- **TAO claim index across transfers** &nbsp;&#91;[I-1](invariants.md#i-1), [I-11](invariants.md#i-11), [E-2](invariants.md#e-2)&#93; — `_update:682-702` syncs and checkpoints both parties around `super._update`; `_syncTao:659-667` at zero supply leaves TAO unassigned; `indexableTao` returns zero once dissolving. Worth tracing batch transfers with repeated ids and the dissolution boundary where arrivals switch from index to refund pot.

- **Clone and mailbox creation cleanliness** &nbsp;&#91;[G-33](invariants.md#g-33), [G-34](invariants.md#g-34), [X-4](invariants.md#x-4)&#93; — CREATE2 addresses are predictable from `(user, netuid, uid)` / `(tokenId, uid)`; `_requireClean:52-60` rejects pre-poisoned candidates and `_initializeClone:41-47` verifies the hotkey claim. Worth checking the `tryAssociateHotkey` reservation rule (anyone can reserve an ownerless account as a coldkey-swap destination) against the parking hotkey and against `ensureHotkeyHasOwner` in `StakeOps:27-29`.

- **Dissolution boundary** &nbsp;&#91;[G-36](invariants.md#g-36), [I-2](invariants.md#i-2)&#93; — `VaultReads.isDissolved:77-81` reverts during the blackout and returns true once the generation counter moves or registration clears; `_unwrapFromDissolvedSubnet:322-333` pays pro rata of unreserved TAO. Worth tracing what `recovery`, `_slots` and the claim index look like for a token that dissolves mid-recovery.

### Protocol-Type Concerns

**As a Liquid Staking protocol:**
- Exchange rate is a live `getStake` sum with no smoothing: `VaultReads.resolveBacking:131-150` — a chain-side event (sweep, forced sale on `moveStake`) between two reads changes price with no event from the vault.
- `TRACKED_SLACK_RAO = 1000` (`VaultReads.sol:128`) is the only tolerance between "intact" and "shortfall"; `coversTracked:187-189` applies it per slot and in `_secureBacking:487` to the sum.
- Validator set is capped at 10 (`IValidatorRegistry.sol:4`) and weights are `uint16` bps; `_alignToWeights:253-260` rounds each target down and gives the last entry the remainder.

**As a Vault:**
- `SUPPLY_CAP = 1e45` (`AlphaVault.sol:65`) ties share supply to TAO index precision; `earnedAt` floors at `1e36` and `syncAmounts` rounds liability up (`VaultMath.sol:85-95`).
- Full-supply TAO exits skip virtual offsets (`AlphaVault.sol:216`) while alpha exits never do — the two exit routes price the last share differently by design.
- Refund-share minting inside an exit (`AlphaVault.sol:239-245`) is the only mint path not covered by `SUPPLY_CAP`.

### Temporal Risk Profile

**Deployment & Initialization:**
- `AlphaVault` constructor claims `_parkingHotkey` and reverts `ParkingHotkeyUnavailable` if another coldkey owns it (`:74-77`); a front-runner who reserves the published parking hotkey as a coldkey-swap destination forces a redeploy with a new one — mitigated by choosing an unpublished random key.
- `BasicValidatorRegistry` must have a validator published before the first `wrap`, else `NoValidatorFound` (`VaultReads.sol:53`); `script/DeployAlpha.s.sol` is out of scope here but sets the ordering.
- First deposit on a fresh token: `sharesFor(0, 0, deposit) = deposit × 1e9` (`VaultMath.sol:21`) — virtual offsets, no minimum first deposit beyond the chain floor.

**Market Stress:**
- A pool price collapse pushes small holders below `minStakeTao` at `isBelowFloorAtReadPrice`, so `unwrap` reverts `WithdrawTooSmall` while `unwrapForTao` may still drain (full) or refuse (partial via `_sellableChunk`); documented as accepted.
- Alpha-transfer disable by the subnet owner blocks `wrap`, `unwrap`, `reclaimAlphaFromMailbox` and `replaceClone` (`requireTransfersEnabled`) — TAO routes and claims remain.

**Deprecation:**
- No V2 or migration code. A token whose subnet dissolves becomes a permanent TAO-redemption pot (`_unwrapFromDissolvedSubnet`); no sunset mechanism for abandoned clones or parked positions whose registry owner is gone.

### Composability & Dependency Risks

**Dependency Risk Map:**

> **Subtensor Staking precompile (0x805)** — via `VaultReads`, `StakeOps`, `VaultAllocation`, all clones
> - Assumes: `getStake` is exact and current; `getHotkeyOwner`/`getHotkeySuccessor` reflect swap history (edges can be erased by re-registration or dissolution); `getDefaultMinStake` ≥ the same-subnet move/transfer minimum; `removeStake` lowers stake by at most the request; `transferStake`/`moveStake` admission rules match `admitsMove` (`VaultReads.sol:39-42`); `setRejectStakingHotkeyGrowth` semantics as documented.
> - Validates: pre-checks before every write (floors, locks, owner records, list room); post-move balance re-reads at `_settle`/`_reanchor`; `sold` underflow check.
> - Mutability: Runtime-upgradeable by Subtensor governance; the vault is immutable and cannot follow.
> - On failure: a refused call burns all forwarded gas (documented); a semantic change (e.g. minimums, list cap of 256 at `IStaking.sol:56`) silently changes which operations succeed.

> **Alpha precompile (0x808)** — via `admitDeposit`, `_sellableChunk`, every `Context.alphaPriceE18`
> - Assumes: `getAlphaPrice` is spot TAO/alpha ×1e18, rounded down by at most `ALPHA_PRICE_QUANTUM_E18 = 1e9`; `simSwapAlphaForTao` is the post-fee output for a `uint64` amount.
> - Validates: NONE on magnitude; zero price defers floor checks to the chain.
> - Mutability: Governed by Subtensor; price is pool state movable by anyone within a block.
> - On failure: floor decisions flip; partial TAO sales refuse.

> **Subnet precompile (0x803)** — via `currentTokenId`, `VaultReads._subnetState`, `requireTransfersEnabled`
> - Assumes: registration counter steps per registration and survives dissolution; `getSubnetCapacityConfig` tenth field is the transfer switch (positional decode at `VaultReads.sol:99`).
> - Validates: NONE.
> - Mutability: A runtime upgrade that reorders the config tuple silently misreads the switch.
> - On failure: wrong token id, wrong dissolution state, or wrong transfer gate.

> **Neuron (0x804), Address mapping (0x80C), Balance transfer (0x800)** — via constructor, `CloneOwner`, `DepositMailbox`, `StakeOps.ensureHotkeyHasOwner`, `SubnetClone.transferAllTao`
> - Assumes: `tryAssociateHotkey` is a no-op when owned and refused for a reserved destination; `addressMapping` is deterministic; `transferAll(keepAlive=false)` moves the full balance including existential deposit.
> - Validates: owner read-back after the parking claim (`AlphaVault.sol:76`) and after clone init (`VaultClones.sol:44`).
> - Mutability: Governed by Subtensor.
> - On failure: `ParkingHotkeyUnavailable` / `CloneProtectionFailed` at creation; a silent partial `transferAll` would strand TAO on an old clone.

> **IValidatorRegistry (pluggable)** — via `VaultReads.resolveValidators`, `AlphaVault.awaitingAttestation`
> - Assumes: distinct hotkeys, weights summing to 10 000, monotonic nonce, at most 10 entries.
> - Validates: length 1..10 and equal-length arrays only (`VaultReads.sol:53-55`).
> - Mutability: Any contract an integrator deploys; `BasicValidatorRegistry` is owner-controlled and instant.
> - On failure: duplicate hotkeys double-count backing (I-15/X-1); over-weighted sets revert every priced path (X-2).

> **OpenZeppelin 5.x** — `ERC1155Supply`, `ReentrancyGuard`, `Clones`, `Create2`, `Ownable2Step`, `Math.mulDiv`, `SafeCast`, `Address.sendValue`
> - Assumes: standard semantics; `_update` override order (`AlphaVault.sol:681`) runs the vault's hooks around supply tracking.
> - Validates: n/a (submodule, unmodified).
> - Mutability: Immutable.
> - On failure: n/a.

**Token Assumptions** *(unvalidated only)*:
- Native TAO as EVM value: assumes 1e9 wei = 1 RAO and that `sendValue` to an arbitrary `recipient` may re-enter only through non-`nonReentrant` views — every payout is the last external call in its function.
- ERC-1155 receivers: `_mint` to `msg.sender` in `wrap` and in the refund path fires `onERC1155Received` after all state writes; a contract depositor can re-enter only into view functions and the lens.

**Shared State Exposure**:
- The clone's staking list (cap 256, replacement at 128) is shared with anyone who can land alpha on a hotkey the clone already lists; `admitsMove` reserves one entry for parking.
- The subnet's alpha pool is shared with every trader; the vault's TAO exits move the price other holders are quoted at (`docs/security-model.md`: "a TAO exit's price impact falls partly on remaining holders").

---

## 3. Invariants

> ### 📋 Full invariant map: **[invariants.md](invariants.md)**
>
> A dedicated reference file contains the complete invariant analysis — do not look here for the catalog.
>
> - **38 Enforced Guards** (`G-1` … `G-38`) — per-call preconditions with `Check` / `Location` / `Purpose`
> - **20 Single-Contract Invariants** (`I-1` … `I-20`) — Conservation, Bound, Ratio, StateMachine, Temporal
> - **7 Cross-Contract Invariants** (`X-1` … `X-7`) — caller/callee pairs that cross scope boundaries
> - **5 Economic Invariants** (`E-1` … `E-5`) — higher-order properties deriving from `I-N` + `X-N`
>
> Every inferred block cites a concrete Δ-pair, guard-lift + write-sites, state edge, temporal predicate, or NatSpec quote. The **On-chain=No** blocks (`I-3`, `I-14`, `I-15`, `X-1`, `X-2`, `E-4`) are the high-signal ones — each is simultaneously an invariant and a potential bug. Attack-surface bullets above cross-link directly into the relevant blocks.

---

## 4. Documentation Quality

| Aspect | Status | Notes |
|--------|--------|-------|
| README | Present | `README.md` — scope, trust statement, registry responsibility, no-deployment disclaimer |
| NatSpec | Adequate | `@notice`/`@dev` on every external function and most internals; errors documented in `VaultErrors.sol`; `IStaking` carries chain-behaviour notes |
| Spec/Whitepaper | Present | `docs/` (7 files): overview, security model, hotkey swaps & watcher runbook, edge cases, source flow guide, user guide, deployment with a precompile-by-precompile runtime compatibility table (per spec) |
| Inline Comments | Thorough | Why-comments on ordering, floor choices, gas-burn avoidance and rounding; no stale design references found |

Spec-derived claims used above are tagged `(per spec)` or cite `docs/`; the trust statements about distinct hotkeys, watcher liveness and the late-recovery attack come from `docs/security-model.md` and `docs/hotkey-swaps.md`.

---

## 5. Test Analysis

| Metric | Value | Source |
|--------|-------|--------|
| Test files | 45 | File scan (always reliable) |
| Test functions | 674 | File scan (always reliable) |
| Line coverage (src/) | 99.3% (937/944) | `forge coverage --ir-minimum --no-match-contract Invariant` (invariant suites excluded per project practice; CI runs them) |
| Branch coverage (src/) | 100% (225/225) | same run |
| Function coverage (src/) | 99.4% (161/162) | same run; `CloneBase` 6/7 |

The default `forge coverage` failed with "Stack too deep" (project compiles with `via_ir`); the `--ir-minimum` retry succeeded. Repo-wide totals including `test/` helpers and mocks are 83.3% lines / 68.2% branches and are not a statement about `src/`.

### Test Depth

| Category | Count | Contracts Covered |
|----------|-------|-------------------|
| Unit | ~590 | broad — every contract; dedicated suites for rounding, dust, recovery deadline, hotkey swaps, dissolution, mailbox reclaims, clone replacement, validator-set cap |
| Integration | broad | Vault + registry + clones + factory run together against chain mocks (`test/mocks`, `AlphaVaultTestBase.sol`); e2e Python harness against a localnet in `e2e/` (not Foundry) |
| Fork | 0 | none |
| Stateless Fuzz | 73 | VaultMath, share pricing, claimable TAO, backing resolution, public properties |
| Stateful Fuzz (Foundry) | 10 | `AlphaAccountingInvariant`, `BackingInvariant`, `ClaimableTaoInvariant`, `HotkeySwapInvariant` |
| Stateful Fuzz (Echidna / Medusa) | 0 | none |
| Formal Verification (Certora / Halmos / HEVM) | 0 | none |

### Gaps

- No formal verification of `VaultMath` or of the recovery state machine; both are small and pure enough to be good candidates.
- No Echidna/Medusa campaign; the four Foundry invariant suites are the only stateful coverage and are excluded from local runs.
- No fork tests; chain semantics are covered by mocks plus the out-of-repo e2e localnet harness, so a mock/runtime divergence in a precompile rule is the main untested seam.
- Coverage gaps in `src/`: one line in `AlphaVaultLens`, two in `VaultAllocation`, two in `VaultReads`, two in `CloneBase` (one function); the uncovered `CloneBase` path is most likely the `amount == 0` early return in `unwrapTao`/`flush`.

---

## 6. Developer & Git History

> Repo shape: normal_dev — 17 of 42 commits touch `src/` over 49 days (2026-09-14 → 2026-11-02); the initial import (`a259f5b`, 1996 lines) was followed by iterative fixes with tests.

Analyzed branch: `master` at `b986e47`.

### Contributors

| Author | Commits | Source Lines (+/-) | % of Source Changes |
|--------|--------:|--------------------|--------------------:|
| PawelGebal | 10 | +2125 / -130 | 83% |
| pawel-gebal-reef | 30 | +434 / -297 | 17% |
| mateuszsrebrny-reef | 2 | 0 (non-source) | 0% |

The two top identities share a name and are likely one developer under two accounts (could not confirm from git alone); treat source authorship as single-developer.

### Review & Process Signals

| Signal | Value | Assessment |
|--------|-------|------------|
| Unique contributors | 3 (likely 2 people) | Single-dev on source |
| Merge commits | 2 of 42 (5%) | PR numbers in most subjects suggest squash-merged PRs; no evidence of a second reviewer on source |
| Repo age | 2026-09-14 → 2026-11-02 | 49 days |
| Recent source activity (30d) | 7 commits | Active; two source commits on the analysis date |
| Test co-change rate | 100% | Every source-changing commit also modified tests (co-modification, not coverage) |

### File Hotspots

| File | Modifications | Note |
|------|-------------:|------|
| src/AlphaVault.sol | 9 | High churn — recovery, exits, TAO ordering |
| src/libraries/VaultAllocation.sol | 8 | High churn — swap following, slot assignment, consolidation |
| src/AlphaVaultLens.sol | 8 | Quote semantics changed 4 times |
| src/libraries/VaultReads.sol | 6 | Backing resolution |
| src/VaultErrors.sol | 4 | Error surface tracks behaviour changes |
| src/libraries/VaultMath.sol | 4 | mulDiv widening |

### Security-Relevant Commits

**Score** = weighted sum of fix-like signals in a commit: message keywords, diff patterns touching `require`/access control/accounting, and change shape. **10+ warrants a manual diff.**

| SHA | Date | Subject | Score | Key Signal |
|-----|------|---------|------:|------------|
| 1d54938 | 2026-10-30 | fix: refuse staking-list growth and deposit over own hotkeys (#34) | 18 | spans 5 security domains; rewrites access control; 446 lines |
| dd757e3 | 2026-10-14 | fix: do not park a write-off at zero supply (L-01) (#25) | 13 | accounting/state-machine fix, 5 lines |
| f6688c7 | 2026-09-22 | fix: pay the TAO exit after the refund mint so callbacks see settled state (#12) | 13 | reordering of external call vs state |
| 880c0ab | 2026-09-16 | fix: quote zero for dissolved positions without refunds (#5) | 13 | lens accounting |
| acfcd7a | 2026-10-15 | fix: let the watcher recover backing from hotkey 0x0 (L-04) (#28) | 12 | recovery path, net removal |
| 6e28c9c | 2026-09-16 | fix: allow preview quotes when alpha transfers are disabled (#4) | 12 | lens gating |
| a259f5b | 2026-09-14 | feat: add alpha wrapper | 12 | initial import, 1996 lines |
| bb2dac4 | 2026-11-02 | fix: keep an emptied slot on the hotkey the vault followed to (L-06) | 10 | slot resolution, same-day as analysis |
| c598af2 | 2026-09-23 | fix: follow a renamed key when its attested name is reused by another slot (N-4) (#19) | 10 | slot resolution |
| 205ccf1 | 2026-09-21 | fix: widen the three share-math products to mulDiv (#11) | 9 | overflow in share math |

Labels `L-01`, `L-04`, `L-06`, `N-4` in subjects indicate findings from a prior review being closed on this branch.

### Dangerous Area Evolution

| Security Area | Commits | Key Files |
|--------------|--------:|-----------|
| oracle_price (balance/price reads) | 17 | AlphaVault, VaultAllocation, VaultReads, VaultMath |
| fund_flows | 12 | AlphaVault, AlphaVaultLens |
| state_machines | 10 | AlphaVault, VaultReads |
| signatures (attestation/registry) | 9 | AlphaVault, BasicValidatorRegistry, IValidatorRegistry |
| access_control | 4 | CloneBase, CloneFactory, BasicValidatorRegistry |

### Security Observations

- **Single-developer source** — one person (two git identities) wrote 100% of `src/`; no second-reviewer signal in history.
- **Late large change** — `1d54938` (2026-10-30, 446 lines, score 18) touched 18 source files three days before analysis; it introduced the reject-growth flag handling in `collectDeposit` and `CloneBase.initialize`.
- **Same-day fixes** — `bb2dac4` and `30b4160` (246-line refactor of allocation identifiers) landed on the analysis date; `VaultAllocation.assignActives/_receivingHotkey` is the freshest logic in scope.
- **Prior-review carryover** — four commits close labelled findings (L-01, L-04, L-06, N-4), consistent with the README's internal-review statement; no independent audit yet.
- **Hotspot = attack surface** — `AlphaVault.sol` and `VaultAllocation.sol` lead both churn and the attack-surface list.
- **No technical-debt markers** — zero TODO/FIXME/HACK in `src/`.

### Cross-Reference Synthesis

- **Swap resolution is the freshest and most-fixed code** — `c598af2` + `bb2dac4` + `30b4160` all rewrite `assignActives`/`_receivingHotkey` → the first attack surface and I-15/X-1 are where the next bug is statistically most likely.
- **TAO exit ordering was already fixed once** — `f6688c7` moved the payout after the refund mint → the `taoLiability` bump in `_unwrapForTao:242-244` is a compensating mechanism worth re-deriving, not assuming.
- **Write-off at zero supply (`dd757e3`) and 0x0 recovery (`acfcd7a`)** — both touch `_finishRecovery`/`recoverStray` → the recovery state machine (I-4, I-12, I-16) has had two accounting fixes in a month.
- **Registry trust is documented, not enforced** — `ad51cca` ("stake on attested names without checking who owns them") deliberately moved ownership checks out of the vault → X-1/X-2/X-6 describe what the vault now takes on faith.

---

## X-Ray Verdict

**ADEQUATE** — Tests are HARDENED (unit + 73 stateless fuzz + 10 Foundry invariant suites, 99% src line coverage), docs are HARDENED (NatSpec plus a seven-file spec with a runtime compatibility table), and access control is ADEQUATE: roles and boundaries are explicit and the vault has no admin, but the one privileged role (`BasicValidatorRegistry` owner) acts instantly with no timelock or multisig in the reference implementation.

**Structural facts:**
1. 1552 nSLOC across 5 subsystems; 14 in-scope contracts/libraries plus 8 interfaces; no proxies, no upgrade path, no pause.
2. 13 permissionless `AlphaVault` entry points, all `nonReentrant`; 11 vault-only clone/factory functions; 1 instant owner setter in the registry.
3. Every balance, price, owner record and swap edge is a live Subtensor precompile read; the vault stores only a slot record (`logical`, `active`, `tracked`) and TAO index state.
4. 674 test functions in 45 files; 73 stateless fuzz and 10 invariant tests; no formal verification; no fork tests (e2e localnet harness lives outside Foundry).
5. 17 source-touching commits in 49 days by effectively one developer; 10 fix-scored commits, 4 of them closing labelled prior-review findings; two source commits on the analysis date.

# alpha-wrapper internal audit — 2026-11-06

| | |
| --- | --- |
| Commit audited | `052f820` (`master`) |
| Scope | `src/**/*.sol` (14 files, 1630 nSLOC) and `script/DeployAlpha.s.sol`; interfaces, mocks and tests read for context only |
| Chain reference | Subtensor `b6a81d144` (Release 488) at `~/Projects/subtensor`; every chain claim below cites a Rust location in that tree |
| Method | pashov `x-ray` pre-audit report (`x-ray/`), then pashov `solidity-auditor` v4.1: 12 specialist agents (math, access control, economics, execution trace, invariants, periphery, first principles, asymmetry, boundary, numerical gap, trust gap, flow gap), run 3 at a time, one pass, orchestrator dedup and four-gate validation, chain claims re-verified by the orchestrator |
| Prior reviews | Internal reviews L-01…L-06, N-4, QA 1-20 and "internal audit finding 2" are closed on this branch and were not re-raised |

No agent produced a finding with a complete, proven exploit on its own. Four issues were raised independently by four or more agents, survived the gates, and are promoted to findings at confidence 75 under the skill's multi-agent convergence rule. No path was found by which a caller extracts other holders' alpha or TAO beyond rounding dust or the trade-offs already stated in `docs/security-model.md` and `docs/edge-cases.md`.

## Severity scale

| Severity | Meaning here |
| --- | --- |
| Critical | Theft or permanent loss of a material share of holders' funds by an unprivileged caller |
| High | Loss of funds, or a permanent freeze of a position's funds, reachable by an unprivileged caller under ordinary conditions |
| Medium | Permanent freeze or loss under plausible but specific preconditions, or loss that needs a bounded third party to act |
| Low | Temporary loss of availability, dust-level loss, griefing at a cost to the attacker, or self-inflicted loss |
| Informational | Design or documentation gaps, test-model divergence from the chain, defense in depth |

## Summary

| Severity | Count | Items |
| --- | ---: | --- |
| Critical | 0 | |
| High | 0 | |
| Medium | 1 | F-1 |
| Low | 9 | F-2, F-3, F-4, L-1, L-2, L-3, L-4, L-5, L-6 |
| Informational | 10 | L-7 … L-16 |
| Rejected after verification | 2 | R-1, R-2 |

---

## Findings

### F-1 · Medium · The vault claims ownerless hotkeys from its own coldkey, and the chain can refuse or exhaust that claim

**Location** `StakeOps.ensureHotkeyHasOwner` (`src/libraries/StakeOps.sol:23-25`), reached from `moveToListedHotkey`, `flush`, `sell` and `VaultAllocation.pullDepositFromMailbox`.
**Raised by** 8 of 12 agents.

**Mechanism.** `tryAssociateHotkey` dispatches `create_account_if_non_existent(vaultColdkey, hotkey)` (`pallets/subtensor/src/staking/helpers.rs:128-158`). Three things happen there that the vault does not model:

1. **Owner policy.** `ensure_hotkey_owner_policy` runs first. The runtime policy is `HashedHotkeyOwnerPolicy::allows_owner(coldkey, hotkey) = compatible_authority(hotkey, coldkey)` (`runtime/src/hashed_owner.rs:8-10`). The floor comes from the *hotkey's* authentication kind (`runtime/src/hashed_auth.rs:1030-1038`): `HashedV1 → Committed`, `MlDsa | DerivedPq → PqRequired`. `authority_meets` (`pallets/hashed-accounts/src/mldsa.rs:159-168`) returns `is_protected(authority)` for `Committed`; the vault, the clones and the libraries are EVM-mapped ordinary accounts, so the claim of any hashed-scheme hotkey fails with `HotkeyOwnerPolicyViolation`. Ordinary hotkeys are unrestricted.
2. **Budget.** `ensure_staking_hotkeys_can_grow(coldkey, hotkey)` then pushes the hotkey onto the **vault coldkey's** `StakingHotkeys`. The vault never holds stake under these hotkeys, so `maybe_remove_staking_hotkey` never prunes them: every claim is a permanent entry, one list serves every subnet, the constructor already spends one on `parkingHotkey`, and the cap is `MAX_STAKING_HOTKEYS = 256` (`pallets/subtensor/src/lib.rs:126`). After 255 claims every later claim reverts `TooManyStakingHotkeys`.
3. **Reservation.** `ensure_account_not_reserved_as_coldkey_swap_destination(hotkey)` refuses a hotkey anyone has reserved with `announce_coldkey_swap_v2` (0.1 TAO, renewable). This case is documented in `docs/hotkey-swaps.md`; the other two are not.

A refused dispatch is a `PrecompileFailure::Error` and consumes all gas forwarded to the frame.

**Reachability.** Stake sits under an ownerless hotkey on a clone after the retained-stake swap in F-2 (verified: `Owner::<T>::remove(old_hotkey)` runs on every all-subnet swap without `keep_stake` at `swap_hotkey.rs:668-671`, while retained stakers keep their position under the old hotkey at `swap_hotkey.rs:1225-1231`). Agents found no other current chain path.

**Impact.** With an *ordinary* hotkey the claim succeeds and the cost is one budget entry per event; the position recovers once the registry publishes the successor. With a *hashed-scheme* hotkey, or a reserved one, every path that must move the stake reverts: `wrap`, `rebalance` and `unwrap` (consolidation off the old hotkey), `unwrapForTao` (`sell` claims first), `replaceClone` (`flush`). `syncBacking` reverts `BackingUnchanged` because the slot is not short, and `recoverStray(source)` reverts `NothingToRecover` because the hotkey is recorded. The token's alpha is frozen until the validator or another compatible authority re-associates the hotkey; the vault has no path of its own. Whether any attested validator uses a hashed-scheme hotkey today was not verified; the hashed-accounts pallet is live in Release 488.

**Recommendation.**
- Make the claim from the **subnet clone** (`SubnetClone.tryAssociateHotkey(bytes32) onlyWrapper`). A hotkey holding clone stake is already on the clone's list, so the cap check passes; the budget becomes per clone and `replaceClone` resets it. Check the side effect: `clear_small_nomination_if_required` skips sweeps for hotkeys the coldkey owns (`helpers.rs:267`), which removes a documented loss rather than adding one.
- State the owner policy and the 256 cap in `docs/hotkey-swaps.md` and `docs/deployment.md`, and have the registry refuse hashed-scheme hotkeys the claiming coldkey cannot own.
- Model the owner policy in `test/mocks/MockNeuron` / `MockStaking.associate` (today they always succeed or model the cap only).

### F-2 · Low · A stranger's 0.0001 TAO cross-subnet transfer makes the validator's next swap strand the vault's stake

**Location** `AlphaVault.wrap` via `VaultAllocation.stakingHotkeysForAttestedSet` (`src/libraries/VaultAllocation.sol:237-238`); same effect on `rebalance` and partial `unwrap`.
**Raised by** 4 of 12 agents. **Chain with F-1** at confidence 75: planted row + all-subnet swap + hashed-scheme hotkey ⇒ frozen token (Medium, counted under F-1).

**Mechanism.** The clone sets `setRejectStakingHotkeyGrowth(true)`. On an all-subnet swap of attested hotkey V to W, the clone's stake follows only if `hotkey_swap_stake_can_follow` (`stake_utils.rs:1577-1596`) is true: `hotkeys.contains(W) || (hotkeys.contains(V) && !hotkey_swap_needs_split(..))`, else `!rejects_growth && len < 128`. `hotkey_swap_needs_split` (`:1565-1573`) is true when the clone holds a nonzero `Alpha` row under V on **another** netuid. Any stranger plants that row: `transfer_stake(dest = cloneColdkey, hotkey = V, netuid M, netuid M, amount)` passes `ensure_third_party_staking_hotkeys_can_grow` because V is already listed (`:1599-1604`), and the same-subnet minimum is `DefaultMinTransfer = 100_000 RAO` (`runtime/src/lib.rs:1021`). The clone then lands in `retained_swap_stakers` (`swap_hotkey.rs:937-966`): its alpha stays under V (event `HotkeySwapStakeRetained`) while `Owner::<T>::remove(V)` runs.

**Vault side.** Slot `{V, V, x}` is not short, so `locateBacking` does not follow the successor. `stakingHotkeysForAttestedSet` takes the funded branch, `usable = hasOwner(V) = false`, `retired = V`: `wrap` and `rebalance` revert `AttestedHotkeyRetired`, partial `unwrap` reverts, full-supply `unwrap` and `unwrapForTao` proceed and claim V for the vault (one F-1 budget entry). After the registry publishes W, consolidation moves V→W and claims V on the way.

**Impact.** Deposits, weight alignment and partial alpha exits stop for that token until the registry owner publishes the successor; emissions continue under V. Without the planted row the same swap is followed automatically. The attacker spends 0.0001 TAO and waits for a validator swap it does not control. `MockStaking.moveHotkeyPositions` moves every position unconditionally, so no test reaches this path.

**Recommendation.** Decide whether a funded slot whose hotkey lost its owner record should be `retired` (today) or claimed lazily on the next move (as `unwrapForTao` already does); the lazy claim removes the halt but forwards gas to a claim F-1 may refuse. Add a mock mode that retains the clone's stake and removes the owner, and test `wrap`, `rebalance` and `unwrap` through it. Document the retained-stake case next to `keep_stake` in `docs/hotkey-swaps.md`.

### F-3 · Low · A payout that leaves a clone with less than 500 RAO burns the remainder and blocks the last claimant

**Location** `CloneBase.unwrapTao` (`src/CloneBase.sol:35-37`), called from `claimTao`, `_unwrapForTao`, `_unwrapFromDissolvedSubnet` and the mailbox reclaims.
**Raised by** 5 of 12 agents.

**Mechanism.** `Address.sendValue` is an EVM CALL with value; Frontier executes it with `ExistenceRequirement::AllowDeath` (`vendor/frontier/frame/evm/src/runner/stack.rs:1466-1471`). `EXISTENTIAL_DEPOSIT = 500` RAO (`runtime/src/lib.rs:524`) and dust goes to `SubtensorDustRemoval` (`pallets/subtensor/src/lib.rs:228-240`). A payout that leaves the clone's mapped account with 1–499 RAO reaps it and burns the remainder, while `taoLiability` and `claimableTao` still count it. Example: liability 600 RAO over two holders; A claims 300, the clone keeps 300 < 500 and is reaped; B's `claimTao` reaches `sendValue` with an empty clone and reverts until at least 300 RAO of new TAO arrives.

**Impact.** At most 499 RAO (5·10⁻⁷ TAO) per clone per event; the last claimant's `claimTao`, or the last dissolved-subnet `unwrap`, reverts until new TAO reaches the clone. The mocks move wei with `vm.deal` and model no existential deposit.

**Recommendation.** Either keep the clone's remainder at zero or at least the existential deposit (round the payout down, or revert when `balance - amount ∈ (0, ED)`), or fund each clone with one existential deposit at creation and exclude it from `indexableTao`. The same rule applies to a `claimTao` of 1–499 RAO to a recipient that holds nothing (L-7).

### F-4 · Low · A coldkey-swap reservation on a predicted clone or mailbox address makes `createMailbox` burn its gas

**Location** `CloneFactory._requireClean` (`src/CloneFactory.sol:52-61`) and `VaultClones.deployProtectedClone`.
**Raised by** 4 of 12 agents.

**Mechanism.** `_requireClean` checks owner, coldkey root, owned hotkeys, lock and list length, but not `ColdkeySwapDestinationReservations`. `announce_coldkey_swap_v2` (`pallets/subtensor/src/macros/dispatches.rs:2474-2520`) lets any signer reserve any account that is not yet a hotkey for `ColdkeySwapAnnouncementDelay` at the key-swap fee (0.1 TAO, `runtime/src/lib.rs:1042`). The candidate address is computable from `(user, netuid, uid)` or `(tokenId, uid)` in the mempool. `CloneOwner`'s constructor or `DepositMailbox._claimOwnHotkey` then calls `tryAssociateHotkey`, which fails at `ensure_account_not_reserved_as_coldkey_swap_destination` (`helpers.rs:141`); the dispatch error consumes all forwarded gas. Once deployed, the accounts are hotkeys and `NewColdKeyIsHotkey` (`swap_coldkey.rs:582-584`) refuses any later reservation, so only the pre-deployment window is exposed.

**Impact.** The victim's `createMailbox` reverts and pays the forwarded gas; they retry with a fresh UID. The attacker pays 0.1 TAO per attempt. `docs/security-model.md` already says a front-run UID forces a retry; it does not say the retry costs the chain gas, and no precompile exposes the reservation, so the vault cannot pre-check. No test covers it.

**Recommendation.** Document the reservation path and the gas cost; recommend a random UID and a private relay for users who are front-run; ask Subtensor for a reservation view so `_requireClean` can revert cheaply.

---

## Leads

Not promoted: either a step of the path is unverified, the trigger is a trusted or self-inflicted action, or the impact is below the finding bar. Each carries the severity it would have if confirmed.

| # | Severity | Location | Lead |
| --- | --- | --- | --- |
| L-1 | Low | `AlphaVault.recoverStray` / `wrap` | After a total write-off and a full exit (supply 0, slots `[parking:0]`), `_annex` books recovered alpha R to `tracked`; the next `wrap` prices with `sharesFor(preStake = R, supply = 0, D)`, so the 1e9 virtual shares own R forever and no depositor can withdraw it. Fair-rate minting keeps that position constant. Fix direction: route a zero-supply recovery to a treasury, or snapshot write-offs per token. |
| L-2 | Low | `AlphaVault.reclaimAlphaFromMailbox` / `reclaimMailboxAlphaAsTao` | A mailbox hotkey accepts stake on any subnet (`stake_utils.rs:1599-1616`), but every reclaim reads `getStake(mailbox, mailbox, netuid)` for the mailbox's own netuid; alpha of netuid B sent to the netuid-A mailbox is unrecoverable. Self-inflicted, permanent. Fix: take the stake netuid as a separate argument. |
| L-3 | Low | `AlphaVault.reclaimAlphaFromMailbox`, `_unwrapFromLiveSubnet` | The vault pre-reads `getRejectLockedAlpha(dest)` but not `getRejectStakingHotkeyGrowth(dest)` (exposed at `precompiles/src/staking.rs:555`, absent from `IStaking.sol`); `validate_stake_transition` (`stake_utils.rs:2060-2066`) refuses a destination that rejects growth or holds 128 entries and does not list the paying hotkey, and the gas burns. Mostly self-inflicted; a cheap pre-check exists. |
| L-4 | Low | `AlphaVault._unwrapFromLiveSubnet` | `validate_stake_transition` runs `ensure_account_not_reserved_as_coldkey_swap_destination(destination_coldkey)` for cross-coldkey transfers; an attacker who announces a swap into a victim's coldkey makes every `unwrap` to it revert with gas burned until the announcement lapses. No precompile exposes the reservation. `unwrapForTao` and other coldkeys remain. |
| L-5 | Low | `VaultAllocation._sellableChunk`, `AlphaVault.reclaimMailboxAlphaAsTao` | The leftover quote simulates the **whole slot** (`simSwapAlphaForTao(netuid, balance)`), and `do_remove_stake` refuses `amount > SubnetAlphaIn * 1000` (`remove_stake.rs:553-566`); a refused simulation or sale burns the forwarded gas. A one-slot position cannot use `excludedSlots`; the mailbox sale has no partial route. Fix: quote `simSwap(chunk + minLeftover) - chunkQuote` and bound chunks by the pool limit. |
| L-6 | Low | `AlphaVault.wrap` | After a total write-off `sharesFor(0, S, D) = D·(S + 1e9)` multiplies supply by the deposit; two or three total write-offs with large deposits reach `SUPPLY_CAP = 1e45` and `wrap` reverts for that token forever while exits keep working. Needs repeated chain-side total loss. Fix direction: rebase supply when `_finishRecovery` parks zero. |
| L-7 | Informational | `AlphaVault.claimTao` | A claim of 1–499 RAO to a recipient that holds nothing fails at `can_deposit` (`BelowMinimum`) although `ClaimBelowNativePrecision` passed. Same root as F-3. |
| L-8 | Informational | `VaultReads.attestedSetOf` | Only length, cap and equal lengths are checked; duplicate hotkeys make `_settle` write two slots on one balance (double-counted exits), weights summing above 10 000 make `rebalance`'s `total - assigned` underflow on every priced call. `IValidatorRegistry` documents both rules and `BasicValidatorRegistry` cannot violate them; a one-line sum and uniqueness check is cheap defense in depth for third-party registries. |
| L-9 | Informational | `VaultAllocation.pullDepositFromMailbox` | `validate_stake_transition` requires `SubtokenEnabled` on both netuids (`stake_utils.rs:1996-2001`); the vault reads the transfer switch but no precompile exposes the subtoken switch, so a disabled subnet burns the forwarded gas. Document it. |
| L-10 | Informational | `VaultAllocation.pullDepositFromMailbox` | `listed[0]` is taken as the landing hotkey whenever the target holds no stake, with no owner check; an emptied, swapped-away hotkey stays listed while its `Alpha` row exists (`staking_hotkey_must_remain`, `stake_utils.rs:945-955`) and may be ownerless or reserved. Frequency unverified. |
| L-11 | Informational | `VaultAllocation._gatherIntoLargestSlot`, `consolidateRotatedStake` | The vault floors every move at `getDefaultMinStake` (0.002 TAO) while the chain gates same-subnet moves at `DefaultMinTransfer` (0.0001 TAO, `stake_utils.rs:1508-1514`); with a multi-validator set a holder whose claim clears the floor can get `GatherBelowFloor` although the chain would move each slot. Conservative by design; the precompile exposes no transfer-minimum getter. |
| L-12 | Informational | `AlphaVault._unwrapFromLiveSubnet` | Same floor mismatch: `WithdrawTooSmall` at 0.002 TAO on a transfer the chain accepts at 0.0001 TAO. `MockStaking._requireMovable` encodes the vault's floor, not the chain's. |
| L-13 | Informational | `VaultAllocation.consolidateRotatedStake` | Roll, gather and rebalance hops write no vault storage and the record is rebuilt from `getStake`; `recoverStray` lets anyone trigger two full hops of slot 0. The chain conserves alpha on same-subnet moves (`ensure!(alpha_removed == alpha)`), so the only loss found is one RAO of share-pool rounding per hop. |
| L-14 | Informational | `AlphaVault.syncBacking` | A validator that owns two attested hotkeys can swap A into B; slot A reads short because B is taken, and `syncBacking` parks the position until the registry republishes. Exits keep working; documented in `docs/hotkey-swaps.md`. |
| L-15 | Informational | `test/mocks/MockStaking.moveHotkeyPositions` | The mock moves every position on a swap; the chain retains a growth-rejecting coldkey's stake when `hotkey_swap_needs_split` is true and removes the owner only on the all-subnet path. No test reaches F-1/F-2. **Highest-value test gap.** |
| L-16 | Informational | `test/mocks/MockStaking._writeStake` | The mock unlists a hotkey at zero quoted stake; the chain keeps it while any `Alpha` row exists (floored quotes leave fractional shares). On chain each rotated-out hotkey stays listed, so `replaceClone` opens and `StakingListFull` arrives earlier than tests show. |

---

## Rejected after verification

| # | Claim | Why rejected |
| --- | --- | --- |
| R-1 | `replaceClone` reverts when the old clone holds 1–499 RAO because `transfer_all` to a fresh successor would fail `BelowMinimum` | A mapped account's balance is always 0 or ≥ ED: a transfer out that leaves less is reaped (F-3), and a deposit below ED into an empty account is refused by the chain. `transfer_all` of zero succeeds. |
| R-2 | The registry owner can republish the same hotkey to reopen deposits after a write-off, deposit at the written-down price, then `recoverStray` returned alpha for the new shares | Requires the registry owner, a trusted role, to act against documented intent with no unprivileged amplifier; `docs/security-model.md` names the registry update as the gate and the late-recovery attack as accepted. |

## Verified and found consistent with the chain

Consolidated from all twelve agents and re-checked by the orchestrator where it affected a grade:

- Every precompile selector, argument order and return shape in `src/interfaces/` matches `precompiles/src/*.rs`; `getAlphaPrice` is `floor(price·1e9)·1e9`, so `ALPHA_PRICE_QUANTUM_E18 = 1e9` is exact; `getSubnetCapacityConfig` field 10 is `TransferToggle`; `getStakingHotkeys` returns `[offset, offset+limit)` clipped to the list, so `_pilesUnderListedHotkeys` indexing is in bounds.
- Share math (`sharesFor`/`assetsFor`, virtual offsets 1e9/1) rounds against the caller on every path including the TAO-exit refund; the TAO index keeps `taoLiability ≤ clone.balance` in the EVM model and `SUPPLY_CAP` keeps every whole-RAO arrival indexable; `_update` handles batch ids and self-transfers without double accrual.
- `_sellableChunk`'s marginal leftover quote is strictly conservative against `clear_small_nomination_if_required` (post-sale spot price, remove-stake paths only); full drains bypass the minimum as `_sellRound` assumes.
- Clones and mailboxes are hotkeys, so coldkey swaps into them fail `NewColdKeyIsHotkey`; third parties can land alpha on a growth-rejecting clone only under hotkeys it already lists (`stake_utils.rs:1599-1616`), which closes donation inflation and list filling; the parking entry is always reserved (`stakingListAdmits`).
- `ReentrancyGuardTransient` works: the runtime runs Frontier's Pectra config with transient storage.
- Same-subnet `move_stake` ignores `TransferToggle`, so `rebalance`, `syncBacking` and `recoverStray` keep working with transfers disabled; dissolution removes `NetworkRegisteredAt` while the netuid is still queued, so `isDissolved` passes the blackout correctly.
- No ordering of swap, re-registration and re-attestation traced by the resolver agents produced two funded slots on one hotkey; merged piles fall to `BackingShortfall` and self-heal through parking.

## Artifacts

- Assembled pashov report (shell-generated, unedited): `.solidity-auditor/runs/20261106-062621/full-report.md`; raw agent outputs under `agent-results/` in the same directory (untracked).
- Pre-audit structural report: `x-ray/x-ray.md`, `x-ray/invariants.md`, `x-ray/entry-points.md`, `x-ray/architecture.svg` (untracked).

> ⚠️ This review was performed with AI assistance. AI analysis cannot establish the absence of vulnerabilities and no guarantee of security is given.

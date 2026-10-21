# Staking-list DoS fix

Status: steps 1 to 4 are on PR #34. Steps 5 and 6 are designed, not implemented.

The proposal below is retained for review context. The
[corrected atomic migration](#corrected-atomic-migration) chapter supersedes its
ownership and migration design and qualifies its cleanup claims.

## In short

Subtensor lets an account stake under at most 256 hotkeys. Strangers could add
hotkeys to a clone's list by sending it stake, and a full list blocked deposits.
The fix, step by step:

1. Every clone refuses list growth by others from the moment it is created, so a
   stranger can only top up hotkeys the clone already uses.
2. A deposit goes to the user's mailbox under the mailbox's own hotkey and reaches
   the clone on a hotkey the clone already lists, so the refusal never blocks an
   honest deposit.
3. At the cap the vault still moves stake onto hotkeys the clone lists, so exits
   and recovery through the parking hotkey keep working.
4. A clone is created only for a subnet the registry serves.
5. Each clone's hotkey is owned by its own small owner contract instead of the
   vault, so the vault's own list never grows.
6. A clone whose list is full anyway can be replaced by anyone: a fresh clone takes
   over the same token, all stake and TAO move across, and the old clone is
   abandoned. Token ids never change.

## For the reviewer

Subtensor v481 caps `StakingHotkeys` at 256 entries per coldkey for its own
actions and 128 for third-party transfers, always admits a hotkey already listed,
and lets an account refuse third-party growth with `setRejectStakingHotkeyGrowth`,
with a bypass for hotkeys the receiver owns. Every mailbox and subnet clone sets
the flag during creation. The mailbox owns its own account as a hotkey, which is
the bypass deposits use: the user stakes to the mailbox under that hotkey, and
`wrap` transfers it to the clone under a listed registry hotkey, lifting the
clone's flag inside the transaction only when the clone lists nothing yet.
`StakeOps.move` reverts `StakingListFull` at the cap only for a hotkey the clone
does not list, checked by paging `getStakingHotkeys`. An entry can outlive its
stake: a root-subnet crumb under a listed validator leaves a non-zero basket
watermark for the pair, because the chain rebases the watermark by `rate × delta`
rounded toward minus infinity on both stake in and stake out, so a plain round
trip ends at minus one; subnet dissolution removes stake rows without pruning;
and the chain prunes an entry only on the pair's own stake paths, on hotkey swaps
for coldkeys with stake, and on the auto-stake switch. A list therefore grows by
one entry per crumbed validator that the registry drops, at about one transaction
fee per entry, and nothing callable from the EVM frees it. The fix accepts that a
clone fills and makes clones disposable. Hotkey association appends the hotkey to
the owner's `StakingHotkeys` and nothing frees that entry either, and a hotkey
swap rewrites the owner's `OwnedHotkeys` but not a stake-less staking-list entry
and burns 0.1 TAO, so each clone gets a dedicated owner proxy whose only action
is `tryAssociateHotkey` for the clone; the vault's list holds the parking hotkey
alone. A permissionless migration call, allowed only when the clone's list count
equals the cap and the position is clean (live subnet, no lock, no shortfall or
open recovery window, alpha transfers enabled), deploys a fresh clone and owner
through the existing contamination checks, lifts the new clone's flag for the
call, transfers every own-subnet pile found on the old clone's list to the new
clone under the same hotkey (the chain's 128 third-party entries bound one
migration), moves the native balance, re-points the token's clone address,
re-reads balances and restores the flag. Backing records, shares, the claim index
and mailboxes are keyed by token id and hotkey, so nothing else changes. Root and
other-subnet crumbs stay on the abandoned clone, which receives nothing of ours
afterwards: gifts land only on listed hotkeys and hotkey swaps follow the stake.

## Corrected atomic migration

This is a proposed implementation plan. Keep the same token and replace its
custody clone in one transaction. Migrate recorded backing and existing TAO;
accept a bounded dust loss and forfeit emissions or TAO arriving at the old clone
afterwards.

The expected validator set is small, probably below five. That is an operating
expectation, not an agreed maximum of four. The current interface permits 64.
Gas validation must state the supported position count; this plan makes no
promise that migrating every permitted set fits one transaction.

### Why the earlier proposal could fail

- **128 incoming keys is a destination limit.** A stranger can fund all 256
  historical keys already listed by the old clone. Copying every own-subnet
  position unchanged fails when the new clone receives its 129th distinct key.
- **Exactly 256 is too late.** A validator rotation can need more slots than
  remain, then revert back to a count below 256. The proposed migration would
  still be unavailable.
- **Recovery can need an absent parking key.** A full list can prevent securing
  backing, while the clean-position requirement also prevents migration.
- **A full transfer still has a minimum.** One small position can make the whole
  migration revert. Below that minimum does not automatically mean an acceptable
  loss: the total discarded amount needs a separate limit.
- **Clone owners alone do not isolate ownership growth.**
  `StakeOps.ensureHotkeyHasOwner` also associates recovery and sale keys with the
  vault. Those claims consume its list too.
- **Moving every historical position can exceed block gas.** A small current
  validator set does not make the historical list small. The migration must work
  from bounded backing records rather than transfer every funded historical key.

### Implementation, step by step

1. **Isolate all ownership claims.** Give each custody clone a dedicated owner
   contract. Route claims for ownerless recovery or sale keys through dedicated
   owners too. Each owner can associate only its fixed target. Check candidate
   addresses for contamination, initialize atomically, and verify actual native
   ownership before using them. Custody clones continue to own no hotkeys.

2. **Keep parking reachable.** Before every operation that can add staking-list
   entries, account for its new destinations and preserve one free entry whenever
   parking is absent. Apply this to deposits, rotations and recovery. Growth
   rejection remains enabled between calls, so strangers cannot consume that
   reserved entry. If parking is already listed, moves to it remain admissible
   at the cap. This invariant must start with clone creation; it cannot repair
   an existing full clone whose parking key is absent.

3. **Make replacement available before exhaustion.** Use a deterministic
   headroom threshold, not equality with 256. With the current 64-validator
   interface, 192 entries is a conservative eligibility threshold. This does not
   assume a four-validator limit or guarantee migration gas for 64 positions.
   A replacement starts below the threshold, preventing repeated public
   replacements of fresh custody. Recovery can finish through the reserved
   parking capacity before migration is attempted.

4. **Check the position before moving funds.** Require the token's original
   subnet generation to be live, outside dissolution, unlocked and accepting
   transfers. Require no open recovery window and resolve all recorded backing.
   A missing material position must go through recovery; it cannot be relabelled
   as dust. Preserve any existing requirement for a newer registry attestation.
   Root-netuid custody needs separate treatment because its holding rules differ;
   this migration is for non-root alpha subnets.

5. **Build a small, fixed transfer plan.** Resolve the recorded active keys,
   including parking where applicable, and snapshot their balances before moving
   anything. Include material old-key residue associated with those records.
   Count actual source positions, not just current validators. Historical gifts
   outside recorded backing do not expand the migration loop. A known unresolved
   user position is not such a gift. Validate the plan against the supported
   source count and destination capacity before making transfers.

6. **Apply an explicit dust budget.** Define a small, fixed aggregate loss limit
   covering both skipped balances and transfer rounding. The migration caller
   cannot increase it. Skip only prevalidated dust; a different transfer failure
   reverts everything. Native minimums, failed quotes and a zero price must not
   become permission to discard arbitrary backing. Pin the budget's units and
   value before implementation acceptance. If no valid transfer plan fits it,
   leave the original custody and records intact.

7. **Move funds and switch custody atomically.** Deploy a protected replacement,
   temporarily admit the planned transfers, and move each transferable recorded
   position under the same hotkey. Read actual destination balances and verify
   total loss against the dust budget before updating backing records. Transfer
   the entire existing native TAO balance, including reserved claims. Preserve
   token ID, supply, claim index, debts and liabilities; moving existing TAO must
   not credit it again. Restore and verify protection, then publish the new clone
   address under the reentrancy guard. Any failure rolls back the whole operation.

8. **Keep dissolution on its existing path.** Refuse migration for a dissolving
   or dissolved token generation. Its clone stays assigned to that token so
   dissolution refunds remain available for normal redemptions. An atomic
   migration cannot remain half-finished across blocks. After a successful live
   migration, the new clone holds the backing that future dissolution will refund.

### Agreed simplifications and their limits

| Simplification | Why it is acceptable |
| --- | --- |
| One transaction; no batches | Only the supported small set of backing positions is transferred. Native gas validation must include a full historical list, which still increases each call's cost. Larger configurations are outside this operating assumption. |
| Bounded dust may be lost | The protocol limits the total loss and records actual received backing. This removes the need for dust loans or a consolidation state machine. |
| Late emissions and TAO may be abandoned | This loss is explicitly accepted. The old clone needs no forwarding service for those arrivals. Existing TAO and recorded material backing still migrate. |
| Historical gift positions do not drive migration | Untracked donations cannot force hundreds of transfers. Missing recorded backing must be resolved before this rule applies. |
| No migration during dissolution | Custody stays in place for refunds and redemption, so migration needs no special dissolution workflow. |
| Recovery finishes before migration | The reserved parking entry removes the capacity deadlock. Migration does not change recovery deadlines or perform a new material write-off. |

The exact dust budget and supported source count remain implementation decisions.
The expectation of fewer than five validators does not itself enforce either.

### Runtime facts and acceptance checks

The attack requires the clone to use different validators over time. An attacker
can keep existing entries occupied; the rejection flag prevents inserting an
arbitrary new set into a protected clone. Root stake entering and leaving at an
unchanged rate leaves a minus-one watermark when the rate-times-amount product
is fractional, and zero when it is integral. Native root-claim methods exist,
but tiny unpayable claims can leave that watermark untouched. The wrapper's
cleanup therefore does not reliably release the slot. Funding, transfers and
cleanup have costs; a universal one-transaction-fee estimate is not justified.

Before accepting the implementation, native v481 regression tests must cover:

- A full historical list with the supported small backing set and many funded
  historical gifts; migration stays within block gas and destination limits.
- Rotation near capacity and shortfall recovery with parking initially absent;
  the reserve survives every entry-adding path.
- Ownership claims during recovery and mailbox cleanup; the vault list stays
  bounded.
- Dust at, below and above the aggregate allowance, plus rounding and failed
  transfers; excessive loss reverts all changes.
- Existing TAO claims before and after migration, pending mailbox deposits,
  unchanged shares, and protection flags after success and rollback.
- Dissolution, dissolved generations, netuid reuse, locks and disabled transfers;
  refused migration leaves the original custody and claims intact.

Relevant code: [backing and subnet checks](../../src/libraries/VaultReads.sol),
[ownership claims](../../src/libraries/StakeOps.sol), and
[recovery and TAO accounting](../../src/AlphaVault.sol). Native admission,
transfer minimums and pruning are in
[Subtensor v481 stake_utils.rs](https://github.com/RaoFoundation/subtensor/blob/v481/pallets/subtensor/src/staking/stake_utils.rs);
watermark rounding and claim thresholds are in
[claim_root.rs](https://github.com/RaoFoundation/subtensor/blob/v481/pallets/subtensor/src/staking/claim_root.rs).

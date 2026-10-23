# Hotkey swaps and recovery

The vault supports weighted `IValidatorRegistry` implementations. Here, the
`BasicValidatorRegistry` owner updates one target.

The design uses automatic one-hop swap handling plus an external watcher.
Temporary wrap/exit failures while the watcher repairs chain state are accepted.

## What changes in a swap

A hotkey is an identifier that outlives its **owner record**, which Subtensor
can remove. That record associates it with a coldkey and is required for
stake operations. It is separate from ownership of delegated alpha: the vault's
alpha stays under the vault clone's coldkey.

An all-subnet swap that carries the stake removes the old hotkey's owner record;
a per-subnet swap, or one that leaves the stake under the old key, retains it.
In these docs, “ownerless” means only that the record is absent.

## An emptied slot after a swap

Suppose the registry names A and the vault holds 100 alpha there:

1. A swaps to B across all subnets. The 100 alpha moves to B; A loses its owner record.
2. The vault follows the swap and records B as the actual stake location.
3. An exit empties that slot. The next allocation for A goes to B, the key that
   still has an owner record.

For an empty slot the vault prefers the attested name, then the recorded key,
then that key's one-hop successor, each only while it has an owner record,
subject to collision checks. Funded slots stay at their resolved location.
After a per-subnet swap the name keeps its owner record, so an emptied slot
returns to the name and stays idle there until the registry owner publishes
the successor.

## Automatic handling has limits

The record keeps an attested name (`logical`), actual stake location (`active`)
and expected alpha (`tracked`). One shortfall clock covers the whole token.

The resolver follows at most one hop from each recorded active key, only when
the successor covers that slot's expectation within 1000 RAO of accounting slack.
It counts each key for at most one slot. Separately observed swaps can advance the
record repeatedly: any priced operation, and a `syncBacking` call on a position
that accounts for itself, writes a followed swap into the record. Two
unobserved swaps, an erased edge or a collision need a watcher. Subnet re-registration can erase lineage.

## Receiving keys

A receiving key needs an owner record, because the chain refuses stake
operations without one: the attested name, else the recorded active key, else
its one-hop successor. A name with no usable key reports
`AttestedHotkeyRetired`; the registry owner replaces the target.

A vacated attested name that someone else claims receives an empty slot's
allocation until the registry owner publishes the successor. The alpha stays
under the vault's coldkey and, if moved, is recovered as missing backing.

The chain refuses to move stake through a hotkey with no owner record. When the
vault has to move stake off such a key, it claims the key for its own coldkey
first, then moves. The claim is permanent, and while the name stays attested
the claimed key counts as a receiving key for an emptied slot, which stays
idle there until the registry owner publishes the successor.

## The parking hotkey

At deployment the vault claims one hotkey for its own coldkey, the parking
hotkey, and holds it for good. Sync gathers
located backing onto that hotkey when a balance clears the conservative movement
floor; sub-floor balances may stay behind while the fixed window runs. Completion collapses the record to
parking; abandoned dust needs explicit `recoverStray` sources later. The position
is then parked:

- Deposits and weight alignment wait for an attestation newer than the one in
  force when the position parked.
- Alpha exits pay from the parking hotkey; the alpha arrives delegated to it and
  the holder moves it to a validator with their own `moveStake`.
- TAO exits sell from the parking hotkey. Share transfers and TAO claims work.
- Emissions resume once the position is released.

One parking hotkey serves every subnet. The chain keys stake by hotkey, coldkey
and subnet, and each subnet's position rests under its own clone coldkey, so
parking one subnet touches only that subnet's position, and each position is released by
its own registry authority.

The first wrap, rebalance or alpha exit after a newer attestation rolls the
parked alpha onto the attested set, aligns it and clears the parked state.
Re-publishing the same set under a new nonce releases a position whose lost
name was already replaced or irrelevant.

## Two independent recovery jobs

| Problem | Meaning | Repair |
| --- | --- | --- |
| Name has no usable key | The attested name, its recorded key and its successor have no owner record. | Registry governance publishes a set without the name, or the validator reclaims it. |
| Missing backing | The vault cannot locate enough alpha to satisfy its record. | Park it with `recoverStray`, or let `syncBacking` write off the difference after the window. |

They can occur together. An attested entry with no usable key blocks allocation
even while backing is intact.

## Watcher runbook

1. Monitor current registry entries, recorded/resolved stake keys, backing
   status and `awaitingAttestation`. Include empty entries and newly attested
   keys with no recorded slot. If the vault resolves a successor after a swap,
   call `syncBacking(tokenId)` before the old key is re-registered to record it.
   Watch the chain's hotkey swap events for attested names. After any swap of
   an attested name, publish the successor at once: until then an emptied slot
   re-stakes under the old name, which stays idle on that subnet.
2. For missing backing, call `syncBacking(tokenId)`. It secures all located
   backing on `parkingHotkey` before starting one fixed recovery window, except
   below-floor piles. Other collection failures revert.
3. Locate more alpha under the clone's coldkey and call
   `recoverStray(tokenId, source)` once per hotkey, after sync declares the loss.
   Finds reduce the pooled deficit without validator attribution. If parking is
   empty, collect a movable source first so it can carry smaller sources home.
   `missingStake(tokenId)` reports unlocated alpha;
   dust at recorded keys reduces that amount and is written off when it is too small to park.
4. While recovery is open, priced operations refuse. Further syncs collect
   returns at recorded locations. The deadline stays fixed through partial recovery.
   At expiry, sync collects returns before writing off the remaining deficit.
   After collecting full coverage, call sync again to finalize recovery.
   Full recovery or write-off leaves the position parked unless no shares remain. Alpha recovered later
   belongs to the holders at that time.
5. After completion with shares outstanding, registry governance publishes a newer set even if all backing returned.
   Remove any lost or captured name, naming the intended successor. The next wrap
   or `rebalance(netuid)` releases the parked position onto it.
6. `StakingListFull` on any call means the clone's staking list is full. Call `replaceClone(tokenId, uid)` with a fresh random UID,
   then retry: the position, its TAO and the token id move to a fresh clone.

Collection emits `BackingRecovered`; sync finalization emits
`BackingParked`. A write-off emits `BackingWrittenOff` before it. Both calls
are permissionless.

Declaration cost grows with the number of located keys: simulate the call and
budget above the estimate. Keep funds for retries when a chain restriction
blocks collection.

## Exit behavior and accepted tradeoffs

If an attested entry has no usable receiving key, `AttestedHotkeyRetired`
blocks wraps, rebalances and partial alpha exits. The guard is conservative: it
applies even if that entry's rebalance move would be too small to execute. A
full-supply alpha exit may proceed. "Full supply" means all outstanding shares.

`unwrapForTao` ignores registry weights and sells from recorded keys, including
the parking hotkey. It still needs intact backing, an executable pool sale and
an acceptable payout. Partial sales face post-fee minimums and dust protections.

On a live subnet, a shortfall blocks wraps, rebalances, both exits and value
quotes until the position parks or the loss is written off. Share transfers,
claimable TAO and mailbox recovery stay available.

A parked position pays exits; deposits and emissions resume once a newer
registry attestation arrives. A validator can swap and re-register its
old key to cut a successor edge the vault still needs. After an all-subnet
swap, anyone paying the burn can register that ownerless key on the affected token's
subnet if registration is open. If backing goes short, call `syncBacking(tokenId)`, then
`recoverStray(tokenId, successor)`, then `syncBacking(tokenId)` before write-off.

A revert preserves shares and stake, but costs gas. A finalized write-off really
reduces holders' accounted backing; alpha recovered later belongs to holders at
recovery time. Watcher and registry authority availability are therefore liveness
dependencies, and recovery before write-off matters financially. See the
[late-recovery risk](security-model.md#recovery-window-tradeoff-and-late-recovery-attack).

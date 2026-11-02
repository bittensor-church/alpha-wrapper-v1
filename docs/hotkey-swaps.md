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
a per-subnet swap, or one that leaves the stake under the old hotkey, retains it.
In these docs, “ownerless” means only that the record is absent.

## An emptied slot after a swap

Suppose the registry names A and the vault holds 100 alpha there:

1. A swaps to B across all subnets. The 100 alpha moves to B; A loses its owner record.
2. The vault follows the swap and records B as the actual stake location.
3. An exit empties that slot. The next allocation for A goes to B, the hotkey that
   still has an owner record.

For an empty slot the vault takes the recorded hotkey while it has an owner
record and no outgoing swap edge, else the attested hotkey while it has an owner
record, else that hotkey's one-hop successor, subject to collision checks. Funded
slots stay at their resolved location.

## Automatic handling has limits

The record keeps an attested hotkey (`logical`), actual stake location (`active`)
and expected alpha (`tracked`). One shortfall clock covers the whole token.

The resolver follows at most one hop from each recorded active hotkey, only when
the successor covers that slot's expectation within 1000 RAO of accounting slack.
It counts each hotkey for at most one slot. Separately observed swaps can advance the
record repeatedly: any priced operation, and a `syncBacking` call on a position
that accounts for itself, writes a followed swap into the record. Two
unobserved swaps, an erased edge or a collision need `syncBacking`,
`autoRecoverStray` and `syncBacking` again, each open to anyone: a swap keeps
the clone's alpha under a hotkey in the clone's staking list, which
`autoRecoverStray` reads. Subnet re-registration can erase lineage.

## Receiving hotkeys

A receiving hotkey needs an owner record, because the chain refuses stake
operations without one. An attested hotkey with no usable hotkey reports
`AttestedHotkeyRetired`; the registry owner replaces the target.

A slot the vault has followed a swap from stays on that hotkey while it keeps its
owner record and no outgoing swap edge, whoever claims the vacated hotkey. An attested hotkey
with no followed record receives an empty slot's allocation while it has an
owner record, whoever holds it. Alpha moved off either without a trail is
missing backing: every priced call reverts `BackingShortfall` until a watcher
parks the position, which earns again once the registry publishes a new set.
The followed hotkey keeps the slot after its validator registers the attested
hotkey again; a swap from the followed hotkey onto it, or publishing the
followed hotkey, moves the slot.

The chain refuses to move stake through a hotkey with no owner record. When the
vault has to move stake off such a hotkey, it claims the hotkey for its own coldkey
first, then moves. The claim is permanent, and while the hotkey stays attested
the claimed hotkey counts as a receiving hotkey for an emptied slot, which stays
idle there until the registry owner publishes the successor. Anyone paying the
chain's hotkey-swap fee can block the claim by reserving the ownerless hotkey as a
coldkey-swap destination; the stake under it cannot move while the
reservation lasts.

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
hotkey was already replaced or irrelevant.

## Two independent recovery jobs

| Problem | Meaning | Repair |
| --- | --- | --- |
| Attested hotkey has no usable hotkey | No owner record on the attested hotkey or its successor; none, or an outgoing swap edge, on its recorded hotkey. | Registry governance publishes a set without it, or the validator reclaims it. |
| Missing backing | The vault cannot locate enough alpha to satisfy its record. | `autoRecoverStray` parks what the clone's staking list reveals, `recoverStray` a named hotkey; `syncBacking` writes off the difference after the window. |

They can occur together. An attested entry with no usable hotkey blocks allocation
even while backing is intact.

## Watcher runbook

1. Monitor current registry entries, recorded/resolved stake hotkeys, backing
   status and `awaitingAttestation`. Include empty entries and newly attested
   hotkeys with no recorded slot. If the vault resolves a successor after a swap,
   call `syncBacking(tokenId)` before the old hotkey is re-registered to record it.
   Watch the chain's hotkey swap events for attested hotkeys. After any swap of
   an attested hotkey, publish the successor at once: until then an emptied slot
   stays on the followed hotkey, or with no record re-stakes under the old hotkey.
2. For missing backing, call `syncBacking(tokenId)`. It secures all located
   backing on `parkingHotkey` before starting one fixed recovery window, except
   below-floor piles. Other collection failures revert.
3. After sync declares the loss, call `autoRecoverStray(tokenId)` until it
   reverts `NothingToRecover`: each call collects up to eight listed hotkeys the
   record does not name. Call `recoverStray(tokenId, source)` for a hotkey it
   cannot reach.
   Finds reduce the pooled deficit without validator attribution. If parking is
   empty, collect a movable source first so it can carry smaller sources home.
   `missingStake(tokenId)` reports unlocated alpha;
   dust at recorded hotkeys reduces that amount and is written off when it is too small to park.
4. While recovery is open, priced operations refuse. Further syncs collect
   returns at recorded locations. The deadline stays fixed through partial recovery.
   At expiry, sync collects returns before writing off the remaining deficit.
   After collecting full coverage, call sync again to finalize recovery.
   Full recovery or write-off leaves the position parked unless no shares remain. Alpha recovered later
   belongs to the holders at that time.
5. After completion with shares outstanding, registry governance publishes a newer set even if all backing returned.
   Remove any lost or captured hotkey and publish the intended successor. The next wrap
   or `rebalance(netuid)` releases the parked position onto it.
6. The lens's `stakingListEntries(tokenId)` reports the clone's staking list. From
   128 entries, half the chain's cap, anyone can call `replaceClone(tokenId, uid)`
   with a fresh random UID; `StakingListFull` on any call means the same. The
   position, its TAO and the token id move to a fresh clone; piles below the
   floor stay on the old clone.

Collection emits `BackingRecovered`; sync finalization emits
`BackingParked`. A write-off emits `BackingWrittenOff` before it. Both calls
are permissionless.

Declaration cost grows with the number of located hotkeys: simulate the call and
budget above the estimate. Keep funds for retries when a chain restriction
blocks collection.

## Exit behavior and accepted tradeoffs

If an attested entry has no usable receiving hotkey, `AttestedHotkeyRetired`
blocks wraps, rebalances and partial alpha exits. The guard is conservative: it
applies even if that entry's rebalance move would be too small to execute. A
full-supply alpha exit may proceed. "Full supply" means all outstanding shares.

`unwrapForTao` ignores registry weights and sells from recorded hotkeys, including
the parking hotkey. It still needs intact backing, an executable pool sale and
an acceptable payout. Partial sales face post-fee minimums and dust protections.

On a live subnet, a shortfall blocks wraps, rebalances, both exits and value
quotes until the position parks or the loss is written off. Share transfers,
claimable TAO and mailbox recovery stay available.

A parked position pays exits; deposits and emissions resume once a newer
registry attestation arrives. A validator can swap and re-register its
old hotkey to cut a successor edge the vault still needs. After an all-subnet
swap, anyone paying the burn can register that ownerless hotkey on the affected token's
subnet if registration is open. If backing goes short, call `syncBacking(tokenId)`, then
`autoRecoverStray(tokenId)`, then `syncBacking(tokenId)` before write-off.

A revert preserves shares and stake, but costs gas. A finalized write-off really
reduces holders' accounted backing; alpha recovered later belongs to holders at
recovery time. Watcher and registry authority availability are therefore liveness
dependencies, and recovery before write-off matters financially. See the
[late-recovery risk](security-model.md#recovery-window-tradeoff-and-late-recovery-attack).

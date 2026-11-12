# Hotkey swaps and recovery

The vault supports weighted `IValidatorRegistry` implementations. Here, the
`PlaceholderValidatorRegistry` owner updates one target.

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

The record keeps the attested hotkey (`attested`), the hotkey the stake sits under
(`stakedUnder`) and the expected alpha (`tracked`). One shortfall clock covers the whole token. A
priced call values the position before it acts: `wrap`, `unwrap`, `unwrapForTao`,
`rebalance` and the lens previews.

The resolver follows at most one hop from each recorded hotkey, only when
the successor covers that slot's expectation within 1000 RAO of accounting slack.
Failing that, it takes, among the hotkeys the clone stakes under that no other slot
holds, the one with the smallest pile that covers the slot. It counts each hotkey
for at most one slot. Two slots that moved together and differ by less than what
the piles gained since the record was last written can take each other's pile:
the total stays exact, each validator holds the other's weight on later deposits
and alignment, and a registry set naming both successors puts each slot under its
own validator. Separately observed swaps can advance the record repeatedly:
any priced call, and a `syncBacking` call on a position that accounts for
itself, writes a followed or found hotkey into the record. A found hotkey keeps
the slot like a followed one, even when it is a rotated-out validator; a later
registry set moves the slot. A sweep, a pile split across hotkeys, a pile under
hotkey 0x0, two slots merged onto one hotkey, or a pile found under a hotkey the
registry attests for another slot need a watcher or a registry update.

## Receiving hotkeys

A receiving hotkey needs an owner record, because the chain refuses stake
operations without one. An attested hotkey with no usable hotkey reports
`AttestedHotkeyRetired`; the registry owner replaces the target.

A slot the vault has followed a swap from stays on that hotkey while it keeps its
owner record and no outgoing swap edge, whoever claims the vacated hotkey. If the
validator swaps on from the followed hotkey while the slot is empty, a stranger
can claim that hotkey, clear any swap edge on it and receive the slot's allocation.
An attested hotkey with no followed record receives an empty slot's allocation while it has an
owner record, whoever holds it. Either way the stranger cannot take the
principal: the alpha stays under the clone's coldkey, and moved without a trail
it is found on the clone's staking list. A pile no single listed hotkey covers
is missing backing: every priced call reverts `BackingShortfall` until a watcher
parks the position, which earns again once the registry publishes a new set.
The followed hotkey keeps the slot after its validator registers the attested
hotkey again; a swap from the followed hotkey onto it, or publishing the
followed hotkey, moves the slot.

The chain refuses to move stake through a hotkey with no owner record. When the
vault has to move stake off such a hotkey, the clone's owner contract claims the
hotkey first, then the clone moves; the entry lands on the owner contract's own
staking list. The claim is permanent, and while the hotkey stays attested
the claimed hotkey counts as a receiving hotkey for an emptied slot, which stays
idle there until the registry owner publishes the successor. Anyone paying the
chain's hotkey-swap fee can block the claim by reserving the ownerless hotkey as a
coldkey-swap destination; the stake under it cannot move while the
reservation lasts. A hotkey under the chain's hashed or post-quantum account
schemes refuses every EVM claimant; stake under it moves again once an account
of that scheme, such as its validator, claims it.

## The parking hotkey

At deployment the vault claims one hotkey for its own coldkey, the parking
hotkey, and holds it for good. Sync gathers
located backing onto that hotkey when a balance clears the conservative movement
floor; sub-floor balances may stay behind while the fixed window runs. Completion collapses the record to
parking; abandoned dust needs explicit `recoverStray` sources later. While shares
remain, the position is then parked:

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
| Missing backing | The vault cannot locate enough alpha to satisfy its record. | Park it with `recoverStray`, or let `syncBacking` write off the difference after the window. |

They can occur together. An attested entry with no usable hotkey blocks allocation
even while backing is intact.

## Watcher runbook

1. Monitor current registry entries, recorded/resolved stake hotkeys and their
   owner records, backing status and `awaitingAttestation`. Include empty
   entries and newly attested hotkeys with no recorded slot. If the vault
   resolves a successor after a swap,
   call `syncBacking(tokenId)` before the old hotkey is re-registered to record it.
   Watch the chain's hotkey swap events for attested and recorded hotkeys. After
   a swap from either, or a lost or changed owner record on a recorded hotkey,
   publish the validator's current hotkey at once: until then an emptied slot can
   re-stake under a hotkey the validator left, idle or held by a stranger.
   When several validators of one set swapped, publish all their current hotkeys
   in one update: with two slots on each other's piles, a set naming only one of
   them makes wraps, alpha exits and rebalances revert `SwappedHotkeyStillAttested`.
2. For missing backing, call `syncBacking(tokenId)`. It secures all located
   backing on `parkingHotkey` before starting one fixed recovery window, except
   below-floor piles. Other collection failures revert.
3. After sync declares the loss, run `scripts/find_strays.py`: it lists every
   hotkey the clone stakes under that the record does not name, largest pile
   first, and with `--recover` calls `recoverStray(tokenId, source)` for each in
   that order, so a pile parked by one call carries the smaller ones home.
   Finds reduce the pooled deficit without validator attribution.
   `missingStake(tokenId)` reports unlocated alpha;
   dust at recorded hotkeys reduces that amount and is written off when it is too small to park.
4. While recovery is open, priced calls refuse. Further syncs collect
   returns at recorded locations. The deadline stays fixed through partial recovery.
   At expiry, sync collects returns before writing off the remaining deficit.
   After collecting full coverage, call sync again to finalize recovery.
   Full recovery or write-off leaves the position parked unless no shares remain. Alpha recovered later
   belongs to the holders at that time.
5. After completion with shares outstanding, registry governance publishes a newer set even if all backing returned.
   Remove any lost or captured hotkey and publish the intended successor. The next wrap,
   alpha exit or `rebalance(netuid)` releases the parked position onto it.
6. The lens's `stakingListEntries(tokenId)` reports the clone's staking list. From
   128 entries, half the chain's cap, anyone can call `replaceClone(tokenId, uid)`
   with a fresh random UID; `StakingListFull` on any call means the same. The
   position, its TAO and the token id move to a fresh clone; piles below the
   floor stay on the old clone.

`syncBacking` and `recoverStray` are permissionless. Declaration cost grows with
the number of located hotkeys: simulate the call and budget above the estimate.
Keep funds for retries when a chain restriction blocks collection.

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
registry attestation arrives. A cut or redirected successor edge is resolved
through the clone's staking list. If backing goes short, call `syncBacking(tokenId)`, run
`scripts/find_strays.py --recover`, then `syncBacking(tokenId)` before write-off.

A revert preserves shares and stake, but costs gas. A finalized write-off really
reduces holders' accounted backing; alpha recovered later belongs to holders at
recovery time. Watcher and registry authority availability are therefore liveness
dependencies, and recovery before write-off matters financially. See the
[late-recovery risk](security-model.md#recovery-window-tradeoff-and-late-recovery-attack).

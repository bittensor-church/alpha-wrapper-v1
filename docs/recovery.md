# Recovery

## Hotkey swaps

A validator hotkey swap that carries its stake moves the vault's alpha to the new
hotkey, still under the clone's coldkey. The vault finds it there by itself, so
wraps, exits, rebalances and quotes keep working and the backing stays whole. The
registry owner then publishes the validator's new hotkey; the
[accepted risks](security-model.md#other-accepted-risks) list what can happen
until then.

## Missing backing

The vault cannot account for a slot after a sweep, a pile split across hotkeys, a
pile under hotkey 0x0, two slots merged onto one hotkey, or a pile found under a
hotkey the registry attests for another slot. Wraps, rebalances, exits and quotes
then revert `BackingShortfall` until `syncBacking` runs; see the
[runbook](#watcher-runbook). One shortfall clock covers the whole token.

## Parked positions

Recovery ends with the backing on the parking hotkey, which the vault owns for
good. While shares remain, the position is parked:

- Deposits and weight alignment wait for an attestation newer than the one in
  force when the position parked.
- Alpha exits pay from the parking hotkey; the alpha arrives delegated to it and
  the holder moves it to a validator with their own `moveStake`.
- TAO exits sell from the parking hotkey. Share transfers and TAO claims work.
- Emissions resume once the position is released.

The first wrap, rebalance or alpha exit after a newer attestation moves the
parked alpha onto the attested set and clears the parked state. Re-publishing
the same set under a new nonce releases the position too. One parking hotkey
serves every subnet, and each position parks and releases on its own.

## Watcher runbook

1. Watch the registry's sets, the chain's hotkey swap events for attested and
   recorded hotkeys, backing status and `awaitingAttestation`. After a swap,
   publish the validator's current hotkey at once. When several validators of one
   set swapped, publish all their current hotkeys in one update: a set naming
   only some of them can make wraps, alpha exits and rebalances revert
   `SwappedHotkeyStillAttested`. `AttestedHotkeyRetired` means a slot has no
   hotkey with an owner record to stake under; it blocks wraps, rebalances and
   partial alpha exits until the registry publishes a set without that attested
   hotkey.
2. For missing backing, call `syncBacking(tokenId)`. It secures all located
   backing on `parkingHotkey`, except below-floor piles. If that covers the
   record, the position parks in the same call; otherwise one fixed recovery
   window starts. Other collection failures revert.
3. After sync declares the loss, run `scripts/find_strays.py`: it lists every
   hotkey the clone stakes under that the record does not name, largest pile
   first, and with `--recover` calls `recoverStray(tokenId, source)` for each in
   that order, so a pile parked by one call carries the smaller ones home.
   `missingStake(tokenId)` reports unlocated alpha.
4. While recovery is open, further syncs collect returns at recorded locations.
   The deadline stays fixed through partial recovery. At expiry, sync collects
   returns before writing off the remaining deficit. After collecting full
   coverage, call sync again to finalize recovery.
5. Once the position is parked, registry governance publishes a newer set, even
   if all backing returned. The next wrap, alpha exit or `rebalance(netuid)`
   releases the position onto it.
6. The lens's `stakingListEntries(tokenId)` reports the clone's staking list. From
   128 entries anyone can call `replaceClone(tokenId, uid)` with a fresh random
   UID; `StakingListFull` on any call means the same. The position, its TAO and
   the token id move to a fresh clone; piles below the floor and uncollected
   strays stay on the old clone, an [accepted risk](security-model.md#other-accepted-risks).
   Before the list reaches 128 entries, collect strays with
   `scripts/find_strays.py --recover`.

`syncBacking` and `recoverStray` are permissionless. Declaration cost grows with
the number of located hotkeys: simulate the call and budget above the estimate.
Keep funds for retries when a chain restriction blocks collection.

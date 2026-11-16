# Security model

## Authority and trust

- The vault is immutable, and only the vault drives its mailboxes and subnet
  clones.
- The registry owner's authority is limited to choosing validators and their
  weights. `PlaceholderValidatorRegistry` has one owner, one hotkey per subnet, and
  two-step ownership transfers.
- If the registry owner loses access, parked positions stay parked: deposits and
  rebalancing stay blocked, while exits remain available.
- A hostile validator set still harms holders: it steers emissions and can block
  transactions, and the TAO exit that ignores weights has its own constraints.

**Each integrator is responsible for choosing and governing its validator policy
and for assessing the resulting economic, legal, regulatory and liability risks
for its service and jurisdiction.**

Holders rely on:

- Subtensor behaving as the runtime the vault targets; see
  [runtime compatibility](deployment.md#runtime-compatibility).
- Registry governance publishing distinct hotkeys; a hotkey counted twice can
  overpay an exit.
- A funded, responsive watcher to park
  [missing backing](recovery.md#missing-backing), and an authorized registry
  update to release a parked position.
- Trusted vault and lens builds and addresses.

## Safeguards

- Each subnet registration's backing sits in its own clone.
- Only a mailbox's depositor can wrap its deposit.
- Stake-moving and payout entry points are non-reentrant.
- Virtual shares limit first-depositor inflation.
- Caller-chosen minimum outputs bound deposits and exits.
- Missing backing blocks pricing and exits until it is recovered or written off.
- Alpha exits avoid pool trades; TAO exits are opt-in market sales.
- Mailboxes and subnet clones are checked and protected at creation, so only
  unlocked alpha backs shares.
- A clone whose staking list strangers fill is replaced permissionlessly; token,
  shares and TAO claims carry over.

## Why clone contamination matters

A coldkey swap can plant locks and ownership roles on any account that holds no
stake, including a future mailbox or subnet clone. Locked alpha priced as
backing would let an attacker mint shares, exit with honest holders' unlocked
alpha and leave them the locked remainder.

Creation rejects a poisoned candidate, and the caller retries with a fresh UID;
accepted accounts are protected against later coldkey swaps. A lock that appears
anyway blocks wrapping from that mailbox, or stops that clone's pricing and
exits, until it clears. Front-running a
public UID only forces a retry.

## Recovery-window tradeoff and late-recovery attack

When alpha the record expects is still missing after `syncBacking` collects the
located backing, the sync parks that backing and starts one fixed recovery window.
Alpha still missing at expiry is written off: a real loss for holders at that
time, and anything recovered later belongs to whoever holds shares then. Balances
too small to move can be written off as well.

Anyone able to keep vault alpha
[where the vault does not locate it](recovery.md#missing-backing) and return
it later can exploit that policy:

1. Leave vault alpha where the vault does not locate it.
2. Let the write-off finalize if watchers miss the window.
3. Deposit against the reduced backing to acquire a larger share of the supply.
4. Return the hidden alpha, so the new shares take part in its recovery.

The original holders lose at most the hidden alpha and what it earned
meanwhile. Parking before write-off defeats the attack, which makes watcher
responsiveness a financial concern. After a write-off, deposits stay shut until
the registry is updated, and holders who keep their shares keep their claim on
later recovery until the clone is replaced.

## Other accepted risks

- Exits can fail temporarily while the watcher repairs chain state.
- A validator that swaps one attested hotkey onto another it owns merges two
  slots; the position reads short until one `syncBacking` parks it whole.
- Chain minimums and rounding can require top-ups or combining shares, and a
  full TAO exit may discard a small unsold residue.
- A TAO exit's price impact falls partly on remaining holders.
- A parked position earns emissions again only after a new validator set is
  published and the next wrap, rebalance or alpha exit releases it.
- After a validator swap, stake can sit idle under the old hotkey until the
  registry publishes the successor.
- A stranger who claims a vacated validator hotkey, attested or one the vault
  followed a swap onto, can receive an empty slot's allocations until the
  registry replaces the slot's attested hotkey. The stranger cannot take the
  principal.
- A slot whose alpha the vault finds on the clone's staking list stays under that
  hotkey, even a rotated-out validator, until a later registry set moves it.
- A hotkey the vault followed a swap onto keeps the slot after its validator
  registers the attested hotkey again; publishing that hotkey, or a swap from it
  onto the attested one, moves the slot.
- Two validators of one set that swap their hotkeys together can leave each slot
  on the other's pile: the total stays exact, and each validator holds the
  other's weight until the registry names both successors.
- Stake under a hotkey with no owner record moves only after the clone's owner
  contract claims that hotkey. Anyone paying the chain's hotkey-swap fee can
  block the claim by reserving the hotkey as a coldkey-swap destination, and a
  hotkey under the chain's hashed or post-quantum account schemes refuses it
  until an account of that scheme claims the hotkey.
- Alpha a clone holds on another subnet stays outside the backing.
- Whatever a clone replacement leaves on the old clone is lost for good: piles
  below the floor, strays and written-off alpha. Anyone holding enough alpha can
  push a pile below the floor by dumping the price around a replacement and so
  destroy it for holders, gaining nothing.

See [edge cases](edge-cases.md) for dissolution, transfer restrictions and minimums.

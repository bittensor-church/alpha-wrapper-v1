# Security model

## Authority and trust

The vault has no admin or upgrade path. Only it can drive its mailbox and subnet
clones. `BasicValidatorRegistry` has one owner choosing a single hotkey per subnet
at 100% weight. OpenZeppelin two-step ownership transfers require the nominated
successor to accept; the existing owner retains authority until then. Renunciation
is disabled. Downstream registries may supply different governance and weighted
sets through `IValidatorRegistry`.

The registry owner cannot directly withdraw backing, mint/burn users' shares,
access their mailboxes or change vault code.

If the `BasicValidatorRegistry` owner loses access without an accessible pending
successor, registry updates stop permanently. Parked positions cannot be released:
deposits and rebalancing remain blocked, though exits remain available. An
ownership transfer alone does not advance registry nonces; the new owner must
publish a validator update to release parking.

Registry choices affect emissions and transaction availability. The TAO exit
ignores registry weights, but cannot bypass source ownership, missing backing,
dissolution, chain minimums or pool constraints. A hostile set is not harmless
merely because that exit exists.

**Each integrator is responsible for choosing and governing its validator policy
and for assessing the resulting economic, legal, regulatory and liability risks
for its service and jurisdiction.**

Holders rely on:

- Subtensor and its precompiles for stake ownership, moves, accounting and refunds.
  Creation requires `getHotkeyOwner`, `getOwnedHotkeys`, `getColdkeyRoot`,
  `getColdkeyLock`, `getRejectLockedAlpha`, `getStakingHotkeys`,
  `setRejectStakingHotkeyGrowth`, `getRejectStakingHotkeyGrowth` and
  `tryAssociateHotkey`. The lineage and ownership readers must reflect current
  runtime storage; an unsupported runtime cannot prepare clones.
- Registry governance, validator performance and distinct hotkeys in each set.
  The vault does not reject duplicates; one key counted twice can overpay an exit.
- A funded, responsive watcher to repair unresolved swaps and park backing, and
  an authorized registry update to release a parked position. Watcher calls are
  permissionless; registry updates require authorization. Neither is guaranteed on-chain.
- Trusted vault/lens builds and addresses. The lens's `vault()` checks pairing,
  not authenticity.

## Safeguards

- Separate clones isolate each subnet registration's backing.
- Mailbox collection only credits its depositor; outsiders cannot collect it.
- Stake-moving and native-payout entry points are non-reentrant. Share changes
  checkpoint claimable TAO before recipient acceptance callbacks.
- Virtual shares/assets limit first-depositor inflation; a supply cap protects
  claim-index precision.
- Caller-selected minimum outputs make insufficient fills revert atomically.
- Unresolved backing blocks live pricing and exits until the position parks or
  the loss is written off; recovery moves only the vault's own stake, onto a
  hotkey only the vault's coldkey controls.
- A receiving key needs an owner record; the vault does not check whose. The
  registry owner replaces a name that answers to a stranger.
- Alpha exits avoid pool trades. TAO exits are opt-in market sales with fees and
  price impact, including price impact borne by remaining holders.
- Mailboxes and subnet clones are checked and protected at creation, so locked
  alpha never backs a share.
- Mailboxes and subnet clones refuse staking-list growth by others, and deposits
  land only on hotkeys the chain admits whatever a stranger has done to the list.

## Why clone contamination matters

A coldkey swap can plant locks, account settings and ownership roles on any
account that stakes nothing, including a future mailbox or subnet clone, without
its consent. A poisoned mailbox blocks its user's deposit. Locked alpha priced
as backing would let an attacker mint shares and exit with honest holders'
unlocked alpha, leaving them alpha that neither exit can move.

- Creation checks the candidate chosen by the caller's UID for ownership,
  swap history, locks and staking-list entries, rejects a poisoned one so the
  caller retries with a fresh UID, then makes the account a hotkey: a mailbox
  claims its own, a throwaway owner contract claims a subnet clone's. The chain refuses coldkey
  swaps into existing hotkeys, so the protection holds at zero stake, and no
  clone has a function that could rename or hand over that hotkey. Creation
  also verifies that the clone rejects locked-alpha transfers and staking-list
  growth by others.
- An unexpected lock fails closed: a locked mailbox cannot be wrapped, and a
  locked subnet clone stops prices, deposits, alignment and exits until the lock
  clears. Recovery reads and accrued TAO claims stay available.

The cost is one creation transaction per user; the first user of a subnet
generation also pays for the shared clone. A UID is public once submitted, so a
front-run creation can fail and need a retry with a new UID. TAO donations
remain allowed; alpha donations only onto a hotkey the clone already lists.

## Why a subnet clone owns no hotkey

The chain hands a subnet to the coldkey that owns its most convicted hotkey and
locks the owner's cut onto that coldkey every epoch. A subnet clone owning a
hotkey could be made subnet owner that way and frozen by the lock. A contract
deployed with each subnet clone owns its account as a hotkey instead, which
still refuses coldkey swaps into it, and the clone owns nothing. Mailboxes keep owning their
account: a hijacked mailbox blocks one user's wrap on one subnet and the alpha
stays reclaimable. The vault's coldkey may be made subnet owner through the
hotkeys it holds; nothing reads its locks or stake.

## Staking lists

The chain keeps, for every coldkey, the list of hotkeys it stakes under: at most
256 entries through the coldkey's own moves, at most 128 through stake sent by
others, and a listed hotkey is always admitted. An entry stays while the coldkey
holds stake under that hotkey on any subnet or a root-dividend record for the
pair.

- Every clone and the vault refuse growth by others from creation on. A deposit
  takes the one route the chain always admits: the mailbox's own hotkey, then a
  hotkey the clone already lists, then the chosen validator.
- A crumb a stranger sends under a listed validator keeps that validator listed
  after a rotation, and nothing the vault can call frees the entry, so a clone's
  list fills by one entry per validator the registry has ever used.
- Owning a hotkey costs its owner an entry for good, so a throwaway contract
  owns each subnet clone's hotkey and the vault's own list holds the parking
  hotkey alone.
- A clone's own moves keep the last entry for the parking hotkey, so recovery
  can always park. A deposit or rotation onto a hotkey the clone cannot take
  reverts `StakingListFull`; an alignment move the list refuses is skipped, so
  exits do not wait on the list.
- Once the list has fewer free entries than the attested set plus parking,
  anyone calls `replaceClone(tokenId, uid)`: a fresh clone and owner take over
  the recorded backing and the TAO under the same hotkeys, and the token keeps
  its id, shares and claims. Piles below the floor, TAO below the chain's
  existential deposit and the crumbs stay on the old clone.
- A single-subnet swap of a validator carrying such a crumb leaves the clone's
  stake on the old name. The vault handles it as a swap that kept the stake.

## Recovery-window tradeoff and late-recovery attack

The [hotkey-swap runbook](hotkey-swaps.md) separates two failures: names with
no usable key and unlocated alpha. A registry update repairs the first.
`syncBacking` handles the second: it moves all located backing onto the vault's
parking hotkey before starting one fixed recovery window, with a dust exception:
if even the richest source or parking balance is below the conservative movement
floor, collection leaves those balances in place without delaying the window.
Every sync retries collection before write-off, so a larger return or price rise
can bring the dust home. Other collection failures revert without changing the
clock or obligation; persistent chain restrictions can still delay recovery.
A native precompile refusal consumes forwarded gas, even though state rolls back.

The conservative floor uses `DefaultMinStake`: 0.002 TAO on Subtensor runtime 481,
20 times its 0.0001 TAO same-subnet transfer minimum. Thus some chain-movable
balances can be skipped and written off. Ten skipped locations expose less than
0.02 TAO at the floor check's price, not at a future price. Using the lower
transfer minimum is a separate compatibility change.

Recovery counts one expected total and one pool of located alpha, without assigning
finds to validators. After sync declares a loss, `recoverStray(tokenId, source)`
parks one source per call. Only sync finalizes recovery, collecting returns at
recorded locations first. Neither call extends the clock.
Validator swaps cannot move the secured balance off the vault-owned parking hotkey.
At expiry, sync collects returns before writing off the remaining deficit,
including any dust still outside parking. The dust exposure is per skipped
location, valued at the floor check's price; it is not a bound on future alpha
value. A movable pile gathers smaller balances too. Late dust recovery requires
explicit source keys and belongs to holders at that later time.
Full recovery or write-off leaves the position parked pending a newer registry update, unless no shares remain.

Write-off chooses repricing over indefinite waiting for missing alpha. It is a
real loss of accounted backing for holders at finalization, not proof the alpha
was destroyed. Any later recovery belongs to whoever holds shares then.

A validator can exploit that policy:

1. Swap its hotkey, carrying vault alpha, then re-register the old key on the
   subnet to erase the successor edge.
2. If watchers cannot park the funded key in time, finalize the write-off.
3. Once the registry authority publishes again, deposit against the reduced backing to
   acquire a larger share of the supply.
4. Reveal/recover the hidden alpha, or have a later registry update and settlement
   count it. The new shares now participate in that recovery.

For hidden principal `H` with no growth, the original holders' aggregate loss
from this ordering is bounded by `H`: it reallocates the late recovery, rather
than also extracting another `H` from located backing. Emissions or surplus on
the hidden key can make the later windfall exceed the `BackingWrittenOff` amount.
After write-off, deposits stay shut while shares remain until the registry is
updated. A full exit to zero supply also clears parking and reopens deposits;
no shares remain to dilute.

This is accepted policy and a reason to park before write-off. Afterward,
neither `recoverStray` nor a new registry update reconstructs the old holders' claims.
Following a complete write-off, a zero-floor `unwrap` voluntarily burns worthless
shares and gives up their claim on future recovery. A positive floor preserves
them; accrued TAO survives either way.

## Other accepted limits

- Watcher-assisted recovery permits temporary exit failures, including with intact
  backing. The contract does not skip required alpha-exit alignment to avoid them.
- Stake minimums and rounding can require top-ups or combining shares. A full
  TAO exit may discard sub-floor unsold residue.
- Partial TAO exits can refund unsold alpha as shares; `minTaoOut` bounds the payout,
  not the pool-price effect on remaining holders.
- A parked position earns no emissions until the registry authority publishes a new set.
  A validator can swap and re-register its old key to cut a successor edge the
  vault still needs. After an all-subnet swap, anyone paying the burn can register
  that ownerless key on the affected token's subnet if registration is open; see the
  [watcher runbook](hotkey-swaps.md#watcher-runbook).
- A name swapped on one subnet keeps its owner, and a name the vault claimed to
  move stake off gains one, so an emptied slot re-stakes under it and earns
  nothing there until the registry owner publishes the successor; see the
  [watcher runbook](hotkey-swaps.md#watcher-runbook).
- Clone protection relies on the chain refusing coldkey swaps into existing
  hotkeys, rejecting locked-alpha transfers by default and honouring the
  reject-growth flag. A public UID can be front-run into a retry; a poisoned
  candidate never becomes backing.
- The parking hotkey and every ownerless name the vault restores an owner to,
  so it can move stake off it, stay on the vault's own staking list, which the
  chain caps at 256. Stake sent to the vault's address before deployment stays
  there too, at most the 128 entries others may add, which leaves 127 for
  restored names; refusing to deploy over such entries would let a griefer dust
  every retry instead.
- A replacement can be front-run like a creation: a crumb on the predicted
  successor or owner makes it revert `CloneContaminated`, and the caller retries
  with a fresh UID while the griefer pays about 0.0001 TAO plus a fee per attempt.
- Alpha a clone holds on another subnet is not backing and stays there. A
  replaced clone keeps it, along with recorded piles below the floor and
  anything that arrives later.
- A vacated attested name that a stranger claims receives an empty slot's
  allocation until the registry owner publishes the successor. The alpha stays
  under the vault's coldkey; if the stranger moves it, it is recovered as
  missing backing.

See [edge cases](edge-cases.md) for dissolution, transfer restrictions and minimums.

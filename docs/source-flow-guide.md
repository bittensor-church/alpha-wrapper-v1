# Alpha Wrapper: following the flow

A short guide to the wrapper's control flow.

## What lives where

```text
User's stake -> personal DepositMailbox -> shared SubnetClone
                         wrap                  |
                                              +-> alpha delegated to hotkeys
                                              +-> native TAO balance

AlphaVault: shares and accounting     IValidatorRegistry: target hotkeys and weights
```

## Why there are several kinds of hotkey

The registry attests a validator hotkey, but a hotkey swap can move its stake elsewhere.

- `logical`: the attested hotkey the slot was recorded under; `attestedOf` reads it.
- `active`: the last recorded location of its stake.
- `tracked`: the alpha expected at the last record update.
- `Backing.hotkeys`: locations resolved now, after following one swap or finding the
  slot's alpha on the clone's staking list.

Example: after a swap from A to B, the record can say `logical = A, active = B`.
Locating backing and choosing a receiver are separate checks: a receiving hotkey
must also have an owner record.

## The lifecycle

```text
Missing backing -> syncBacking secures located backing -> fixed recovery window
                       |
                       +-> recoverStray(source) -> collect into parking; window stays open
                       +-> full coverage + sync -> collect returns; recovery complete; parked
                       +-> expiry + sync -> collect returns; write off deficit; parked

Parked -> newer registry update -> next wrap/rebalance/alpha exit can
                                       apply the set and clear parked state
Parked -> live alpha or TAO exit leaves no shares -> parked state cleared
```

A detected shortfall blocks ordinary live deposits and exits. Collection must
succeed before the clock starts, except when every available pile is below the
conservative floor. Such dust can remain outside parking and be written off;
other move failures still revert. One pooled obligation replaces validator-specific
expectations during recovery; the deadline stays fixed through partial finds.
A write-off takes a sync after expiry.

Parking blocks deposits and rebalancing until a newer registry update. Exits can use
parked backing, subject to execution checks. Transfers and accrued TAO claims
remain separate. Dissolution takes another path: exits wait through applicable
cleanup, then old shares redeem the clone's unreserved TAO.

## Follow a transaction

- **`createMailbox`:** resolve the live generation -> check the candidates -> deploy
  any missing subnet clone and personal mailbox -> make each a hotkey (the mailbox
  claims its own, a throwaway owner contract claims the clone's) refusing staking-list growth ->
  verify -> publish accepted addresses. All steps are atomic.
- **`replaceClone`:** require a prepared, live clone with transfers enabled -> check backing ->
  require a list at least half full ->
  deploy a fresh clone and owner -> lift the successor's growth flag -> transfer each recorded
  pile at or above the floor under its own hotkey -> restore the flag -> move the TAO balance ->
  point the token at the successor -> re-read balances into the record.
- **`wrap`:** require prepared addresses -> check backing, receivers and that the mailbox holds no lock ->
  land the mailbox's own-hotkey stake on a hotkey the clone lists, lifting the growth
  flag for the transfer when it lists nothing, then move it onto the chosen registry
  hotkey -> consolidate dropped hotkeys -> align weights ->
  record actual balances -> calculate and mint shares. Collecting first lets a
  fresh deposit help move old dust; pricing uses the balances after movement.
- **Live `unwrap`:** check backing -> select destinations -> consolidate dropped
  hotkeys -> price and burn shares -> gather and transfer staked alpha -> align the
  remainder -> update records. Check the recipient's actual credit against the
  minimum. A parked exit uses its recorded locations and skips weight alignment.
- **`unwrapForTao`:** check backing -> budget alpha and burn shares -> sell whole
  slots before partials -> measure proceeds and remaining alpha -> refund eligible
  unsold alpha as shares with proceeds reserved -> pay TAO.
- **Dissolved `unwrap`:** exclude reserved TAO claims -> calculate a proportional
  refund -> burn shares -> pay native TAO. The caller must pass zero for `minAlphaOut`.

Start tracing in `AlphaVault`. `VaultAllocation` resolves hotkeys and moves stake. For recovery details, use the [runbook](hotkey-swaps.md).

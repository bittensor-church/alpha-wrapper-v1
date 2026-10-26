# User guide

Use an EVM account on Bittensor with TAO for gas. Send transactions to the vault
and read quotes from its `AlphaVaultLens`; check that the lens's `vault()`
matches your vault. See [How it works](overview.md) for the contract layout.

Alpha amounts use 9 decimals (RAO); native TAO amounts, including `minTaoOut`,
use 18-decimal EVM wei.

## Wrap staked alpha

1. Call `createMailbox(netuid, uid)` with a fresh random `bytes32` UID. If it
   reverts `CloneContaminated`, retry with a new UID.
2. Read `getDepositAddress(you, netuid)` and convert it to its Substrate coldkey
   with `addressMapping(address)` at `0x080C`.
3. Send alpha to that coldkey with Subtensor's `transfer_stake_and_hotkey`,
   using the same id as the destination hotkey.
4. Choose a hotkey from `getValidators(netuid)` on `vault.validatorRegistry()`.
5. Call `wrap(netuid, chosenHotkey, minSharesOut)` from the account that created
   the mailbox. Size `minSharesOut` with `previewWrap(tokenId, assets)`.

After a netuid is recycled, call `createMailbox` again before wrapping.

- `DepositTooSmall`: top up the mailbox and retry.
- `LockedDeposit`: reclaim the alpha with `reclaimAlphaFromMailbox` to a coldkey
  that accepts locked alpha.
- `StakingListFull`: anyone can call `replaceClone(tokenId, uid)` with a fresh
  random UID, then retry. Token id, shares and TAO claims carry over. The lens's
  `stakingListEntries(tokenId)` shows the list; replacement opens once it holds
  128 entries, half the chain's cap.

## Shares and exits

Shares transfer as ERC-1155 balances. Keep the token id from `Deposited`.
`sharePrice(tokenId)` is alpha per share scaled by 1e18; `previewUnwrap(tokenId,
shares)` quotes a specific burn. The lens's `totalStake(tokenId)` and
`resolvedBacking(tokenId)` show the position's backing.

### Staked alpha: the default exit

Call `unwrap(tokenId, shares, yourColdkey, minAlphaOut)` and verify the
destination coldkey. Size `minAlphaOut` from `previewUnwrap`; use at least `1`,
since zero also accepts burning shares for nothing after a complete write-off.

### Native TAO: market sale

Call `unwrapForTao(tokenId, shares, minTaoOut)`. It sells the backing in the pool
and pays your EVM account; fees and price impact reduce proceeds. Unsold alpha
is refunded as shares. Prefer the alpha exit when available.

A slot the pool will not pay for makes the call fail.
`unwrapForTao(tokenId, shares, minTaoOut, excludedSlots)` skips the slots set in
the mask (bit `i` is slot `i` of `recordedSlots(tokenId)`) and refunds their
share as shares. `scripts/plan_tao_exit.py` finds those slots and dry-runs the
call.

Small holders may need a top-up or combined shares to clear the chain's
minimums.

### Dissolved subnet

After cleanup, `unwrap(tokenId, shares, anything, 0)` pays your share of the
clone's TAO refund, quoted by `previewUnwrap`. See
[dissolution](edge-cases.md#subnet-dissolution).

## Recovery status

`BackingShortfall` or `ShortfallOnFile` means expected alpha is missing; wraps,
rebalances, exits and quotes wait until it is recovered or written off. Shares
still transfer and accrued TAO stays claimable. The lens reports
`missingStake(tokenId)`, `isBackingIntact(tokenId)` and
`writeOffDeadline(tokenId)`.

`awaitingAttestation(tokenId)` reports a parked position. It pays alpha exits
from the parking hotkey, so move the received alpha to a validator with
`moveStake` to earn emissions. Deposits wait for a new validator set. See the
[watcher runbook](hotkey-swaps.md).

## Claim TAO and reclaim deposits

TAO a live clone receives outside exits is shared among holders: read
`claimableTaoOf(you, tokenId)` and collect it with `claimTao(tokenId,
recipient)`.

Mailbox recovery acts on your own mailbox:

- `reclaimAlphaFromMailbox(netuid, destColdkey)`: return the deposit to a coldkey.
- `reclaimMailboxAlphaAsTao(netuid, minTaoOut)`: sell it for native TAO.
- `reclaimTaoFromMailbox(netuid)`: collect native TAO, including dissolution refunds.

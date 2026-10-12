# Test design

Test through supported public interfaces. Expected values are literals derived by
hand, never computed with production arithmetic or read from the lens: such checks
repeat the same bug on both sides. Public reads such as `recordedSlots()` are valid
observations.

Fixtures use chain-valid values: alpha positions of 1-100,000 alpha, a default price
of 0.05 TAO per alpha, and TAO credited at `1e9` wei per RAO. The mocks reproduce the
chain rules the vault depends on: u64 stake, subnet, dissolution and transfer checks,
chain minimums, sale simulation and the pool's minimum price, the nominator sweep
(which deletes a remainder it cannot sell), and refusals that return no data and
consume the forwarded gas (`_expectChainRefusal`).

The invariant suites prove different things:

- **Alpha accounting:** exact conservation of deposited and emitted alpha under a
  moving price, and each deposit and exit converted at the holder's exact share.
  Every holder must exit, but top-ups satisfy the stake minimums. This does not
  prove small positions can always exit unaided.
- **Claimable TAO:** entitlements come from an independent ledger of donations and
  holder balances. Cash conservation is exact; entitlement comparisons allow
  bounded rounding.
- **Backing:** recovery and coverage under hotkey swaps, strays and write-offs, and
  the lens never reporting more backing than the chain holds.
- **Hotkey swap:** stake follows renamed, reused and coldkey-swapped validator keys.

Handlers fail on any revert outside the business errors their entry point documents,
including panics and refused chain calls. In the backing campaigns each allowed error
must also be justified by the state it met, read from the chain mock. Fixed handler
sequences live in the
`*CampaignPathsTest` unit contracts. Alpha exit residue is bounded per mint or exit,
since repeated conversions accumulate rounding loss; that residue still counts in
exact conservation.

Gas snapshots include fuzz tests, so CI fuzzes a fixed input stream: a pinned seed, no
dictionary values and two threads. Regenerate after `forge clean` with
`FOUNDRY_PROFILE=ci forge snapshot --fuzz-seed 0x1 --threads 2 --no-match-contract Invariant`;
`forge snapshot` ignores the configured seed without the flag. Locally the default
profile fuzzes with a random seed and dictionary values. Repeated-ID and distinct-ID
batch cases stay separate to expose the effect of warm reads.

E2E revert checks require a mined failed receipt. RPC or command failures are setup
failures, not evidence that the contract rejected a transaction.

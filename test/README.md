# Test design

Test through supported public interfaces. Expected values are literals derived by
hand, never computed with production arithmetic or read from the lens: such checks
repeat the same bug on both sides. Public reads such as `recordedSlots()` are valid
observations.

Fixtures use chain-valid values: alpha positions of 1-100,000 alpha, a default price
of 0.05 TAO per alpha, and TAO credited at `1e9` wei per RAO. The mocks reproduce the
chain rules the vault depends on: u64 stake, subnet and transfer checks, chain
minimums, the nominator sweep, and refusals that return no data and consume the
forwarded gas (`_expectChainRefusal`).

The invariant suites prove different things:

- **Alpha accounting:** exact conservation of deposited and emitted alpha under a
  moving price. Every holder must exit, but top-ups satisfy the stake minimums. This
  does not prove small positions can always exit unaided.
- **Claimable TAO:** entitlements come from an independent ledger of donations and
  holder balances. Cash conservation is exact; entitlement comparisons allow
  bounded rounding.
- **Backing:** recovery and coverage under hotkey swaps, strays and write-offs.
- **Hotkey swap:** stake follows renamed, reused and coldkey-swapped validator keys.

Handlers fail on any revert outside the business errors their entry point documents,
including panics and refused chain calls. Fixed handler sequences live in the
`*CampaignPathsTest` unit contracts. Alpha exit residue is bounded per mint or exit,
since repeated conversions accumulate rounding loss; that residue still counts in
exact conservation.

Gas snapshots include fuzz tests; CI pins the fuzz seed, dictionary weight and thread
count so they are reproducible. Repeated-ID and distinct-ID batch cases stay separate
to expose the effect of warm reads.

E2E revert checks require a mined failed receipt. RPC or command failures are setup
failures, not evidence that the contract rejected a transaction.

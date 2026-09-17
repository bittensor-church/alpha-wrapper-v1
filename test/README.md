# Test design

Test through supported public interfaces. Do not expose internal libraries with
test-only shims or use production arithmetic for expected values: those checks
can repeat the same bug on both sides. Public reads such as `recordedSlots()`
are valid observations.

The invariant suites prove different things:

- **Alpha accounting:** exact conservation under healthy conditions. Every holder
  must exit, but top-ups satisfy the mocked stake minimums. This does not prove
  small positions can always exit unaided.
- **Claimable TAO:** entitlements come from an independent ledger of donations
  and holder balances. Reserve bounds alone would miss underpayments. Cash
  conservation is exact; entitlement comparisons allow bounded rounding.
- **Backing:** recovery and coverage checks under faults. Expected refusals are
  allowed, so this suite cannot establish conservation or exit liveness.

Unexpected handler reverts fail all three suites. Alpha exit residue is bounded
per mint or exit, since repeated conversions accumulate rounding loss; that
residue still counts in exact conservation.

Some arithmetic fixtures use one wei per TAO RAO. Accounting campaigns use the
chain's `1e9` scale; E2E scenarios check actual precompile behavior. Mocks control
observable responses rather than reproduce the chain.

Only deterministic tests enter gas snapshots; sampled fuzz and invariant gas
varies. Repeated-ID and distinct-ID batch cases stay separate to expose the
effect of warm reads.

E2E revert checks require a mined failed receipt. RPC or command failures are
setup failures, not evidence that the contract rejected a transaction.

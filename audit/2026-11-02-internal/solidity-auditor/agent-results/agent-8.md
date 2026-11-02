## Agent 8 — asymmetry

No FINDING. Three LEADs.

Storage lifecycle diffed across all writers — mirrored. Cross-coldkey reservation of clone/mailbox refused by chain (NewColdKeyIsHotkey, swap_coldkey.rs:564).

LEAD | contract: VaultAllocation | function: replaceClone | bug_class: over-restrictive-floor-abandons-stake
asymmetry: vault refuses to flush a slot worth below DefaultMinStake (2_000_000 RAO, runtime/src/lib.rs:953) while the chain moves any same-subnet transfer worth >= DefaultMinTransfer (100_000 RAO, lib.rs:954; stake_utils.rs:1476-1479; DefaultMinStake only on cross-netuid path stake_utils.rs:1998-2009). After the skip, _reanchor writes tracked = 0 for that slot so the pile leaves the record.
code_smells: `if (balances[i] != 0 && !StakeOps.isBelowFloorAtReadPrice(balances[i], context.alphaPriceE18)) flush(...)`; then `_reanchor(tokenId, backing.hotkeys, fetchBalances(..., successor))`.
description: Any caller of replaceClone makes holders lose each slot worth between 0.0001 and 0.002 TAO, although the chain can move it. Frequency not quantified.

LEAD | contract: AlphaVault | function: replaceClone | bug_class: permissionless-replace-strands-unrecorded-alpha
asymmetry: replaceClone copies recorded slots and all TAO; vault alpha under unrecorded hotkeys of the old clone has no path back: recoverStray resolves coldkeyOf(subnetClone[tokenId]) only; no vault entry point for a retired clone.
description: Any caller can run replaceClone before the watcher recovers strays, so vault alpha on unrecorded hotkeys of the old clone becomes unreachable. 128-entry precondition needs validator-side swap splits; outsider reachability not shown. (Same as agent-5 LEAD stranded-alpha-on-replaced-clone.)

LEAD | contract: AlphaVault | function: recoverStray | bug_class: missing-retired-hotkey-guard
asymmetry: wrap/rebalance refuse to route stake to an attested hotkey without owner record (AttestedHotkeyRetired); recoverStray no-shortfall branch moves the stray onto slot 0's resolved hotkey through StakeOps.move → moveAdmitted → ensureHotkeyHasOwner(toHotkey), making the vault claim that hotkey (helpers.rs:128-160, appends to vault's StakingHotkeys). Next assignActives sees funded slot with hasOwner == true, retired clears, later wraps allocate to a hotkey no validator runs.
code_smells: `bytes32 home = hotkeys[0];` chosen without hasOwner(home).
description: Any caller of recoverStray can turn a retired slot-0 hotkey into a vault-owned receiving hotkey, so later wraps park alpha where no validator earns. Docs describe the claim policy for moves off such a hotkey; not proven worse than documented idle slot.

Cleared: share math symmetry; TAO index symmetry; recovery lifecycle; collectDeposit landing/flag dance; admitsMove parking reserve; _rollRotatedStake home re-add under cap; unwrapForTao underflow guards.

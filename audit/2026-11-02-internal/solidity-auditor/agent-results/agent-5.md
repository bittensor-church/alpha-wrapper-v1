## Agent 5 — invariant

No FINDING. Three LEADs.

Invariants held under traces: share pricing rounds against caller, preStake after settlement, same-subnet moves conserve exactly (stake_utils.rs:1434-1461); TAO index liability ceil ≤ newTao, temp liability bump keeps sale proceeds out of index; unwrapForTao sold underflow guard, _sellableChunk conservative vs chain sweep (helpers.rs:253-259), full-burn refund ≤ 1.8e28 << SUPPLY_CAP; slot uniqueness guarded at every write site, same-coldkey merge yields conservative BackingShortfall; recovery state machine {0,0}→{ts,0}→{0,nonce}→{0,0} no path writes both; staking list caps 256 own / 128 third-party opt-out (stake_utils.rs:1570-1588), admitsMove reserves parking entry; dissolution: netuid stays in DissolveCleanupQueue until all phases complete (dissolution.rs:661-713), TAO credited in phase 2.2 before NetworkRegisteredAt removed in 5.2, blackout covers whole refund; zero-supply leftovers go to next depositor (documented).

LEAD | contract: AlphaVault | function: replaceClone | bug_class: stranded-alpha-on-replaced-clone
code_smells: VaultAllocation.replaceClone flushes only backing.hotkeys (recorded slots) to the successor; subnetClone[tokenId] = successor is the only pointer kept; recoverStray reads subnetClone[tokenId] and coldkeyOf(clone), so alpha under the old clone's coldkey on an unrecorded hotkey can never be addressed again; docs document this only for sub-floor piles.
description: After a write-off, any caller can run replaceClone and the vault loses every path to above-floor alpha that still sits under the old clone on an unrecorded hotkey. Precondition (128 list entries) and no attacker gain keep this a lead.

LEAD | contract: AlphaVault | function: _unwrapFromLiveSubnet | bug_class: third-party-blocks-swap-follow
code_smells: hotkey_swap_stake_can_follow (stake_utils.rs:1548-1566) retains a delegator's stake on the old hotkey when hotkey_swap_needs_split is true, which fires when the coldkey holds alpha under the same hotkey on another subnet (stake_utils.rs:1532-1540). ensure_third_party_staking_hotkeys_can_grow lets any third party transfer_stake into the clone on an already-listed hotkey with a different destination netuid. Clone rejects growth, so a later per-subnet swap leaves the vault's stake on the retired hotkey; assignActives keeps a funded slot on it and hotkeySuccessor points away.
description: A third party can plant cross-subnet alpha on a listed hotkey, so a validator's per-subnet swap leaves the vault's stake idle on the old hotkey. Alpha stays under the clone; unverified whether worse than documented "stake can sit idle until the registry publishes the successor". (Same root mechanism as agent-2 FINDING retained-staker-ownerless-hotkey-freeze.)

LEAD | contract: AlphaVault | function: claimTao | bug_class: existential-deposit-dust-breaks-liability-cover
code_smells: taoLiability = liability - amount assumes clone.balance drops by exactly amount; ED 500 RAO (runtime/src/lib.rs:478). A payout leaving 0 < balance < 500 RAO is dusted, so clone.balance < taoLiability and remaining claimants' sendValue reverts for the whole claim.
description: A claim that leaves the clone below the chain's existential deposit removes the remainder, so the remaining claim of up to 500 RAO fails. Unverified: whether Subtensor's EVM native transfer uses the dusting path for contract accounts with sufficients.

Refuted: refund mint uncapped by SUPPLY_CAP; recoverStray round-trip through caller hotkey; coversTracked slack accumulation; duplicate actives via funded branch; garbage tokenId bits.

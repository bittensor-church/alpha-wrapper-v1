## Agent 10 — numerical-gap

Chain facts: same-subnet move conserves exactly, min is DefaultMinTransfer 100_000 RAO (stake_utils.rs:1480) not DefaultMinStake; clear_small_nomination_if_required only on remove paths; full unstake bypasses min; remove_stake caps at available and rejects zero (AmountTooLow, remove_stake.rs:72-81); same coldkey+hotkey+netuid move refused SameNetuid (stake_utils.rs:1948-1950); share pool debits exactly; getAlphaPrice floor(price·1e9); isSubnetDissolving = DissolveCleanupQueue membership until cleanup completes; reject-growth blocks only unlisted hotkeys; caps 128/256.

FINDING | contract: AlphaVault | function: _unwrapFromLiveSubnet | bug_class: duplicate-attested-hotkey-double-count
seam: boundary×invariant (repeated input entry × "Σ slot balances == clone backing")
precondition: registry returns the same hotkey in two entries. BasicValidatorRegistry cannot; any multi-validator IValidatorRegistry can; resolveValidators checks only length, cap and hotkeys.length == weights.length.
path: registry → resolveValidators accepts [V, V] weights [5000, 5000] → assignActives: i=0 ownSlot found+funded → actives[0]=V; i=1 indexOf(slotAttested, V) returns the same slot, funded branch has no contains(actives, hotkey) check → actives[1]=V → _settle writes two slots both tracking getStake(V) → totalAlpha = 2B → _unwrapFromLiveSubnet computes assets from 2B → _gatherAndFlush([V,V],[B,B]) with assets ≤ B takes no gather hop → requested = assets flushed from V.
proof: B = 1_000_000_000 RAO on V, supply S = 1e18, record [V(B), V(B)], totalAlpha = 2e9. Holder with s = 4e17 (40%): assetsFor(2e9, 1e18, 4e17) ≈ 799_999_200 RAO; fair ≈ 399_999_600. balances[0] = 1e9 ≥ assets so no gather; _flushMeasured transfers it. Remaining holders (60%) now back 200_000_800 RAO. deliverAndAlign sees [rem, rem] equal targets, no move; _settle rewrites [V(rem), V(rem)]; next minority holder repeats. With unequal weights _rebalanceStep calls moveStake(V → V) which the chain refuses SameNetuid and burns gas → wrap/unwrap/rebalance revert. unwrapForTao on the duplicate record sells slot 0 fully then requests removeStake(V, B) on slot 1 with live balance 0 → AmountTooLow → reverts.
description: A duplicate hotkey in the registry set makes the vault count its stake twice, so a minority holder withdraws twice their share.
fix: Reject a validator set with a repeated hotkey in resolveValidators.

LEAD | contract: VaultAllocation | function: _alignToWeights | bug_class: weights-sum-underflow
code_smells: targets[lastIndex] = total - assigned; never checks Σ weights == BPS_BASE. [10001, 1]: assigned > total → revert on every wrap, alpha unwrap and rebalance.
description: Weights that sum above 10000 make targets[lastIndex] underflow, so wrap, unwrap and rebalance revert until the registry publishes a new set. TAO exits still work.

LEAD | contract: AlphaVault | function: claimTao | bug_class: existential-deposit-liability-drift
code_smells: assumes clone.balance ≥ taoLiability; ED 500 RAO. Sequence: liability 1000 RAO (600/400); A claims 600 → clone keeps 400 → dusted → B's claim fails forever; next arrival backfills. Bounded 499 RAO per token.
description: A claim that leaves the clone below 500 RAO lets the chain remove the rest, so taoLiability exceeds the balance and one claimant cannot claim. Unconfirmed that pallet_balances dusts a contract account frontier keeps alive through sufficients.

LEAD | contract: AlphaVault | function: wrap | bug_class: write-off-recapitalization-reaches-supply-cap
code_smells: after a full write-off preStake = 0, so sharesFor(0, S, d) = d·(S + 1e9). S = 1e18, d = 1e9 → S' ≈ 1e27; second → 1e36; third → 1e45 = SUPPLY_CAP; fourth deposit reverts SupplyCapExceeded. With 1000-alpha deposits the token closes after two write-offs. Holders can still exit; tokenId cannot take deposits until the subnet re-registers. Not attacker-triggerable without real backing loss.
description: Each deposit after a full write-off multiplies supply by the deposit size, so three write-offs reach SUPPLY_CAP and close deposits for the token.

Sound: _unwrapForTao refund formula; _sellableChunk leftover bound; sold underflow guard; _rebalanceStep cached balances; _gatherAndFlush re-reads; TRACKED_SLACK_RAO only gates detection; syncAmounts ceil; _update double-id/self-transfer; admitsMove parking entry; dissolution blackout.

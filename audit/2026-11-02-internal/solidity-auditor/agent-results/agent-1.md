## Agent 1 — math-precision

No FINDING. Three LEADs.

Verified chain facts: same-subnet moveStake/transferStake/transferStakeAndHotkey conserve alpha exactly (stake_utils.rs:1434-1461); dust sweep exists only in do_remove_stake (helpers.rs:236-276), _sellableChunk leftover bound is conservative; validate_remove_stake requires amount_paid_out >= DefaultMinStake only when remainder nonzero (stake_utils.rs:1819-1830); DefaultMinStake=2_000_000 RAO, DefaultMinTransfer=100_000 RAO (runtime/src/lib.rs:953-954); getAlphaPrice returns floor(P*1e9)*1e9 (precompiles/src/alpha.rs:82-88) so ALPHA_PRICE_QUANTUM_E18 exact; SUPPLY_CAP guarantees indexIncrease>=1 per whole RAO; refundShares <= shares so cap cannot be breached by refunds.

LEAD | contract: VaultAllocation | function: _alignToWeights | bug_class: unchecked-weight-sum
code_smells: targets[lastIndex] = total - assigned; resolveValidators never checks Σ weights == BPS_BASE. weights [6000,6000,1], total 1_000_000 → assigned 1_200_000 > total → revert in wrap, rebalance, alpha unwrap. Σ < 10000 → last slot silently takes remainder.
description: A registry that publishes weights above 10000 basis points makes wrap, rebalance and alpha unwrap revert for that subnet. BasicValidatorRegistry emits one validator at 10000, so no caller reaches this today.
fix: Add `if (weightSum != VaultMath.BPS_BASE) revert ValidatorSetMalformed();` to VaultReads.resolveValidators.

LEAD | contract: AlphaVault | function: replaceClone | bug_class: sub-existential-deposit-transfer-all
code_smells: transferAllTao dispatches pallet_balances::transfer_all{keep_alive:false} (precompiles/src/balance_transfer.rs:130-142). ED = 500 RAO = 5e11 wei (runtime/src/lib.rs:480). Successor holds zero TAO; old-clone balance in 1..499 RAO may make replaceClone revert. Unverified: whether a contract account can hold sub-ED balance, whether zero-amount transfer_all succeeds.
description: replaceClone reverts while the old clone holds less TAO than the existential deposit, until someone sends TAO to it. The chain rules for that balance remain unverified.

LEAD | contract: AlphaVault | function: _unwrapForTao | bug_class: existential-deposit-reap-liability
code_smells: unwrapTao → Address.sendValue; EVM value transfers use transfer_allow_death. If clone.balance - taoOut < 500 RAO, DustRemoval takes the remainder and taoLiability > clone.balance; claimTao reverts for last claimant until new TAO arrives. Same exposure in claimTao. Loss bounded by 500 RAO per event.
description: A payout that leaves the clone under the existential deposit can lose up to 500 RAO of reserved claim TAO. Unverified: whether Subtensor reaps contract accounts that carry a sufficient reference.

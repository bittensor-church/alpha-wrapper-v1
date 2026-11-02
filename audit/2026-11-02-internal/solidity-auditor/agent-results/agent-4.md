## Agent 4 — execution-trace

No FINDING. Five LEADs.

Verified: transfer_stake_within_subnet debits exactly the requested alpha (stake_utils.rs:1402-1500), share pool zeroes a member on full withdrawal (share-pool/src/lib.rs:570-573, 625-720); no dust sweep on moves/transfers (clear_small_nomination_if_required only from do_remove_stake, remove_stake.rs:102/492); reject-growth blocks strangers from adding hotkeys (stake_utils.rs:1567-1584), swaps rename list entries in place (swap_hotkey.rs:689-706, 1133-1142); precompile selectors/tuple shapes match (staking.rs:1311, subnet.rs:1319-1341, staking.rs:590, alpha.rs:77-91); ERC1155 callbacks fire only after final state or inside the taoLiability guard.

LEAD | contract: CloneBase | function: unwrapTao | bug_class: existential-deposit-dust
code_smells: Address.sendValue pays claims; claimTao lowers taoLiability by same amount; ExistentialDeposit 500 rao (runtime/src/lib.rs:480); pallet_balances removes a remainder below it on mutation.
description: A claim that leaves the clone below 500 rao makes the chain remove the remainder, so taoLiability exceeds the balance and the last claimTao reverts. EVM value-transfer dust removal path unconfirmed; value at risk below 500 rao.

LEAD | contract: VaultAllocation | function: _alignToWeights | bug_class: unchecked-weight-sum
code_smells: targets[lastIndex] = total - assigned; resolveValidators never checks Σ weights == BPS_BASE.
description: A registry that publishes weights above 10,000 in total makes the subtraction underflow, so wrap, rebalance and partial unwrap revert for every caller. Registry owner trusted; robustness gap.

LEAD | contract: VaultAllocation | function: collectDeposit | bug_class: list-head-landing
code_smells: deposit onto zero-stake target first lands on getStakingHotkeys(coldkey,0,1)[0]; ensureHotkeyHasOwner(landing) → tryAssociateHotkey refused when third party reserved that hotkey as coldkey-swap destination (helpers.rs:140); a third party keeps any once-listed hotkey on the list by staking to it on another netuid (stake_utils.rs:1571).
description: An attacker who pins an ownerless list head and reserves it blocks every deposit onto a new validator until the list head changes. No cheap way found to make the list head ownerless (swaps rename in place).

LEAD | contract: StakeOps | function: ensureHotkeyHasOwner | bug_class: vault-staking-list-cap
code_smells: tryAssociateHotkey runs as the vault's coldkey; create_account_if_non_existent (helpers.rs:143-157) refuses at 256 and pushes onto vault's StakingHotkeys; nothing removes entries.
description: After the vault claims 255 ownerless hotkeys, every later claim reverts, so stake under an ownerless hotkey cannot move for any token. No attacker path found that forces claims at that rate.

LEAD | contract: AlphaVault | function: recoverStray | bug_class: pile-transit-through-caller-key
code_smells: with no shortfall, _annex → consolidateRotatedStake → _rollRotatedStake moves the whole slot-0 pile onto the caller-named source and back when slot 0 is richer; source only needs clone stake under it, which any third party can supply onto a listed hotkey; hop runs maybe_become_delegate(source).
description: Any caller makes the vault move its whole slot-0 pile onto a hotkey the caller names and back in one call. No chain mechanic found that lets the hotkey owner take or hold stake keyed to the clone coldkey.

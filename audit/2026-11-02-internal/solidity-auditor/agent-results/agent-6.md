## Agent 6 — periphery

No FINDING. Four LEADs.

Verified: all 25 precompile selectors used exist with matching arg types/return shapes (staking.rs, alpha.rs, subnet.rs TransferToggle 10th field, neuron.rs, balance_transfer.rs, address_mapping.rs). Units consistent (RAO/RAO, wei/wei, getAlphaPrice 1e18 w/ 1e9 quantum). MAX_STAKING_HOTKEYS 256 (lib.rs:105), third-party cap 128 (lib.rs:98); admitsMove one stricter than chain; collectDeposit never hits 128 cap; replacementOpen at 128 matches. DefaultMinTransfer 100_000 RAO vs vault floor DefaultMinStake 2_000_000 RAO: conservative. _sellableChunk leftover bound conservative. All-subnet hotkey swap renames clone position and StakingHotkeys entry (swap_hotkey.rs:585-712); Owner removed only when stake moves. Coldkey-swap V2 reservation refuses hotkey destinations (swap_coldkey.rs:565) so live clones/mailboxes cannot be reserved. pallet_balances transfer_all with zero reducible balance succeeds → replaceClone works on TAO-less clone (refutes agent-1 LEAD sub-existential-deposit-transfer-all partially). OZ 5.4.0 ERC1155Supply._update order confirmed.

LEAD | contract: StakeOps | function: ensureHotkeyHasOwner | bug_class: unbounded-own-staking-list-growth
code_smells: tryAssociateHotkey runs as the vault; create_account_if_non_existent (helpers.rs:142-157) pushes the claimed hotkey onto the vault's own StakingHotkeys after ensure_staking_hotkeys_can_grow (cap 256). Vault never stakes on these keys so nothing prunes.
description: Each ownerless hotkey the vault claims adds one permanent entry to the vault's staking list. After 255 claims every path that needs a claim reverts forever. docs/deployment.md:102 states the 256 refusal; no cheap attacker path found.

LEAD | contract: CloneFactory | function: _requireClean | bug_class: swap-reservation-not-checked
code_smells: _requireClean does not check a live coldkey-swap V2 reservation on the candidate; create_account_if_non_existent (helpers.rs:140) refuses a reserved hotkey, so CloneOwner constructor or mailbox _claimOwnHotkey reverts with raw precompile error instead of CloneContaminated.
description: An attacker who reserves the predicted clone or mailbox address makes createMailbox fail with a raw precompile revert. A fresh uid retries; harm is one failed transaction. docs/deployment.md:102 names the reservation.

LEAD | contract: VaultReads | function: resolveValidators | bug_class: duplicate-attested-hotkeys
code_smells: resolveValidators checks length, cap, shape but not uniqueness. In assignActives two equal attested entries resolve to the same funded slot without the contains(actives, hotkey) guard (only on receiving-hotkey branch); _settle writes two slots with the same active and tracked.
description: A registry that returns the same hotkey twice makes _settle count one balance twice, so shares price above the real backing. Registry owner-controlled; BasicValidatorRegistry returns one entry.

LEAD | contract: SubnetClone | function: unwrapTao | bug_class: existential-deposit-dust-loss
code_smells: EVM native sends use AllowDeath; ED 500 RAO (runtime/src/lib.rs:480). A claim leaving 0 < balance < 500 RAO reaps the account; taoLiability still counts it; next claimTao reverts in sendValue.
description: The last claimants on a token can lose up to 500 RAO of TAO liability that the chain reaps as dust. Under 1e-6 TAO; Frontier reaping for contract accounts unconfirmed.

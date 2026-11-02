## Agent 12 — flow-gap

No FINDINGs. Three LEADs. Verified: deposit path conserves alpha, enforces DefaultMinTransfer (0.0001 TAO) even on full moves, vault floors at DefaultMinStake (0.002 TAO); alpha exit transfer_lock early return for lock-free origin (lock.rs:2034-2055); NewColdKeyIsHotkey checked at announce and execute; TAO exit remove_stake caps at available, bypasses min only on full drain; dissolution blackout covers cleanup, get_next_netuid skips queued netuids; hotkey swaps: all-subnet rename_all + Owner removed (swap_hotkey.rs:624), per-subnet keeps Owner (772); ERC-1155 hook consistent.

LEAD | contract: AlphaVault | function: _unwrapFromLiveSubnet | bug_class: reserved-destination-gas-burn
code_smells: _flushMeasured forwards transferStake(userColdkey, ...) with no destination check; validate_stake_transition (stake_utils.rs:1943) refuses any destination in ColdkeySwapDestinationReservations, which announce_coldkey_swap_v2 lets anyone reserve for 0.1 TAO for 5 days; reclaimAlphaFromMailbox same shape; no precompile exposes the reservation by destination.
description: An attacker reserves a holder's coldkey as a swap destination, so that holder's alpha exit fails and burns the forwarded gas. The holder can release the reservation or use another coldkey.

LEAD | contract: VaultAllocation | function: _sellableChunk | bug_class: full-slot-simulation-dependency
code_smells: leftover bound calls simSwapAlphaForTao(netuid, balance) for the whole slot even when the chunk is small; sim_swap failures surface as PrecompileFailure::Error (alpha.rs:186) and consume forwarded gas. Exclusion-mask exit is the escape hatch.
description: A slot the pool cannot quote in full makes every partial sale of that slot revert, even for a small chunk. No pool input found that fails the full simulation while a smaller chunk would sell.

LEAD | contract: AlphaVault | function: _unwrapFromDissolvedSubnet | bug_class: sub-ed-refund-dropped
code_smells: dissolution credits the clone with `let _ = Self::transfer_tao_from_subnet(...)` (remove_stake.rs:980); transfer_tao uses allow-death semantics (coinbase/tao.rs:61-73) with ED 500 RAO, so a refund below ED to a clone with no free balance is dropped and the error ignored.
description: A dissolved subnet pays the clone less than the existential deposit, so the chain drops the refund and holders redeem nothing. At most 500 RAO per clone.

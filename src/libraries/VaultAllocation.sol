// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { StakeOps } from "./StakeOps.sol";
import { VaultMath } from "./VaultMath.sol";
import { VaultClones } from "./VaultClones.sol";
import { VaultReads } from "./VaultReads.sol";
import { IAlpha, ALPHA_PRECOMPILE } from "../interfaces/IAlpha.sol";
import { IStaking, STAKING_LIST_PAGE, STAKING_PRECOMPILE } from "../interfaces/IStaking.sol";
import { LockedDeposit, ZeroAmount } from "../VaultErrors.sol";
import { IAlphaVaultAbi } from "../interfaces/IAlphaVaultAbi.sol";
import { CloneFactory } from "../CloneFactory.sol";
import { DepositMailbox } from "../DepositMailbox.sol";
import { SubnetClone } from "../SubnetClone.sol";

library VaultAllocation {
    /// @dev What collection does with a pile below the floor.
    enum CollectionPolicy { RevertBelowFloor, LeaveBelowFloor }

    /// @dev One position under one alpha price: the caller reads the price once and every floor test in
    ///      the call uses that read.
    struct Context {
        uint256 tokenId;
        address clone;
        bytes32 coldkey;
        uint16 netuid;
        uint256 alphaPriceE18;
        bytes32 parking;
    }

    function locateBacking(VaultReads.Slot[] memory slots, bytes32 coldkey, uint16 netuid, bytes32 parking)
        external view returns (VaultReads.Backing memory backing) {
        uint256 count = slots.length;
        backing.hotkeys = VaultReads.stakedUnderOf(slots);
        backing.balances = new uint256[](count); backing.short = new bool[](count);
        bool anyShort;
        for (uint256 i; i < count;) {
            uint256 tracked = slots[i].tracked;
            uint256 balance = IStaking(STAKING_PRECOMPILE).getStake(backing.hotkeys[i], coldkey, netuid);
            if (!VaultReads.coversTracked(balance, tracked)) {
                (bytes32 successor, uint256 held) = _coveringSuccessor(backing.hotkeys, i, tracked, coldkey, netuid);
                if (successor != bytes32(0)) {
                    backing.hotkeys[i] = successor; balance = held;
                } else {
                    backing.short[i] = true; anyShort = true;
                }
            }
            backing.balances[i] = balance;
            unchecked { ++i; }
        }
        if (anyShort) _locateShortSlotsOnStakingList(backing, slots, coldkey, netuid, parking);
        backing.total = VaultMath.sumBalances(backing.balances);
    }

    function _coveringSuccessor(bytes32[] memory taken, uint256 index, uint256 tracked, bytes32 coldkey, uint16 netuid)
        private view returns (bytes32 successor, uint256 held) {
        successor = VaultReads.hotkeySuccessor(taken[index], netuid);
        if (successor == bytes32(0) || VaultMath.contains(taken, successor)) return (bytes32(0), 0);
        held = IStaking(STAKING_PRECOMPILE).getStake(successor, coldkey, netuid);
        if (!VaultReads.coversTracked(held, tracked)) return (bytes32(0), 0);
    }

    function _locateShortSlotsOnStakingList(VaultReads.Backing memory backing, VaultReads.Slot[] memory slots, bytes32 coldkey,
        uint16 netuid, bytes32 parking) private view {
        (bytes32[] memory candidates, uint256[] memory piles) = _pilesUnderListedHotkeys(coldkey, netuid, parking);
        for (uint256 i; i < slots.length;) {
            if (backing.short[i]) {
                uint256 pick = _smallestUnclaimedPileCovering(backing.hotkeys, candidates, piles, slots[i].tracked);
                if (pick != VaultMath.INDEX_NOT_FOUND) {
                    backing.hotkeys[i] = candidates[pick]; backing.balances[i] = piles[pick]; backing.short[i] = false;
                }
            }
            unchecked { ++i; }
        }
    }

    function _pilesUnderListedHotkeys(bytes32 coldkey, uint16 netuid, bytes32 parking)
        private view returns (bytes32[] memory candidates, uint256[] memory piles) {
        IStaking staking = IStaking(STAKING_PRECOMPILE);
        (bytes32[] memory page, uint64 total) = staking.getStakingHotkeys(coldkey, 0, STAKING_LIST_PAGE);
        candidates = new bytes32[](total); piles = new uint256[](total);
        for (uint64 offset; offset < total; offset += STAKING_LIST_PAGE) {
            if (offset != 0) (page,) = staking.getStakingHotkeys(coldkey, offset, STAKING_LIST_PAGE);
            for (uint256 i; i < page.length;) {
                bytes32 hotkey = page[i];
                if (hotkey != bytes32(0) && hotkey != parking) {
                    candidates[offset + i] = hotkey;
                    piles[offset + i] = staking.getStake(hotkey, coldkey, netuid);
                }
                unchecked { ++i; }
            }
        }
    }

    function _smallestUnclaimedPileCovering(bytes32[] memory taken, bytes32[] memory candidates, uint256[] memory piles, uint256 tracked)
        private pure returns (uint256 pick) {
        pick = VaultMath.INDEX_NOT_FOUND;
        for (uint256 i; i < piles.length;) {
            bytes32 candidate = candidates[i];
            if (
                candidate != bytes32(0) && !VaultMath.contains(taken, candidate)
                    && VaultReads.coversTracked(piles[i], tracked)
                    && (pick == VaultMath.INDEX_NOT_FOUND || piles[i] < piles[pick])
            ) {
                pick = i;
            }
            unchecked { ++i; }
        }
    }

    function readAdmittedDeposit(bytes32 mailboxColdkey, uint16 nid) external view
        returns (uint256 totalDeposit, uint256 alphaPriceE18) {
        totalDeposit = IStaking(STAKING_PRECOMPILE).getStake(mailboxColdkey, mailboxColdkey, nid);
        if (totalDeposit == 0) revert ZeroAmount();
        alphaPriceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(nid);
        if (StakeOps.isBelowFloorAtReadPrice(totalDeposit, alphaPriceE18)) { revert IAlphaVaultAbi.DepositTooSmall(); }
        if (VaultReads.lockedAlphaOf(mailboxColdkey, nid) != 0) revert LockedDeposit();
    }

    /// @dev Moves the depositor's `amount` of stake from their mailbox into the clone, staked under `target`.
    function pullDepositFromMailbox(address mailbox, bytes32 mailboxColdkey, Context memory context, bytes32 target,
        uint256 amount) external {
        IStaking staking = IStaking(STAKING_PRECOMPILE);
        address clone = context.clone; bytes32 cloneColdkey = context.coldkey; uint16 netuid = context.netuid;
        bytes32 landing = target;
        bool lifted;
        if (staking.getStake(target, cloneColdkey, netuid) == 0) {
            (bytes32[] memory listed, uint64 total) = staking.getStakingHotkeys(cloneColdkey, 0, 1);
            if (total != 0) {
                landing = listed[0];
            } else {
                SubnetClone(clone).setRejectStakingHotkeyGrowth(false); lifted = true;
            }
        }
        uint256 before = staking.getStake(landing, cloneColdkey, netuid);
        StakeOps.ensureHotkeyHasOwner(landing);
        DepositMailbox(mailbox)
            .transferStakeAndHotkey(cloneColdkey, mailboxColdkey, landing, netuid, SafeCast.toUint64(amount));
        if (lifted) SubnetClone(clone).setRejectStakingHotkeyGrowth(true);
        if (landing != target) {
            uint256 landed = staking.getStake(landing, cloneColdkey, netuid) - before;
            StakeOps.moveWithinListCap(clone, cloneColdkey, landing, target, netuid, landed, context.parking);
        }
    }

    /// @dev A fresh clone lists nothing, so its growth flag is down while the old clone transfers in. A pile
    ///      below the floor stays behind rather than fail the call.
    function replaceClone(CloneFactory factory, Context memory context, bytes32[] memory hotkeys,
        uint256[] memory balances, bytes32 uid) external returns (address successor) {
        successor = VaultClones.deployProtectedClone(factory, context.tokenId, context.netuid, uid);
        bytes32 successorColdkey = VaultReads.coldkeyOf(successor);
        SubnetClone(successor).setRejectStakingHotkeyGrowth(false);
        for (uint256 i; i < hotkeys.length;) {
            if (balances[i] != 0 && !StakeOps.isBelowFloorAtReadPrice(balances[i], context.alphaPriceE18)) {
                StakeOps.flush(context.clone, hotkeys[i], successorColdkey, context.netuid, balances[i]);
            }
            unchecked { ++i; }
        }
        SubnetClone(successor).setRejectStakingHotkeyGrowth(true);
        SubnetClone(context.clone).transferAllTao(successorColdkey);
    }

    /// @dev Both sale rounds share this call's balances array: the partial round must see slots drained
    ///      by the first round.
    function sellForTao(address clone, uint16 netuid, bytes32[] memory hotkeys,
        uint256[] memory balances, uint256 excludedSlots, uint256 assets) external {
        uint256 dustThresholdTao = IStaking(STAKING_PRECOMPILE).getNominatorMinRequiredStake();
        // Full drains precede partials so a shrunken partial cannot consume a later floor-exempt drain.
        uint256 remaining = _sellRound(clone, netuid, hotkeys, balances, excludedSlots, assets, dustThresholdTao, false);
        _sellRound(clone, netuid, hotkeys, balances, excludedSlots, remaining, dustThresholdTao, true);
    }

    function _sellRound(address clone, uint16 netuid, bytes32[] memory hotkeys,
        uint256[] memory balances, uint256 excludedSlots, uint256 remaining,
        uint256 dustThresholdTao, bool includePartials) private returns (uint256) {
        for (uint256 i; i < hotkeys.length && remaining != 0;) {
            uint256 balance = (excludedSlots >> i) & 1 == 0 ? balances[i] : 0;
            uint256 chunk;
            if (balance <= remaining) {
                chunk = balance;
            } else if (includePartials) {
                chunk = _sellableChunk(netuid, remaining, balance, dustThresholdTao);
            }
            if (chunk != 0) {
                StakeOps.sell(clone, hotkeys[i], netuid, chunk);
                balances[i] = balance - chunk; remaining -= chunk;
            }
            unchecked { ++i; }
        }
        return remaining;
    }

    /// @dev Partial sales must clear the post-fee minimum without leaving dust the chain would force-sell
    ///      into this caller's payout at the remaining holders' expense.
    ///      The chain reports a slot balance as a 64-bit amount, so narrowing one for a quote cannot
    ///      truncate; a wider value is a fixture rather than a position and is refused.
    function _sellableChunk(uint16 netuid, uint256 remaining, uint256 balance, uint256 dustThresholdTao) private view returns (uint256) {
        uint256 alphaPriceE18 = IAlpha(ALPHA_PRECOMPILE).getAlphaPrice(netuid);
        if (alphaPriceE18 == 0) return 0;

        // One extra RAO covers the leftover quote's rounding.
        uint256 minLeftover = dustThresholdTao == 0
            ? 0 : Math.ceilDiv((dustThresholdTao + 1) * VaultMath.ALPHA_PRICE_SCALE, alphaPriceE18);
        if (balance <= minLeftover) return 0;

        uint256 maxChunk = balance - minLeftover; uint256 chunk = maxChunk < remaining ? maxChunk : remaining;
        // Keep gas-consuming simulation failures away from provably sub-floor inputs.
        if (StakeOps.isBelowFloorAtReadPrice(chunk, alphaPriceE18)) return 0;

        uint256 chunkQuote = IAlpha(ALPHA_PRECOMPILE).simSwapAlphaForTao(netuid, SafeCast.toUint64(chunk));
        if (chunkQuote < StakeOps.minStakeTao()) return 0;

        // The marginal quote bounds leftover value at the post-sale price.
        if (dustThresholdTao != 0) {
            uint256 leftoverQuote =
                IAlpha(ALPHA_PRECOMPILE).simSwapAlphaForTao(netuid, SafeCast.toUint64(balance)) - chunkQuote;
            if (leftoverQuote < dustThresholdTao) return 0;
        }
        return chunk;
    }

    /// @dev The chain refuses stake operations under a hotkey with no owner record, so an empty slot needs a
    ///      receiving hotkey that has one.
    function stakingHotkeysForAttestedSet(VaultReads.Slot[] memory slots, VaultReads.Backing memory backing,
        bytes32[] memory attestedHotkeys, uint16 netuid
    ) external view returns (bytes32[] memory stakingHotkeys, bytes32 retiredAttested) {
        bytes32[] memory slotAttested = VaultReads.attestedOf(slots);
        bytes32[] memory slotHotkeys = backing.hotkeys; uint256[] memory balances = backing.balances;
        stakingHotkeys = new bytes32[](attestedHotkeys.length);
        for (uint256 i; i < attestedHotkeys.length;) {
            bytes32 attested = attestedHotkeys[i];
            uint256 ownSlot = VaultMath.indexOf(slotAttested, attested);
            bytes32 hotkey; bool usable;
            if (ownSlot != VaultMath.INDEX_NOT_FOUND && balances[ownSlot] != 0) {
                hotkey = slotHotkeys[ownSlot]; usable = StakeOps.hasOwner(hotkey);
            } else {
                (hotkey, usable) = _receivingHotkeyForEmptySlot(slotHotkeys, slotAttested, attestedHotkeys, attested, ownSlot, netuid);
                if (hotkey != attested && VaultMath.contains(stakingHotkeys, hotkey)) { revert IAlphaVaultAbi.SwappedHotkeyStillAttested(); }
            }
            stakingHotkeys[i] = hotkey;
            if (!usable && retiredAttested == bytes32(0)) retiredAttested = attested;
            unchecked { ++i; }
        }
    }

    /// @dev Start at the richest source or destination, letting a fresh deposit carry rotated-out dust.
    function chooseConsolidationStart(bytes32[] memory sourceHotkeys, bytes32[] memory attestedHotkeys, bytes32 coldkey, uint16 netuid)
        public view returns (
            bytes32 richestHotkey, uint256 richestBalance,
            uint256[] memory sourceBalances, bool hasRotatedOutBalance, bytes32 destination) {
        sourceBalances = new uint256[](sourceHotkeys.length);
        bytes32 richestRotatedOut; uint256 richestRotatedOutBalance;
        for (uint256 i; i < sourceBalances.length;) {
            bytes32 candidate = sourceHotkeys[i];
            if (!VaultMath.contains(attestedHotkeys, candidate)) {
                uint256 balance = IStaking(STAKING_PRECOMPILE).getStake(candidate, coldkey, netuid);
                sourceBalances[i] = balance;
                if (balance > richestRotatedOutBalance) { richestRotatedOut = candidate; richestRotatedOutBalance = balance; }
            }
            unchecked { ++i; }
        }
        if (richestRotatedOutBalance == 0) return (attestedHotkeys[0], 0, sourceBalances, false, attestedHotkeys[0]);

        hasRotatedOutBalance = true;
        richestHotkey = attestedHotkeys[0];
        for (uint256 i; i < attestedHotkeys.length;) {
            uint256 balance = IStaking(STAKING_PRECOMPILE).getStake(attestedHotkeys[i], coldkey, netuid);
            if (balance > richestBalance) { richestHotkey = attestedHotkeys[i]; richestBalance = balance; }
            unchecked { ++i; }
        }
        destination = richestHotkey;
        if (richestRotatedOutBalance > richestBalance) {
            richestHotkey = richestRotatedOut; richestBalance = richestRotatedOutBalance;
        }
    }

    /// @dev A still-attested slot reserves its resolved hotkey even while empty.
    function _hotkeyHeldByAnotherAttestedSlot(bytes32[] memory slotHotkeys, bytes32[] memory slotAttested, bytes32[] memory attestedHotkeys,
        bytes32 hotkey, uint256 ownSlot) private pure returns (bool) {
        uint256 holder = VaultMath.indexOf(slotHotkeys, hotkey);
        if (holder == VaultMath.INDEX_NOT_FOUND || holder == ownSlot) return false;
        return VaultMath.contains(attestedHotkeys, slotAttested[holder]);
    }

    /// @dev The recorded active hotkey while it has an owner record and no outgoing swap edge, else the
    ///      attested hotkey while it has an owner record, else the record's one-hop successor. The record
    ///      comes first so an emptied slot follows the validator, whoever claims the vacated attested hotkey.
    function _receivingHotkeyForEmptySlot(bytes32[] memory slotHotkeys, bytes32[] memory slotAttested, bytes32[] memory attestedHotkeys,
        bytes32 attested, uint256 ownSlot,
        uint16 netuid) private view returns (bytes32 hotkey, bool usable) {
        bool attestedHeldElsewhere = _hotkeyHeldByAnotherAttestedSlot(slotHotkeys, slotAttested, attestedHotkeys, attested, ownSlot);
        if (attestedHeldElsewhere && ownSlot == VaultMath.INDEX_NOT_FOUND) revert IAlphaVaultAbi.SwappedHotkeyStillAttested();

        hotkey = ownSlot == VaultMath.INDEX_NOT_FOUND ? attested : slotHotkeys[ownSlot];
        bytes32 successor = VaultReads.hotkeySuccessor(hotkey, netuid);
        usable = hotkey != attested && successor == bytes32(0) && StakeOps.hasOwner(hotkey);
        if (!usable) {
            if (!attestedHeldElsewhere && StakeOps.hasOwner(attested)) return (attested, true);
            if (successor != bytes32(0) && successor != attested && StakeOps.hasOwner(successor)) { hotkey = successor; usable = true; }
        }
        if (
            hotkey != attested
                && (VaultMath.contains(attestedHotkeys, hotkey) || _hotkeyHeldByAnotherAttestedSlot(slotHotkeys, slotAttested, attestedHotkeys, hotkey, ownSlot))
        ) {
            revert IAlphaVaultAbi.SwappedHotkeyStillAttested();
        }
    }

    function _alignToWeights(Context memory context, bytes32[] memory hotkeys, uint16[] memory weights, uint256[] memory balances) private {
        uint256 total = VaultMath.sumBalances(balances);

        // A single slot already holds every unit there is to align.
        if (weights.length == 1 || total == 0) return;

        uint256 lastIndex = weights.length - 1; uint256[] memory targets = new uint256[](weights.length);
        {
            uint256 assigned;
            for (uint256 i; i < lastIndex;) {
                targets[i] = (total * weights[i]) / VaultMath.BPS_BASE; assigned += targets[i];
                unchecked { ++i; }
            }
            targets[lastIndex] = total - assigned;
        }

        // Each step settles one cached target, so N-1 steps bound the loop.
        // Settlement rereads actual chain balances afterwards.
        uint256 minStakeTao = StakeOps.minStakeTao();
        for (uint256 round; round < lastIndex;) {
            if (!_moveLargestSurplusToLargestDeficit(context, hotkeys, balances, targets, minStakeTao)) break;
            unchecked { ++round; }
        }
    }

    function _moveLargestSurplusToLargestDeficit(Context memory context, bytes32[] memory hotkeys, uint256[] memory balances,
        uint256[] memory targets, uint256 minStakeTao) private returns (bool) {
        uint256 overIndex; uint256 maxOver;
        uint256 underIndex; uint256 maxUnder;
        for (uint256 i; i < balances.length;) {
            if (balances[i] > targets[i]) {
                uint256 over = balances[i] - targets[i];
                if (over > maxOver) { maxOver = over; overIndex = i; }
            } else if (balances[i] < targets[i]) {
                uint256 under = targets[i] - balances[i];
                if (under > maxUnder) { maxUnder = under; underIndex = i; }
            }
            unchecked { ++i; }
        }

        if (maxOver == 0) return false;

        uint256 moveAmount = maxOver < maxUnder ? maxOver : maxUnder;
        // A rejected precompile call consumes forwarded gas. Skip unproven moves and tolerate weight drift.
        if (context.alphaPriceE18 == 0 || StakeOps.taoValue(moveAmount, context.alphaPriceE18) < minStakeTao) { return false; }
        // A full staking list is no reason to hold an exit; alignment waits for the clone's replacement.
        if (!VaultReads.stakingListAdmits(context.coldkey, hotkeys[underIndex], context.netuid, context.parking)) return false;
        StakeOps.moveUnchecked(context.clone, hotkeys[overIndex], hotkeys[underIndex], context.netuid, moveAmount);
        emit IAlphaVaultAbi.Rebalanced(context.tokenId, hotkeys[overIndex], hotkeys[underIndex], moveAmount);
        balances[overIndex] -= moveAmount; balances[underIndex] += moveAmount;
        return true;
    }

    /// @dev Move all dropped-hotkey backing onto tracked destinations before rewriting the record.
    ///      Recovery may leave a below-floor pile in place; other callers refuse it.
    /// @return leftBelowFloor True only when the richest source/destination is below the floor.
    function consolidateRotatedStake(Context memory context, bytes32[] memory sourceHotkeys, bytes32[] memory attestedHotkeys,
        CollectionPolicy policy) external returns (bool leftBelowFloor) {
        if (!_anyRotatedOut(sourceHotkeys, attestedHotkeys)) return false;
        (bytes32 rollerHotkey, uint256 richestBalance, uint256[] memory sourceBalances, bool hasRotatedOutBalance, bytes32 destination)
            = chooseConsolidationStart(sourceHotkeys, attestedHotkeys, context.coldkey, context.netuid);
        if (!hasRotatedOutBalance) return false;
        // The pile starts at the largest balance and only grows, up to rounding on each move,
        // so its starting size bounds every hop to within that rounding.
        if (StakeOps.isBelowFloorAtAnyPrice(richestBalance, context.alphaPriceE18)) {
            if (policy == CollectionPolicy.LeaveBelowFloor) return true;
            revert IAlphaVaultAbi.ConsolidationBelowFloor();
        }
        _rollPileThroughRotatedOutHotkeys(context, sourceHotkeys, destination, rollerHotkey, sourceBalances);
        return false;
    }

    /// @dev Never revisit the starting hotkey: its cached balance is stale once the pile leaves.
    function _rollPileThroughRotatedOutHotkeys(Context memory context, bytes32[] memory sourceHotkeys, bytes32 destination,
        bytes32 rollerHotkey, uint256[] memory sourceBalances) private {
        bytes32 richestHotkey = rollerHotkey;
        bytes32 coldkey = context.coldkey; uint16 netuid = context.netuid;
        for (uint256 i; i < sourceBalances.length;) {
            bytes32 sourceHotkey = sourceHotkeys[i];
            if (sourceHotkey != richestHotkey && sourceBalances[i] > 0) {
                // Read the live pile; summing earlier credits would over-ask after chain rounding.
                uint256 pile = IStaking(STAKING_PRECOMPILE).getStake(rollerHotkey, coldkey, netuid);
                StakeOps.moveWithinListCap(context.clone, coldkey, rollerHotkey, sourceHotkey, netuid, pile, context.parking);
                rollerHotkey = sourceHotkey;
            }
            unchecked { ++i; }
        }
        uint256 finalPile = IStaking(STAKING_PRECOMPILE).getStake(rollerHotkey, coldkey, netuid);
        if (richestHotkey == destination) StakeOps.moveUnchecked(context.clone, rollerHotkey, destination, netuid, finalPile);
        else StakeOps.moveWithinListCap(context.clone, coldkey, rollerHotkey, destination, netuid, finalPile, context.parking);
    }

    function _anyRotatedOut(bytes32[] memory hotkeys, bytes32[] memory attestedHotkeys) private pure returns (bool) {
        for (uint256 i; i < hotkeys.length;) {
            if (!VaultMath.contains(attestedHotkeys, hotkeys[i])) return true;
            unchecked { ++i; }
        }
        return false;
    }

    /// @dev Runs inside the vault's reentrancy guard.
    function rebalance(Context memory context, bytes32[] memory hotkeys, uint16[] memory weights) external {
        uint256[] memory balances = VaultReads.stakesUnder(hotkeys, context.coldkey, context.netuid);
        _alignToWeights(context, hotkeys, weights, balances);
    }

    /// @dev The vault checks slippage and settles its record after this returns; failures revert all stake moves.
    function payAlpha(Context memory context, bytes32[] memory hotkeys, uint256[] memory balances,
        bytes32 userColdkey, uint256 assets) external returns (uint256 alphaOut) {
        (bytes32 payingHotkey, uint256 deliverable) = _gatherIntoLargestSlot(context, hotkeys, balances, assets);
        uint256 requested = assets < deliverable ? assets : deliverable;
        return _flushAndMeasureCredit(context.clone, payingHotkey, userColdkey, context.netuid, requested);
    }

    function _gatherIntoLargestSlot(Context memory context, bytes32[] memory hotkeys, uint256[] memory balances,
        uint256 assets) private returns (bytes32 payingHotkey, uint256 deliverable) {
        bytes32 coldkey = context.coldkey; uint16 netuid = context.netuid;
        uint256 deliveryIndex;
        for (uint256 i = 1; i < balances.length;) {
            if (balances[i] > balances[deliveryIndex]) deliveryIndex = i;
            unchecked { ++i; }
        }
        // Gather hops can round down, so summed balances cannot determine the final deliverable amount.
        deliverable = balances[deliveryIndex];
        if (balances[deliveryIndex] < assets) {
            // Start with the largest slot; reject an unmovable pile before forwarding gas to the chain.
            if (StakeOps.isBelowFloorAtAnyPrice(balances[deliveryIndex], context.alphaPriceE18)) {
                revert IAlphaVaultAbi.GatherBelowFloor();
            }
            // Re-read every hop: requesting a cached sum can exceed the balance after chain rounding.
            for (uint256 i; i < balances.length && balances[deliveryIndex] < assets;) {
                if (i != deliveryIndex && balances[i] != 0) {
                    uint256 pile = IStaking(STAKING_PRECOMPILE).getStake(hotkeys[deliveryIndex], coldkey, netuid);
                    StakeOps.moveWithinListCap(context.clone, coldkey, hotkeys[deliveryIndex], hotkeys[i], netuid, pile, context.parking);
                    balances[i] += balances[deliveryIndex]; balances[deliveryIndex] = 0; deliveryIndex = i;
                }
                unchecked { ++i; }
            }
            deliverable = IStaking(STAKING_PRECOMPILE).getStake(hotkeys[deliveryIndex], coldkey, netuid);
        }
        payingHotkey = hotkeys[deliveryIndex];
    }

    /// @dev Bound slippage against actual recipient credit, including chain-side stake-share rounding.
    function _flushAndMeasureCredit(address clone, bytes32 hotkey, bytes32 userColdkey, uint16 netuid, uint256 amount)
        private returns (uint256) {
        uint256 recipientBefore = IStaking(STAKING_PRECOMPILE).getStake(hotkey, userColdkey, netuid);
        StakeOps.flush(clone, hotkey, userColdkey, netuid, amount);
        uint256 recipientAfter = IStaking(STAKING_PRECOMPILE).getStake(hotkey, userColdkey, netuid);
        return recipientAfter > recipientBefore ? recipientAfter - recipientBefore : 0;
    }
}

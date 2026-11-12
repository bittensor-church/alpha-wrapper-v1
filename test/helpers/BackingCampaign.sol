// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { CampaignHarness, requireExpectedRevert } from "./CampaignHarness.sol";
import { CHAIN_MIN_STAKE, CHAIN_MIN_TRANSFER, MockStaking } from "../mocks/MockStaking.sol";
import { MockAlpha } from "../mocks/MockAlpha.sol";
import { ALPHA_PRECOMPILE } from "src/interfaces/IAlpha.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { IAlphaVaultAbi } from "src/interfaces/IAlphaVaultAbi.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";
import {
    AttestedHotkeyRetired,
    BackingShortfall,
    BackingUnchanged,
    NothingToRecover,
    NothingToUnwrap,
    Parked,
    ShortfallOnFile,
    SupplyCapExceeded,
    WithdrawTooSmall,
    ZeroAmount
} from "src/VaultErrors.sol";

/// @dev Errors any call that opens the backing record and assigns the attested set can raise.
function backingErrors(uint256 extra) pure returns (bytes4[] memory errors, uint256 next) {
    errors = new bytes4[](5 + extra);
    errors[0] = ShortfallOnFile.selector;
    errors[1] = BackingShortfall.selector;
    errors[2] = AttestedHotkeyRetired.selector;
    errors[3] = IAlphaVaultAbi.SwappedHotkeyStillAttested.selector;
    errors[4] = IAlphaVaultAbi.ConsolidationBelowFloor.selector;
    next = 5;
}

/// @dev Campaign deposits of 10 alpha or more clear the move floor at every campaign price.
function wrapErrors() pure returns (bytes4[] memory errors) {
    uint256 next;
    (errors, next) = backingErrors(3);
    errors[next] = Parked.selector;
    errors[next + 1] = ZeroAmount.selector;
    errors[next + 2] = SupplyCapExceeded.selector;
}

function unwrapErrors() pure returns (bytes4[] memory errors) {
    uint256 next;
    (errors, next) = backingErrors(3);
    errors[next] = ZeroAmount.selector;
    errors[next + 1] = WithdrawTooSmall.selector;
    errors[next + 2] = IAlphaVaultAbi.GatherBelowFloor.selector;
}

function unwrapForTaoErrors() pure returns (bytes4[] memory errors) {
    errors = new bytes4[](5);
    errors[0] = ShortfallOnFile.selector;
    errors[1] = BackingShortfall.selector;
    errors[2] = ZeroAmount.selector;
    errors[3] = NothingToUnwrap.selector;
    errors[4] = WithdrawTooSmall.selector;
}

function rebalanceErrors() pure returns (bytes4[] memory errors) {
    uint256 next;
    (errors, next) = backingErrors(1);
    errors[next] = Parked.selector;
}

function syncErrors() pure returns (bytes4[] memory errors) {
    errors = new bytes4[](1);
    errors[0] = BackingUnchanged.selector;
}

function recoverErrors() pure returns (bytes4[] memory errors) {
    errors = new bytes4[](3);
    errors[0] = NothingToRecover.selector;
    errors[1] = BackingShortfall.selector;
    errors[2] = IAlphaVaultAbi.ConsolidationBelowFloor.selector;
}

/// @dev A replacement opens the backing record and nothing else that the campaign can refuse.
function replaceErrors() pure returns (bytes4[] memory errors) {
    errors = new bytes4[](2);
    errors[0] = ShortfallOnFile.selector;
    errors[1] = BackingShortfall.selector;
}

/// @dev What a refused call asked for, so the refusal can be checked against the state that justifies it.
struct Attempt {
    uint256 deposit;
    uint256 shares;
    uint256 excludedSlots;
    bytes32 source;
    bool forTao;
}

abstract contract BackingCampaignHandler is Test {
    /// @dev The vault's supply cap: one native quantum (1e9) times the index precision (1e36).
    uint256 private constant SUPPLY_CAP = 1e45;

    AlphaVault public immutable vault;
    BackingCampaignHarness public immutable harness;
    uint256 public immutable tokenId;
    uint256 public immutable netuid;
    address[] public actors;

    bytes32[] public touchedHotkeys;
    mapping(bytes32 => bool) public touched;

    uint256 public wraps;
    uint256 public alphaExits;
    uint256 public taoExits;
    uint256 public rebalances;
    uint256 public syncs;
    uint256 public recoveriesClosed;
    uint256 public lastAlphaPaid;

    constructor(
        AlphaVault _vault,
        BackingCampaignHarness _harness,
        uint256 _tokenId,
        uint256 _netuid,
        address[] memory _actors,
        bytes32[] memory _seedHotkeys
    ) {
        vault = _vault;
        harness = _harness;
        tokenId = _tokenId;
        netuid = _netuid;
        actors = _actors;
        for (uint256 i; i < _seedHotkeys.length; ++i) {
            _remember(_seedHotkeys[i]);
        }
    }

    function knownHotkeys() external view returns (bytes32[] memory) {
        return touchedHotkeys;
    }

    function wrap(uint256 actorSeed, uint256 amount, uint256 hotkeySeed) external {
        address actor = _actor(actorSeed);
        bytes32 hotkey = _attested(hotkeySeed);
        harness.depositTo(actor, bound(amount, 10, 1_000) * 1e9);
        uint256 deposit = harness.mailboxStake(actor);
        uint256 holdings = harness.chainHoldings();
        uint256 shares = vault.balanceOf(actor, tokenId);
        vm.prank(actor);
        try vault.wrap(netuid, hotkey, 0) {
            ++wraps;
            assertEq(harness.mailboxStake(actor), 0, "a wrap empties the mailbox");
            assertEq(harness.chainHoldings(), holdings + deposit, "a wrap moves exactly the deposit into the clone");
            harness.assertRecordMatchesChain();
            assertGt(vault.balanceOf(actor, tokenId), shares, "a wrap mints shares");
            _afterAllocation();
        } catch (bytes memory reason) {
            _requireJustifiedRevert(reason, wrapErrors(), Attempt(deposit, 0, 0, bytes32(0), false));
        }
    }

    function unwrap(uint256 actorSeed, uint256 shareSeed) external {
        address actor = _actor(actorSeed);
        uint256 balance = vault.balanceOf(actor, tokenId);
        if (balance == 0) return;
        uint256 shares = bound(shareSeed, 1, balance);
        uint256 supply = vault.totalSupply(tokenId);
        uint256 holdings = harness.chainHoldings();
        bytes32 coldkey = keccak256(abi.encode(actor));
        uint256 before = harness.stakeOf(coldkey);
        vm.prank(actor);
        try vault.unwrap(tokenId, shares, coldkey, 0) {
            ++alphaExits;
            lastAlphaPaid = harness.stakeOf(coldkey) - before;
            assertEq(vault.balanceOf(actor, tokenId), balance - shares, "an alpha exit burns exactly the shares asked");
            assertEq(
                harness.chainHoldings(),
                holdings - lastAlphaPaid,
                "an alpha exit moves exactly the payout out of the clone"
            );
            uint256 backing = harness.assertRecordMatchesChain() + lastAlphaPaid;
            assertLt(
                lastAlphaPaid * supply,
                shares * backing + supply,
                "an alpha exit paid more than one RAO above its share"
            );
            if (shares != supply) _afterAllocation();
        } catch (bytes memory reason) {
            _requireJustifiedRevert(reason, unwrapErrors(), Attempt(0, shares, 0, bytes32(0), false));
        }
    }

    function unwrapForTao(uint256 actorSeed, uint256 shareSeed) external {
        address actor = _actor(actorSeed);
        uint256 balance = vault.balanceOf(actor, tokenId);
        if (balance == 0) return;
        _sellForTao(actor, bound(shareSeed, 1, balance), harness.zeroPaySlots());
    }

    function _sellForTao(address actor, uint256 shares, uint256 excluded) internal returns (bool sold) {
        address clone = vault.subnetClone(tokenId);
        uint256 cloneTao = clone.balance;
        uint256 holderTao = actor.balance;
        uint256 holdings = harness.chainHoldings();
        vm.prank(actor);
        try vault.unwrapForTao(tokenId, shares, 0, excluded) {
            ++taoExits;
            assertGt(actor.balance, holderTao, "a TAO exit pays the holder");
            assertEq(clone.balance, cloneTao, "a TAO exit passes every sale proceed to the holder");
            assertLt(harness.chainHoldings(), holdings, "a TAO exit sells backing");
            harness.assertRecordMatchesChain();
            sold = true;
        } catch (bytes memory reason) {
            _requireJustifiedRevert(reason, unwrapForTaoErrors(), Attempt(0, shares, excluded, bytes32(0), true));
        }
    }

    function rebalance() external {
        uint256 holdings = harness.chainHoldings();
        try vault.rebalance(netuid) {
            ++rebalances;
            assertEq(harness.chainHoldings(), holdings, "a rebalance conserves the clone's holdings");
            harness.assertRecordMatchesChain();
            _afterAllocation();
        } catch (bytes memory reason) {
            _requireJustifiedRevert(reason, rebalanceErrors(), Attempt(0, 0, 0, bytes32(0), false));
        }
    }

    function syncBacking() external {
        (uint256 shortSinceBefore,) = vault.recovery(tokenId);
        bool shortBefore = shortSinceBefore == 0 && harness.anySlotShort();
        uint256 owedBefore = harness.trackedBacking();
        uint256 parkedBefore = harness.parkedStake();
        uint256 holdings = harness.chainHoldings();
        try vault.syncBacking(tokenId) {
            ++syncs;
            (uint256 shortSinceAfter,) = vault.recovery(tokenId);
            assertEq(harness.chainHoldings(), holdings, "a sync only moves backing within the clone");
            if (shortSinceAfter == 0) {
                if (shortSinceBefore != 0) {
                    ++recoveriesClosed;
                    _assertWriteOffAfterTheDeadline(shortSinceBefore, owedBefore);
                }
                harness.assertRecordMatchesChain();
            } else if (shortSinceBefore == 0) {
                _assertDeclaredShortfall(shortBefore, shortSinceAfter, owedBefore);
            } else {
                assertEq(shortSinceAfter, shortSinceBefore, "a collection keeps the recovery clock");
                assertEq(harness.trackedBacking(), owedBefore, "a collection keeps the obligation");
                assertGt(harness.parkedStake(), parkedBefore, "a collection moves backing onto the parking hotkey");
            }
        } catch (bytes memory reason) {
            _requireJustifiedRevert(reason, syncErrors(), Attempt(0, 0, 0, bytes32(0), false));
        }
    }

    function _assertWriteOffAfterTheDeadline(uint256 shortSince, uint256 owedBefore) private view {
        if (harness.trackedBacking() + harness.slack() < owedBefore) {
            assertGe(block.timestamp, shortSince + vault.recoveryWindow(), "wrote off a shortfall before its deadline");
        }
    }

    function _assertDeclaredShortfall(bool shortBefore, uint256 shortSince, uint256 owedBefore) private view {
        assertTrue(shortBefore, "declared a shortfall without a short slot");
        assertEq(shortSince, block.timestamp, "the recovery clock starts at the declaration");
        assertEq(harness.trackedBacking(), owedBefore, "the declaration keeps the obligation");
        assertLt(
            harness.parkedStake() + harness.slack(), owedBefore, "a declared shortfall leaves the parking hotkey short"
        );
    }

    function passTime(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1 minutes, 4 hours));
    }

    function movePrice(uint256 priceSeed) external {
        harness.movePrice(priceSeed);
    }

    function accrueEmissions(uint256 amount) external {
        harness.accrueEmissions(bound(amount, 1, 300) * 1e9);
    }

    function _afterAllocation() internal virtual { }

    /// @dev A refusal must be documented for the entry point and justified by the state it met: each check below
    ///      is a condition the refused state must satisfy, read from the chain mock rather than the lens.
    function _requireJustifiedRevert(bytes memory reason, bytes4[] memory expected, Attempt memory attempt)
        internal
        view
    {
        requireExpectedRevert(reason, expected);
        bytes4 selector = bytes4(reason);
        (uint256 shortSince,) = vault.recovery(tokenId);
        uint256 supply = vault.totalSupply(tokenId);
        if (selector == ShortfallOnFile.selector) {
            assertTrue(shortSince != 0, "refused for a shortfall nobody filed");
        } else if (selector == BackingShortfall.selector) {
            assertTrue(shortSince == 0 && harness.anySlotShort(), "refused intact backing as short");
        } else if (selector == Parked.selector) {
            assertTrue(harness.parked(), "refused as parked after the release");
        } else if (selector == AttestedHotkeyRetired.selector) {
            assertEq(
                harness.firstRetiredAttestedHotkey(),
                _firstWord(reason),
                "refused an attested hotkey with a usable hotkey"
            );
        } else if (selector == IAlphaVaultAbi.SwappedHotkeyStillAttested.selector) {
            (,,, bool collides) = harness.attestedAssignment();
            assertTrue(collides, "refused an assignment without a collision");
        } else if (selector == IAlphaVaultAbi.ConsolidationBelowFloor.selector) {
            bool belowFloor = attempt.source == bytes32(0)
                ? harness.consolidationBelowFloor(attempt.deposit)
                : harness.annexBelowFloor(attempt.source);
            assertTrue(shortSince == 0 && belowFloor, "refused to consolidate piles that clear the floor");
        } else if (selector == IAlphaVaultAbi.GatherBelowFloor.selector) {
            assertTrue(harness.gatherBelowFloor(), "refused to gather piles that clear the floor");
        } else if (selector == NothingToRecover.selector) {
            assertTrue(harness.nothingToCollectFrom(attempt.source), "refused a collectable stray");
        } else if (selector == NothingToUnwrap.selector) {
            assertEq(harness.resolvedBacking(), 0, "refused an exit from funded backing");
        } else if (selector == BackingUnchanged.selector) {
            if (shortSince == 0) {
                assertTrue(harness.everySlotOnItsRecordedHotkey(), "refused to record a followed hotkey swap");
            } else {
                assertLt(block.timestamp, shortSince + vault.recoveryWindow(), "refused an expired write-off");
                assertTrue(harness.recoveryCannotAdvance(), "refused a sync that collects or closes the recovery");
            }
        } else if (selector == SupplyCapExceeded.selector) {
            assertGt(
                supply + attempt.deposit * (supply + 1e9) / (harness.resolvedBacking() + 1),
                SUPPLY_CAP,
                "refused shares within the cap"
            );
        } else if (selector == ZeroAmount.selector) {
            if (attempt.deposit != 0) {
                assertLe(attempt.deposit * (supply + 1e9), harness.chainHoldings(), "refused a deposit worth a share");
            } else {
                assertEq(harness.leastAssetsFor(attempt.shares), 0, "refused shares worth a RAO");
            }
        } else if (selector == WithdrawTooSmall.selector) {
            if (attempt.forTao) {
                assertFalse(
                    harness.sellsASlotWithin(harness.taoExitAssets(attempt.shares), attempt.excludedSlots),
                    "refused a TAO exit that can sell"
                );
            } else {
                assertLt(
                    harness.taoValueAtRead(harness.leastAssetsFor(attempt.shares)),
                    CHAIN_MIN_STAKE,
                    "refused an exit above the floor"
                );
            }
        }
    }

    function _firstWord(bytes memory reason) private pure returns (bytes32 word) {
        assembly {
            word := mload(add(reason, 36))
        }
    }

    function _remember(bytes32 hotkey) internal {
        if (touched[hotkey]) return;
        touched[hotkey] = true;
        touchedHotkeys.push(hotkey);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function _attested(uint256 seed) internal view returns (bytes32) {
        bytes32[] memory set = harness.attestedSet();
        return set[bound(seed, 0, set.length - 1)];
    }
}

abstract contract BackingCampaignHarness is CampaignHarness {
    bytes32[] internal attestedHotkeys;

    function _campaign() internal view virtual returns (BackingCampaignHandler);

    function attestedSet() external view returns (bytes32[] memory) {
        return attestedHotkeys;
    }

    function slack() external pure returns (uint256) {
        return BACKING_SLACK_RAO;
    }

    function resolvedSlots()
        public
        view
        returns (bytes32[] memory hotkeys, uint256[] memory balances, bool[] memory short)
    {
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        hotkeys = new bytes32[](slots.length);
        balances = new uint256[](slots.length);
        short = new bool[](slots.length);
        for (uint256 i; i < slots.length; ++i) {
            hotkeys[i] = slots[i].stakedUnder;
        }
        for (uint256 i; i < slots.length; ++i) {
            uint256 held = _getVaultStake(hotkeys[i], NETUID1);
            if (held + BACKING_SLACK_RAO < slots[i].tracked) {
                bytes32 successor = _successorOf(hotkeys[i]);
                uint256 successorHeld = _getVaultStake(successor, NETUID1);
                if (
                    successor != bytes32(0) && !_contains(hotkeys, successor)
                        && successorHeld + BACKING_SLACK_RAO >= slots[i].tracked
                ) {
                    hotkeys[i] = successor;
                    held = successorHeld;
                } else {
                    short[i] = true;
                }
            }
            balances[i] = held;
        }
        _assignShortSlotsFromList(slots, hotkeys, balances, short);
    }

    function _assignShortSlotsFromList(
        VaultReads.Slot[] memory slots,
        bytes32[] memory hotkeys,
        uint256[] memory balances,
        bool[] memory short
    ) private view {
        for (uint256 i; i < slots.length; ++i) {
            if (!short[i]) continue;
            (bytes32 holder, uint256 held) = _smallestCoveringListed(hotkeys, slots[i].tracked);
            if (holder != bytes32(0)) {
                hotkeys[i] = holder;
                balances[i] = held;
                short[i] = false;
            }
        }
    }

    function _smallestCoveringListed(bytes32[] memory taken, uint256 tracked)
        private
        view
        returns (bytes32 holder, uint256 held)
    {
        bytes32[] memory listed = _listedHotkeys(_subnetColdkey(NETUID1));
        for (uint256 i; i < listed.length; ++i) {
            if (listed[i] == bytes32(0) || listed[i] == vault.parkingHotkey() || _contains(taken, listed[i])) continue;
            uint256 balance = _getVaultStake(listed[i], NETUID1);
            if (balance + BACKING_SLACK_RAO >= tracked && (holder == bytes32(0) || balance < held)) {
                holder = listed[i];
                held = balance;
            }
        }
    }

    /// @dev Both halves must clear the chain's transfer minimum for the returns to land.
    function strandable(bytes32 hotkey) external view returns (bool) {
        uint256 held = _getVaultStake(hotkey, NETUID1);
        return held != 0
            && (held / 2) * MockAlpha(ALPHA_PRECOMPILE).chainAlphaPrice(uint16(NETUID1)) / 1e18 >= CHAIN_MIN_TRANSFER;
    }

    function simulateSweepReturnedInTwoPiles(bytes32 from, bytes32 first, bytes32 second) external {
        uint256 swept = _sweepDuringCrash(NETUID1, from);
        _strangerReturns(NETUID1, first, swept / 2);
        _strangerReturns(NETUID1, second, swept - swept / 2);
    }

    function zeroPaySlots() external view returns (uint256) {
        (bytes32[] memory hotkeys,,) = resolvedSlots();
        return _zeroPaySlots(hotkeys, NETUID1);
    }

    function anySlotShort() external view returns (bool) {
        (,, bool[] memory short) = resolvedSlots();
        for (uint256 i; i < short.length; ++i) {
            if (short[i]) return true;
        }
        return false;
    }

    function everySlotOnItsRecordedHotkey() external view returns (bool) {
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        for (uint256 i; i < slots.length; ++i) {
            if (_getVaultStake(slots[i].stakedUnder, NETUID1) + BACKING_SLACK_RAO < slots[i].tracked) return false;
        }
        return true;
    }

    function resolvedBacking() public view returns (uint256 total) {
        (, uint256[] memory balances,) = resolvedSlots();
        for (uint256 i; i < balances.length; ++i) {
            total += balances[i];
        }
    }

    /// @dev The fewest assets the shares can be worth: alpha exits add unrecorded stake but never drop backing.
    function leastAssetsFor(uint256 shares) public view returns (uint256) {
        return shares * (resolvedBacking() + 1) / (vault.totalSupply(TOKEN1) + 1e9);
    }

    /// @dev A full TAO exit sells the whole backing, without the virtual-share slice.
    function taoExitAssets(uint256 shares) external view returns (uint256) {
        return shares == vault.totalSupply(TOKEN1) ? resolvedBacking() : leastAssetsFor(shares);
    }

    function sellsASlotWithin(uint256 assets, uint256 excludedSlots) external view returns (bool) {
        (bytes32[] memory hotkeys,,) = resolvedSlots();
        return _taoExitSellsWithin(hotkeys, assets, excludedSlots, NETUID1);
    }

    function taoValueAtRead(uint256 alpha) public view returns (uint256) {
        return alpha * _alphaPriceRead(NETUID1) / 1e18;
    }

    function parked() public view returns (bool) {
        (, uint256 parkedAtNonce) = vault.recovery(TOKEN1);
        return parkedAtNonce != 0 && registry.nonces(NETUID1) == parkedAtNonce;
    }

    /// @dev The documented hotkey assignment for the attested set. A funded slot keeps its resolved hotkey. An empty
    ///      or new slot takes its slot's hotkey while it has an owner record and no outgoing edge, else the attested
    ///      hotkey while it has an owner record and no other attested slot holds it, else that hotkey's successor
    ///      while it has an owner record; `usable` marks such a hotkey. The assignment collides when an empty or new
    ///      slot settles on another attested hotkey, a hotkey another attested slot holds, or a hotkey already assigned.
    function attestedAssignment()
        public
        view
        returns (bytes32[] memory attested, bytes32[] memory stakingHotkeys, bool[] memory usable, bool collides)
    {
        (attested,) = registry.getValidators(NETUID1);
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        (bytes32[] memory hotkeys, uint256[] memory balances,) = resolvedSlots();
        stakingHotkeys = new bytes32[](attested.length);
        usable = new bool[](attested.length);
        for (uint256 i; i < attested.length; ++i) {
            bytes32 attestedHotkey = attested[i];
            uint256 slot = _slotOf(slots, attestedHotkey);
            if (slot != type(uint256).max && balances[slot] != 0) {
                stakingHotkeys[i] = hotkeys[slot];
                usable[i] = _hasOwner(hotkeys[slot]);
                continue;
            }
            bool attestedHeld = _heldByAnotherAttestedSlot(hotkeys, slots, attested, attestedHotkey, slot);
            if (attestedHeld && slot == type(uint256).max) return (attested, stakingHotkeys, usable, true);
            bytes32 hotkey = slot != type(uint256).max ? hotkeys[slot] : attestedHotkey;
            bytes32 successor = _successorOf(hotkey);
            usable[i] = hotkey != attestedHotkey && successor == bytes32(0) && _hasOwner(hotkey);
            if (!usable[i]) {
                if (!attestedHeld && _hasOwner(attestedHotkey)) {
                    hotkey = attestedHotkey;
                    usable[i] = true;
                } else if (successor != bytes32(0) && successor != attestedHotkey && _hasOwner(successor)) {
                    hotkey = successor;
                    usable[i] = true;
                }
            }
            if (
                hotkey != attestedHotkey
                    && (_contains(attested, hotkey)
                        || _heldByAnotherAttestedSlot(hotkeys, slots, attested, hotkey, slot))
            ) {
                return (attested, stakingHotkeys, usable, true);
            }
            if (hotkey != attestedHotkey && _contains(stakingHotkeys, hotkey)) {
                return (attested, stakingHotkeys, usable, true);
            }
            stakingHotkeys[i] = hotkey;
        }
    }

    /// @dev The attested hotkey a completed assignment reports as retired: the first with no usable hotkey.
    function firstRetiredAttestedHotkey() external view returns (bytes32) {
        (bytes32[] memory attested,, bool[] memory usable, bool collides) = attestedAssignment();
        if (collides) return bytes32(0);
        for (uint256 i; i < attested.length; ++i) {
            if (!usable[i]) return attested[i];
        }
        return bytes32(0);
    }

    /// @dev Consolidation refuses only when a resolved hotkey outside the assignment holds stake and even the richest
    ///      pile among those hotkeys, the assigned hotkeys and `deposit`, which lands on an assigned hotkey first, is below the
    ///      floor at any price.
    function consolidationBelowFloor(uint256 deposit) external view returns (bool) {
        (, bytes32[] memory stakingHotkeys,,) = attestedAssignment();
        (bytes32[] memory hotkeys, uint256[] memory balances,) = resolvedSlots();
        uint256 richest = deposit;
        bool rotatedOut;
        for (uint256 i; i < hotkeys.length; ++i) {
            if (_contains(stakingHotkeys, hotkeys[i])) continue;
            if (balances[i] != 0) rotatedOut = true;
            if (balances[i] > richest) richest = balances[i];
        }
        for (uint256 i; i < stakingHotkeys.length; ++i) {
            uint256 held = _getVaultStake(stakingHotkeys[i], NETUID1);
            if (held > richest) richest = held;
        }
        return rotatedOut && _belowFloorAtAnyPrice(richest);
    }

    /// @dev Annexing refuses only when the stray holds stake and neither it nor the first slot's hotkey holds a pile that
    ///      clears the floor at any price.
    function annexBelowFloor(bytes32 source) external view returns (bool) {
        (bytes32[] memory hotkeys,,) = resolvedSlots();
        uint256 stray = _getVaultStake(source, NETUID1);
        uint256 home = _getVaultStake(hotkeys[0], NETUID1);
        return stray != 0 && _belowFloorAtAnyPrice(stray > home ? stray : home);
    }

    /// @dev An alpha exit refuses to gather only when even the largest pile it pays from, after consolidation, is below
    ///      the floor at any price.
    function gatherBelowFloor() external view returns (bool) {
        uint256[] memory piles = _pilesAfterConsolidation();
        uint256 largest;
        for (uint256 i; i < piles.length; ++i) {
            if (piles[i] > largest) largest = piles[i];
        }
        return _belowFloorAtAnyPrice(largest);
    }

    /// @dev A parked exit pays from the resolved slots as they are. Otherwise consolidation rolls every dropped hotkey's
    ///      stake onto the first assigned hotkey, starting from an assigned hotkey's pile when no dropped pile is richer, so
    ///      that pile ends there too. Assigned hotkeys count stake the record does not know about.
    function _pilesAfterConsolidation() private view returns (uint256[] memory piles) {
        (bytes32[] memory hotkeys, uint256[] memory balances,) = resolvedSlots();
        if (parked()) return balances;
        (, bytes32[] memory stakingHotkeys,,) = attestedAssignment();
        piles = new uint256[](stakingHotkeys.length);
        for (uint256 i; i < stakingHotkeys.length; ++i) {
            piles[i] = _getVaultStake(stakingHotkeys[i], NETUID1);
        }
        uint256 droppedTotal;
        uint256 richestDropped;
        for (uint256 i; i < hotkeys.length; ++i) {
            if (_contains(stakingHotkeys, hotkeys[i])) continue;
            droppedTotal += balances[i];
            if (balances[i] > richestDropped) richestDropped = balances[i];
        }
        if (droppedTotal == 0) return piles;
        uint256 richest;
        uint256 richestIndex;
        for (uint256 i; i < piles.length; ++i) {
            if (piles[i] > richest) (richest, richestIndex) = (piles[i], i);
        }
        if (richest >= richestDropped && richestIndex != 0) {
            piles[0] += piles[richestIndex];
            piles[richestIndex] = 0;
        }
        piles[0] += droppedTotal;
    }

    /// @dev An open recovery stays unchanged only while parking does not cover the obligation and the sync has nothing
    ///      to collect: no other recorded hotkey holds stake, or the richest recorded pile is below the floor.
    function recoveryCannotAdvance() external view returns (bool) {
        uint256 parkingStake = _parkedStake(NETUID1);
        if (parkingStake + BACKING_SLACK_RAO >= trackedBacking()) return false;
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        uint256 richest = parkingStake;
        bool exposed;
        for (uint256 i; i < slots.length; ++i) {
            if (slots[i].stakedUnder == vault.parkingHotkey()) continue;
            uint256 held = _getVaultStake(slots[i].stakedUnder, NETUID1);
            if (held > richest) richest = held;
            if (held != 0) exposed = true;
        }
        return !exposed || taoValueAtRead(richest) < CHAIN_MIN_STAKE;
    }

    function nothingToCollectFrom(bytes32 source) external view returns (bool) {
        uint256 held = _getVaultStake(source, NETUID1);
        (uint256 shortSince,) = vault.recovery(TOKEN1);
        if (shortSince == 0) {
            (bytes32[] memory hotkeys,,) = resolvedSlots();
            return held == 0 || _contains(hotkeys, source);
        }
        if (source == vault.parkingHotkey() || held == 0) return true;
        uint256 parkedHeld = _parkedStake(NETUID1);
        return _belowFloorAtAnyPrice(held > parkedHeld ? held : parkedHeld);
    }

    function _belowFloorAtAnyPrice(uint256 alpha) private view returns (bool) {
        return alpha != 0 && alpha * (_alphaPriceRead(NETUID1) + 1e9) / 1e18 < CHAIN_MIN_STAKE;
    }

    function _successorOf(bytes32 hotkey) private view returns (bytes32) {
        (bool exists, bytes32 successor) = MockStaking(STAKING_PRECOMPILE).getHotkeySuccessor(hotkey, uint16(NETUID1));
        return exists && successor != hotkey ? successor : bytes32(0);
    }

    function _slotOf(VaultReads.Slot[] memory slots, bytes32 attestedHotkey) private pure returns (uint256) {
        for (uint256 i; i < slots.length; ++i) {
            if (slots[i].attested == attestedHotkey) return i;
        }
        return type(uint256).max;
    }

    /// @dev A hotkey another slot resolves to while that slot's attestedHotkey is still attested.
    function _heldByAnotherAttestedSlot(
        bytes32[] memory hotkeys,
        VaultReads.Slot[] memory slots,
        bytes32[] memory attested,
        bytes32 hotkey,
        uint256 ownSlot
    ) private pure returns (bool) {
        uint256 holder = _indexOf(hotkeys, hotkey);
        if (holder == type(uint256).max || holder == ownSlot) return false;
        return _contains(attested, slots[holder].attested);
    }

    function _hasOwner(bytes32 hotkey) internal view returns (bool exists) {
        (exists,) = MockStaking(STAKING_PRECOMPILE).getHotkeyOwner(hotkey);
    }

    function _contains(bytes32[] memory hotkeys, bytes32 hotkey) private pure returns (bool) {
        return _indexOf(hotkeys, hotkey) != type(uint256).max;
    }

    function _indexOf(bytes32[] memory hotkeys, bytes32 hotkey) private pure returns (uint256) {
        for (uint256 i; i < hotkeys.length; ++i) {
            if (hotkeys[i] == hotkey) return i;
        }
        return type(uint256).max;
    }

    function trackedBacking() public view returns (uint256 owed) {
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        for (uint256 i; i < slots.length; ++i) {
            owed += slots[i].tracked;
        }
    }

    function assertRecordMatchesChain() external view returns (uint256 tracked) {
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        for (uint256 i; i < slots.length; ++i) {
            assertEq(
                slots[i].tracked,
                _getVaultStake(slots[i].stakedUnder, NETUID1),
                "the rewritten record tracks the clone's stake"
            );
            tracked += slots[i].tracked;
        }
    }

    /// @dev Every hotkey the campaign touched plus the parking hotkey, where recoveries and write-offs land.
    function watchedHotkeys() public view returns (bytes32[] memory watched) {
        bytes32[] memory known = _campaign().knownHotkeys();
        watched = new bytes32[](known.length + 1);
        for (uint256 i; i < known.length; ++i) {
            watched[i] = known[i];
        }
        watched[known.length] = vault.parkingHotkey();
    }

    function vaultStakeAt(bytes32 hotkey) external view returns (uint256) {
        return _getVaultStake(hotkey, NETUID1);
    }

    function vaultStakesAt(bytes32[] memory hotkeys) external view returns (uint256[] memory stakes) {
        stakes = new uint256[](hotkeys.length);
        for (uint256 i; i < hotkeys.length; ++i) {
            stakes[i] = _getVaultStake(hotkeys[i], NETUID1);
        }
    }

    function recordedStakeAmong(bytes32[] memory watched, uint256[] memory stakes)
        external
        view
        returns (uint256 total)
    {
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        for (uint256 i; i < slots.length; ++i) {
            uint256 index = _indexOf(watched, slots[i].stakedUnder);
            assertTrue(index != type(uint256).max, "the record names a hotkey the campaign never touched");
            total += stakes[index];
        }
    }

    function chainHoldings() public view returns (uint256) {
        return stakeOf(_subnetColdkey(NETUID1));
    }

    function stakeOf(bytes32 coldkey) public view returns (uint256) {
        return _stakeAcross(watchedHotkeys(), coldkey, NETUID1);
    }

    function parkedStake() external view returns (uint256) {
        return _parkedStake(NETUID1);
    }

    function cloneColdkey() external view returns (bytes32) {
        return _subnetColdkey(NETUID1);
    }

    function depositTo(address user, uint256 amount) external {
        _simulateAlphaDeposit(user, NETUID1, amount);
    }

    function mailboxStake(address user) external view returns (uint256) {
        bytes32 mailboxColdkey = _mailboxColdkey(user, NETUID1);
        return _getStakeForColdkey(mailboxColdkey, mailboxColdkey, NETUID1);
    }

    function attest(bytes32[] memory set) external {
        for (uint256 i; i < set.length; ++i) {
            _simulateHotkeyOwnerPresent(set[i]);
        }
        _setValidators(NETUID1, set, _evenWeights(set.length));
        attestedHotkeys = set;
    }

    /// @dev Emissions accrue to the stake already held under the recorded hotkeys, in equal parts.
    function accrueEmissions(uint256 amount) external {
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        uint256 funded;
        for (uint256 i; i < slots.length; ++i) {
            if (_getStakeForColdkey(slots[i].stakedUnder, coldkey, NETUID1) != 0) ++funded;
        }
        if (funded == 0) return;
        for (uint256 i; i < slots.length; ++i) {
            uint256 held = _getStakeForColdkey(slots[i].stakedUnder, coldkey, NETUID1);
            if (held != 0) {
                MockStaking(STAKING_PRECOMPILE).setStake(slots[i].stakedUnder, coldkey, NETUID1, held + amount / funded);
            }
        }
    }

    function _assertNoTwoSlotsAnswerForOneHotkey() internal view {
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        for (uint256 i; i < slots.length; ++i) {
            for (uint256 j = i + 1; j < slots.length; ++j) {
                assertTrue(slots[i].stakedUnder != slots[j].stakedUnder, "two slots answer for one hotkey");
            }
        }
    }

    function _assertTrackedBackingWithinChainHoldings() internal view {
        uint256 slots = vault.recordedSlots(TOKEN1).length;
        assertLe(trackedBacking(), chainHoldings() + BACKING_SLACK_RAO * slots, "the record expects more than exists");
    }

    /// @dev Bounds the lens read itself, which follows successors without writing them back: one live balance
    ///      counted for two slots would exceed what the chain holds.
    function _assertReportedBackingWithinChainHoldings() internal view {
        assertLe(lens.locatedStake(TOKEN1), chainHoldings(), "the position reports backing the chain does not hold");
    }

    function _assertSharedInvariants() internal view {
        _assertTrackedBackingWithinChainHoldings();
        _assertReportedBackingWithinChainHoldings();
        _assertNoTwoSlotsAnswerForOneHotkey();
    }
}

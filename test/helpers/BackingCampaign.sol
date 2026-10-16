// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { AlphaVaultTestBase } from "../AlphaVaultTestBase.sol";
import { CHAIN_MIN_STAKE, MockStaking } from "../mocks/MockStaking.sol";
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

/// @dev A campaign call may fail only with an error its entry point is documented to raise; a panic, a refused chain
///      call (empty revert data) or any other error fails the campaign.
function requireExpectedRevert(bytes memory reason, bytes4[] memory expected) pure {
    bytes4 selector = bytes4(reason);
    for (uint256 i; i < expected.length; ++i) {
        if (selector == expected[i]) return;
    }
    assembly {
        revert(add(reason, 32), mload(reason))
    }
}

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

/// @dev Campaign deposits of 10 alpha or more clear the minimum stake at every campaign price.
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
        // The chain refuses stake operations on a hotkey without an owner record, so nothing lands there.
        if (!harness.depositTo(actor, bound(amount, 10, 1_000) * 1e9, hotkey)) return;
        uint256 deposit = harness.mailboxStake(actor, hotkey);
        vm.prank(actor);
        try vault.wrap(netuid, hotkey, 0) {
            ++wraps;
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
            assertLe(
                lastAlphaPaid * supply, shares * holdings + supply * harness.slack(), "an exit paid more than its share"
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
        uint256 shares = bound(shareSeed, 1, balance);
        uint256 excluded = harness.zeroPaySlots();
        vm.prank(actor);
        try vault.unwrapForTao(tokenId, shares, 0, excluded) {
            ++taoExits;
        } catch (bytes memory reason) {
            _requireJustifiedRevert(reason, unwrapForTaoErrors(), Attempt(0, shares, excluded, bytes32(0), true));
        }
    }

    function rebalance() external {
        try vault.rebalance(netuid) {
            ++rebalances;
            _afterAllocation();
        } catch (bytes memory reason) {
            _requireJustifiedRevert(reason, rebalanceErrors(), Attempt(0, 0, 0, bytes32(0), false));
        }
    }

    function syncBacking() external {
        (uint256 shortSinceBefore,) = vault.recovery(tokenId);
        try vault.syncBacking(tokenId) {
            ++syncs;
            (uint256 shortSinceAfter,) = vault.recovery(tokenId);
            if (shortSinceBefore != 0 && shortSinceAfter == 0) ++recoveriesClosed;
        } catch (bytes memory reason) {
            _requireJustifiedRevert(reason, syncErrors(), Attempt(0, 0, 0, bytes32(0), false));
        }
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

    /// @dev Runs after a wrap, rebalance or partial alpha exit succeeded, so every attested entry was live.
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
            assertEq(harness.firstRetiredName(), _firstWord(reason), "refused a name with a usable key");
        } else if (selector == IAlphaVaultAbi.SwappedHotkeyStillAttested.selector) {
            (,,, bool collides) = harness.attestedAssignment();
            assertTrue(collides, "refused an assignment without a collision");
        } else if (selector == IAlphaVaultAbi.ConsolidationBelowFloor.selector) {
            bool belowFloor = attempt.source == bytes32(0)
                ? harness.consolidationBelowFloor(attempt.deposit)
                : harness.annexBelowFloor(attempt.source);
            assertTrue(belowFloor, "refused to consolidate piles that clear the floor");
        } else if (selector == IAlphaVaultAbi.GatherBelowFloor.selector) {
            assertTrue(harness.gatherBelowFloor(), "refused to gather piles that clear the floor");
        } else if (selector == NothingToRecover.selector) {
            assertTrue(harness.nothingToCollectFrom(attempt.source), "refused a collectable stray");
        } else if (selector == NothingToUnwrap.selector) {
            assertEq(harness.resolvedBacking(), 0, "refused an exit from funded backing");
        } else if (selector == BackingUnchanged.selector) {
            if (shortSince == 0) {
                assertTrue(harness.everySlotOnItsRecordedKey(), "refused to record a followed swap");
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

abstract contract BackingCampaignHarness is AlphaVaultTestBase {
    bytes32[] internal currentSet;

    function _campaign() internal view virtual returns (BackingCampaignHandler);

    function attestedSet() external view returns (bytes32[] memory) {
        return currentSet;
    }

    function slack() external pure returns (uint256) {
        return BACKING_SLACK_RAO;
    }

    function movePrice(uint256 priceSeed) external {
        _setAlphaPrice(NETUID1, _wholeRaoPrice(priceSeed));
    }

    /// @dev Each slot where the record finds it: the recorded key if that covers the slot within slack, else a
    ///      successor that covers it and no other slot holds; a slot neither covers is short.
    function resolvedSlots()
        public
        view
        returns (bytes32[] memory keys, uint256[] memory balances, bool[] memory short)
    {
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        keys = new bytes32[](slots.length);
        balances = new uint256[](slots.length);
        short = new bool[](slots.length);
        for (uint256 i; i < slots.length; ++i) {
            keys[i] = slots[i].active;
        }
        for (uint256 i; i < slots.length; ++i) {
            uint256 held = _getVaultStake(keys[i], NETUID1);
            if (held + BACKING_SLACK_RAO < slots[i].tracked) {
                bytes32 successor = _successorOf(keys[i]);
                uint256 successorHeld = _getVaultStake(successor, NETUID1);
                if (
                    successor != bytes32(0) && !_contains(keys, successor)
                        && successorHeld + BACKING_SLACK_RAO >= slots[i].tracked
                ) {
                    keys[i] = successor;
                    held = successorHeld;
                } else {
                    short[i] = true;
                }
            }
            balances[i] = held;
        }
    }

    function zeroPaySlots() external view returns (uint256) {
        (bytes32[] memory keys,,) = resolvedSlots();
        return _zeroPaySlots(keys, NETUID1);
    }

    function anySlotShort() external view returns (bool) {
        (,, bool[] memory short) = resolvedSlots();
        for (uint256 i; i < short.length; ++i) {
            if (short[i]) return true;
        }
        return false;
    }

    function everySlotOnItsRecordedKey() external view returns (bool) {
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        for (uint256 i; i < slots.length; ++i) {
            if (_getVaultStake(slots[i].active, NETUID1) + BACKING_SLACK_RAO < slots[i].tracked) return false;
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
        (bytes32[] memory keys,,) = resolvedSlots();
        return _taoExitSellsWithin(keys, assets, excludedSlots, NETUID1);
    }

    function taoValueAtRead(uint256 alpha) public view returns (uint256) {
        return alpha * _alphaPriceRead(NETUID1) / 1e18;
    }

    function parked() public view returns (bool) {
        (, uint256 parkedAtNonce) = vault.recovery(TOKEN1);
        return parkedAtNonce != 0 && registry.nonces(NETUID1) == parkedAtNonce;
    }

    /// @dev The documented key assignment for the attested set. A funded slot keeps its resolved key. An empty or new
    ///      slot takes the name while no other attested slot holds it, else its slot's key, else that key's successor,
    ///      each only while it has an owner record; `live` marks such a key. The assignment collides when an
    ///      empty or new slot settles on another attested name, a key another attested slot holds, or a key already
    ///      assigned.
    function attestedAssignment()
        public
        view
        returns (bytes32[] memory names, bytes32[] memory actives, bool[] memory live, bool collides)
    {
        (names,) = registry.getValidators(NETUID1);
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        (bytes32[] memory keys, uint256[] memory balances,) = resolvedSlots();
        actives = new bytes32[](names.length);
        live = new bool[](names.length);
        for (uint256 i; i < names.length; ++i) {
            bytes32 name = names[i];
            uint256 slot = _slotOf(slots, name);
            if (slot != type(uint256).max && balances[slot] != 0) {
                actives[i] = keys[slot];
                live[i] = _hasOwner(keys[slot]);
                continue;
            }
            bool nameHeld = _heldByAnotherAttestedSlot(keys, slots, names, name, slot);
            if (nameHeld && slot == type(uint256).max) return (names, actives, live, true);
            bytes32 key = name;
            live[i] = !nameHeld && _hasOwner(name);
            if (!live[i]) {
                if (slot != type(uint256).max) key = keys[slot];
                live[i] = key != name && _hasOwner(key);
                bytes32 successor = _successorOf(key);
                if (!live[i] && successor != bytes32(0) && successor != name && _hasOwner(successor)) {
                    key = successor;
                    live[i] = true;
                }
                if (key != name && (_contains(names, key) || _heldByAnotherAttestedSlot(keys, slots, names, key, slot)))
                {
                    return (names, actives, live, true);
                }
            }
            if (key != name && _contains(actives, key)) return (names, actives, live, true);
            actives[i] = key;
        }
    }

    /// @dev The name a completed assignment reports as retired: the first with no usable key.
    function firstRetiredName() external view returns (bytes32) {
        (bytes32[] memory names,, bool[] memory live, bool collides) = attestedAssignment();
        if (collides) return bytes32(0);
        for (uint256 i; i < names.length; ++i) {
            if (!live[i]) return names[i];
        }
        return bytes32(0);
    }

    /// @dev Consolidation refuses only when a resolved key outside the assignment holds stake and even the richest
    ///      pile among those keys, the assigned keys and `deposit`, which lands on an assigned key first, is below the
    ///      floor at any price.
    function consolidationBelowFloor(uint256 deposit) external view returns (bool) {
        (, bytes32[] memory actives,,) = attestedAssignment();
        (bytes32[] memory keys, uint256[] memory balances,) = resolvedSlots();
        uint256 richest = deposit;
        bool rotatedOut;
        for (uint256 i; i < keys.length; ++i) {
            if (_contains(actives, keys[i])) continue;
            if (balances[i] != 0) rotatedOut = true;
            if (balances[i] > richest) richest = balances[i];
        }
        for (uint256 i; i < actives.length; ++i) {
            uint256 held = _getVaultStake(actives[i], NETUID1);
            if (held > richest) richest = held;
        }
        return rotatedOut && _belowFloorAtAnyPrice(richest);
    }

    /// @dev Annexing refuses only when the stray holds stake and neither it nor the first slot's key holds a pile that
    ///      clears the floor at any price.
    function annexBelowFloor(bytes32 source) external view returns (bool) {
        (bytes32[] memory keys,,) = resolvedSlots();
        uint256 stray = _getVaultStake(source, NETUID1);
        uint256 home = _getVaultStake(keys[0], NETUID1);
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

    /// @dev A parked exit pays from the resolved slots as they are. Otherwise consolidation rolls every dropped key's
    ///      stake onto the first assigned key, starting from an assigned key's pile when no dropped pile is richer, so
    ///      that pile ends there too. Assigned keys count stake the record does not know about.
    function _pilesAfterConsolidation() private view returns (uint256[] memory piles) {
        (bytes32[] memory keys, uint256[] memory balances,) = resolvedSlots();
        if (parked()) return balances;
        (, bytes32[] memory actives,,) = attestedAssignment();
        piles = new uint256[](actives.length);
        for (uint256 i; i < actives.length; ++i) {
            piles[i] = _getVaultStake(actives[i], NETUID1);
        }
        uint256 droppedTotal;
        uint256 richestDropped;
        for (uint256 i; i < keys.length; ++i) {
            if (_contains(actives, keys[i])) continue;
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
    ///      to collect: no other recorded key holds stake, or the richest recorded pile is below the floor.
    function recoveryCannotAdvance() external view returns (bool) {
        uint256 parkedStake = _parkedStake(NETUID1);
        if (parkedStake + BACKING_SLACK_RAO >= trackedBacking()) return false;
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        uint256 richest = parkedStake;
        bool exposed;
        for (uint256 i; i < slots.length; ++i) {
            if (slots[i].active == vault.parkingHotkey()) continue;
            uint256 held = _getVaultStake(slots[i].active, NETUID1);
            if (held > richest) richest = held;
            if (held != 0) exposed = true;
        }
        return !exposed || taoValueAtRead(richest) < CHAIN_MIN_STAKE;
    }

    function nothingToCollectFrom(bytes32 source) external view returns (bool) {
        uint256 held = _getVaultStake(source, NETUID1);
        if (source == vault.parkingHotkey() || held == 0) return true;
        (bytes32[] memory keys,,) = resolvedSlots();
        if (_contains(keys, source)) return true;
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

    function _slotOf(VaultReads.Slot[] memory slots, bytes32 name) private pure returns (uint256) {
        for (uint256 i; i < slots.length; ++i) {
            if (slots[i].logical == name) return i;
        }
        return type(uint256).max;
    }

    /// @dev A key another slot resolves to while that slot's name is still attested.
    function _heldByAnotherAttestedSlot(
        bytes32[] memory keys,
        VaultReads.Slot[] memory slots,
        bytes32[] memory names,
        bytes32 key,
        uint256 ownSlot
    ) private pure returns (bool) {
        uint256 holder = _indexOf(keys, key);
        if (holder == type(uint256).max || holder == ownSlot) return false;
        return _contains(names, slots[holder].logical);
    }

    function _hasOwner(bytes32 hotkey) private view returns (bool exists) {
        (exists,) = MockStaking(STAKING_PRECOMPILE).getHotkeyOwner(hotkey);
    }

    function _contains(bytes32[] memory keys, bytes32 key) private pure returns (bool) {
        return _indexOf(keys, key) != type(uint256).max;
    }

    function _indexOf(bytes32[] memory keys, bytes32 key) private pure returns (uint256) {
        for (uint256 i; i < keys.length; ++i) {
            if (keys[i] == key) return i;
        }
        return type(uint256).max;
    }

    function trackedBacking() public view returns (uint256 owed) {
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        for (uint256 i; i < slots.length; ++i) {
            owed += slots[i].tracked;
        }
    }

    /// @dev Every key the campaign touched plus the parking hotkey, where recoveries and write-offs land.
    function chainHoldings() public view returns (uint256) {
        return _vaultStakeAcross(_campaign().knownHotkeys(), NETUID1) + _parkedStake(NETUID1);
    }

    function stakeOf(bytes32 coldkey) external view returns (uint256) {
        return _stakeAcross(_campaign().knownHotkeys(), coldkey, NETUID1)
            + _getStakeForColdkey(vault.parkingHotkey(), coldkey, NETUID1);
    }

    function depositTo(address user, uint256 amount, bytes32 hotkey) external returns (bool deposited) {
        (deposited,) = MockStaking(STAKING_PRECOMPILE).getHotkeyOwner(hotkey);
        if (deposited) _simulateAlphaDepositHotkey(user, NETUID1, amount, hotkey);
    }

    function mailboxStake(address user, bytes32 hotkey) external view returns (uint256) {
        return _getStakeForColdkey(hotkey, _mailboxColdkey(user, NETUID1), NETUID1);
    }

    function attest(bytes32[] memory set) external {
        for (uint256 i; i < set.length; ++i) {
            _simulateHotkeyOwnerPresent(set[i]);
        }
        _setValidators(NETUID1, set, _evenWeights(set.length));
        currentSet = set;
    }

    /// @dev Emissions accrue to the stake already held under the recorded keys, in equal parts.
    function accrueEmissions(uint256 amount) external {
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        uint256 funded;
        for (uint256 i; i < slots.length; ++i) {
            if (_getStakeForColdkey(slots[i].active, coldkey, NETUID1) != 0) ++funded;
        }
        if (funded == 0) return;
        for (uint256 i; i < slots.length; ++i) {
            uint256 held = _getStakeForColdkey(slots[i].active, coldkey, NETUID1);
            if (held != 0) {
                MockStaking(STAKING_PRECOMPILE).setStake(slots[i].active, coldkey, NETUID1, held + amount / funded);
            }
        }
    }

    function _assertNoTwoSlotsAnswerForOneKey() internal view {
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        for (uint256 i; i < slots.length; ++i) {
            for (uint256 j = i + 1; j < slots.length; ++j) {
                assertTrue(slots[i].active != slots[j].active, "two slots answer for one key");
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
        _assertNoTwoSlotsAnswerForOneKey();
    }
}

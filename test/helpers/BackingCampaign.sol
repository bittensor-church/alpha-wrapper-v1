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
            assertTrue(
                harness.ownerHoldsNoReceivingKeyFor(_firstWord(reason)), "refused a name its owner can receive on"
            );
        } else if (selector == IAlphaVaultAbi.SwappedHotkeyStillAttested.selector) {
            assertTrue(harness.anySwapOnRecord(), "refused a swap that never happened");
        } else if (
            selector == IAlphaVaultAbi.ConsolidationBelowFloor.selector
                || selector == IAlphaVaultAbi.GatherBelowFloor.selector
        ) {
            assertTrue(harness.holdsASubFloorPile(attempt.source), "refused piles that clear the floor");
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

    // --- Independent reads of the state a refusal claims ------------------------------------------------------

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

    /// @dev Some eligible slot either drains within `assets`, or sells all of `assets` as a partial whose sale clears
    ///      the minimum stake and whose leftover clears the nominator minimum at the read price.
    function sellsASlotWithin(uint256 assets, uint256 excludedSlots) external view returns (bool) {
        (, uint256[] memory balances,) = resolvedSlots();
        for (uint256 i; i < balances.length; ++i) {
            uint256 balance = (excludedSlots >> i) & 1 == 0 ? balances[i] : 0;
            if (balance == 0) continue;
            if (balance <= assets) return true;
            if (taoValueAtRead(assets) >= CHAIN_MIN_STAKE && taoValueAtRead(balance - assets) > DUST_THRESHOLD) {
                return true;
            }
        }
        return false;
    }

    function taoValueAtRead(uint256 alpha) public view returns (uint256) {
        return alpha * _alphaPriceRead(NETUID1) / 1e18;
    }

    function parked() external view returns (bool) {
        (, uint256 parkedAtNonce) = vault.recovery(TOKEN1);
        return parkedAtNonce != 0 && registry.nonces(NETUID1) == parkedAtNonce;
    }

    /// @dev A funded slot keeps its resolved key. An empty or new slot may take the name while no other attested slot
    ///      holds it, its slot's key, or that key's successor. The name retires only when its owner holds none of them.
    function ownerHoldsNoReceivingKeyFor(bytes32 name) external view returns (bool) {
        (bytes32[] memory names,, bytes32[] memory owners) = registry.getValidators(NETUID1);
        uint256 index = _indexOf(names, name);
        if (index == type(uint256).max) return false;
        bytes32 owner = owners[index];
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        (bytes32[] memory keys, uint256[] memory balances,) = resolvedSlots();
        uint256 slot = type(uint256).max;
        for (uint256 i; i < slots.length; ++i) {
            if (slots[i].logical == name) {
                slot = i;
                break;
            }
        }
        if (slot != type(uint256).max && balances[slot] != 0) return !_ownedBy(keys[slot], owner);

        uint256 nameHolder = _indexOf(keys, name);
        bool nameFree =
            nameHolder == type(uint256).max || nameHolder == slot || !_contains(names, slots[nameHolder].logical);
        bytes32 key = slot == type(uint256).max ? name : keys[slot];
        bytes32 successor = _successorOf(key);
        return !(nameFree && _ownedBy(name, owner)) && (key == name || !_ownedBy(key, owner))
            && (successor == name || !_ownedBy(successor, owner));
    }

    function anySwapOnRecord() external view returns (bool) {
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        for (uint256 i; i < slots.length; ++i) {
            if (slots[i].active != slots[i].logical || _successorOf(slots[i].active) != bytes32(0)) return true;
        }
        for (uint256 i; i < currentSet.length; ++i) {
            if (_successorOf(currentSet[i]) != bytes32(0)) return true;
        }
        return false;
    }

    /// @dev Some recorded or attested key, a successor of one, or the stray being collected holds a nonzero pile
    ///      below the floor even at the highest price the rounded read can hide.
    function holdsASubFloorPile(bytes32 source) external view returns (bool) {
        if (_belowFloorAtAnyPrice(_getVaultStake(source, NETUID1))) return true;
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        bytes32[] memory keys = new bytes32[](slots.length + currentSet.length);
        for (uint256 i; i < slots.length; ++i) {
            keys[i] = slots[i].active;
        }
        for (uint256 i; i < currentSet.length; ++i) {
            keys[slots.length + i] = currentSet[i];
        }
        for (uint256 i; i < keys.length; ++i) {
            if (_belowFloorAtAnyPrice(_getVaultStake(keys[i], NETUID1))) return true;
            if (_belowFloorAtAnyPrice(_getVaultStake(_successorOf(keys[i]), NETUID1))) return true;
        }
        return false;
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

    function _ownedBy(bytes32 hotkey, bytes32 coldkey) private view returns (bool) {
        (bool exists, bytes32 owner) = MockStaking(STAKING_PRECOMPILE).getHotkeyOwner(hotkey);
        return exists && owner == coldkey;
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

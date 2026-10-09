// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { AlphaVaultTestBase } from "../AlphaVaultTestBase.sol";
import { MockStaking } from "../mocks/MockStaking.sol";
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
    WithdrawTooSmall,
    ZeroAmount
} from "src/VaultErrors.sol";

/// @dev A campaign call may fail only with an error its entry point is documented to raise on that state; a
///      panic, a refused chain call (empty revert data) or any other error fails the campaign.
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

function wrapErrors() pure returns (bytes4[] memory errors) {
    uint256 next;
    (errors, next) = backingErrors(3);
    errors[next] = Parked.selector;
    errors[next + 1] = IAlphaVaultAbi.DepositTooSmall.selector;
    errors[next + 2] = ZeroAmount.selector;
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

abstract contract BackingCampaignHandler is Test {
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
        if (harness.wrapFor(_actor(actorSeed), bound(amount, 10, 1_000) * 1e9, _attested(hotkeySeed))) {
            ++wraps;
            _afterAllocation();
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
            requireExpectedRevert(reason, unwrapErrors());
        }
    }

    function unwrapForTao(uint256 actorSeed, uint256 shareSeed) external {
        address actor = _actor(actorSeed);
        uint256 balance = vault.balanceOf(actor, tokenId);
        if (balance == 0) return;
        vm.prank(actor);
        try vault.unwrapForTao(tokenId, bound(shareSeed, 1, balance), 0) {
            ++taoExits;
        } catch (bytes memory reason) {
            requireExpectedRevert(reason, unwrapForTaoErrors());
        }
    }

    function rebalance() external {
        try vault.rebalance(netuid) {
            ++rebalances;
            _afterAllocation();
        } catch (bytes memory reason) {
            requireExpectedRevert(reason, rebalanceErrors());
        }
    }

    function syncBacking() external {
        (uint256 shortSinceBefore,) = vault.recovery(tokenId);
        try vault.syncBacking(tokenId) {
            ++syncs;
            (uint256 shortSinceAfter,) = vault.recovery(tokenId);
            if (shortSinceBefore != 0 && shortSinceAfter == 0) ++recoveriesClosed;
        } catch (bytes memory reason) {
            requireExpectedRevert(reason, syncErrors());
        }
    }

    function passTime(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1 minutes, 4 hours));
    }

    function movePrice(uint256 priceSeed) external {
        harness.setPrice(bound(priceSeed, 1e6, 2e8) * 1e9);
    }

    function accrueEmissions(uint256 amount) external {
        harness.accrueEmissions(bound(amount, 1, 300) * 1e9);
    }

    /// @dev Runs after a wrap, rebalance or partial alpha exit succeeded, so every attested entry was live.
    function _afterAllocation() internal virtual { }

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

    /// @dev The chain refuses stake operations on a hotkey without an owner record, so nothing lands there.
    function wrapFor(address user, uint256 amount, bytes32 hotkey) external returns (bool wrapped) {
        (bool owned,) = MockStaking(STAKING_PRECOMPILE).getHotkeyOwner(hotkey);
        if (!owned) return false;
        _simulateAlphaDepositHotkey(user, NETUID1, amount, hotkey);
        vm.prank(user);
        try vault.wrap(NETUID1, hotkey, 0) {
            wrapped = true;
        } catch (bytes memory reason) {
            requireExpectedRevert(reason, wrapErrors());
        }
    }

    function attest(bytes32[] memory set) external {
        for (uint256 i; i < set.length; ++i) {
            _simulateHotkeyOwnerPresent(set[i]);
        }
        _setValidators(NETUID1, set, _evenWeights(set.length));
        currentSet = set;
    }

    function setPrice(uint256 alphaPriceE18) external {
        _setAlphaPrice(NETUID1, alphaPriceE18);
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

    function _assertSharedInvariants() internal view {
        _assertTrackedBackingWithinChainHoldings();
        _assertNoTwoSlotsAnswerForOneKey();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { MAX_VALIDATORS } from "src/interfaces/IValidatorRegistry.sol";

/// @dev Even weights over 64 validators are 156 bps each and 172 bps for the last; over 3, 3333, 3333 and 3334.
contract DynamicValidatorSetTest is AlphaVaultTestBase {
    uint256 private constant DEPOSIT = 10_000 * ALPHA;

    /// @dev Keeps every target of a 64-validator spread above the 0.04-alpha move floor at 0.05 TAO/alpha.
    uint256 private constant MIN_SPREADABLE = 10 * ALPHA;

    function _assertSpreadOnNetuid1(bytes32[] memory hks, uint256 eachStake, uint256 lastStake) private view {
        _assertSpread(hks, _subnetColdkey(NETUID1), NETUID1, eachStake, lastStake);
    }

    function test_Wrap_SpreadsAcrossFullValidatorCap() public {
        bytes32[] memory hks = _setValidatorCount(NETUID1, MAX_VALIDATORS);
        _depositAndWrap(alice, NETUID1, DEPOSIT);

        _assertSpreadOnNetuid1(hks, 156 * ALPHA, 172 * ALPHA);
        assertEq(lens.totalStake(TOKEN1), DEPOSIT);
    }

    function test_Wrap_StakesWholePositionOnSingleValidator() public {
        bytes32[] memory hks = _setValidatorCount(NETUID1, 1);
        _depositAndWrap(alice, NETUID1, DEPOSIT);

        assertEq(_getVaultStake(hks[0], NETUID1), DEPOSIT);
        assertEq(lens.totalStake(TOKEN1), DEPOSIT);
    }

    function test_Rebalance_ShrinkFromCapLeavesNoStaleTail() public {
        bytes32[] memory wide = _setValidatorCount(NETUID1, MAX_VALIDATORS);
        _depositAndWrap(alice, NETUID1, DEPOSIT);

        bytes32[] memory narrow = _setValidatorCount(NETUID1, 3);
        vault.rebalance(NETUID1);

        for (uint256 i = 3; i < MAX_VALIDATORS; ++i) {
            assertEq(_getVaultStake(wide[i], NETUID1), 0, "dropped validator still funded");
        }
        assertEq(_lastSeen(TOKEN1).length, 3, "remembered set carries no stale tail");
        _assertSpreadOnNetuid1(narrow, 3_333 * ALPHA, 3_334 * ALPHA);
    }

    function test_Rebalance_GrowToCapSpreadsAcrossFullSet() public {
        _setValidatorCount(NETUID1, 3);
        _depositAndWrap(alice, NETUID1, DEPOSIT);

        bytes32[] memory wide = _setValidatorCount(NETUID1, MAX_VALIDATORS);
        vault.rebalance(NETUID1);

        _assertSpreadOnNetuid1(wide, 156 * ALPHA, 172 * ALPHA);
        assertEq(_lastSeen(TOKEN1).length, MAX_VALIDATORS);
    }

    /// @dev The dropped 0.172 alpha clears the move floor; most of the 63-way deficits it leaves (0.002 alpha) do not.
    function test_Rebalance_DrainsDroppedBalanceTooSmallToSpread() public {
        bytes32[] memory wide = _setValidatorCount(NETUID1, MAX_VALIDATORS);
        _depositAndWrap(alice, NETUID1, 10 * ALPHA);
        assertEq(_getVaultStake(wide[MAX_VALIDATORS - 1], NETUID1), 172_000_000, "172 bps of 10 alpha");

        _setValidatorCount(NETUID1, MAX_VALIDATORS - 1);
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(wide[MAX_VALIDATORS - 1], NETUID1), 0, "dropped validator swept");
        assertEq(lens.totalStake(TOKEN1), 10 * ALPHA, "total conserved");
        assertEq(_lastSeen(TOKEN1).length, MAX_VALIDATORS - 1, "nothing left to remember");
    }

    function test_Rebalance_SweepsFullRotationAtTheCap() public {
        bytes32[] memory first = _setValidatorCount(NETUID1, MAX_VALIDATORS);
        _depositAndWrap(alice, NETUID1, DEPOSIT);

        bytes32[] memory second = _hotkeysFrom("second-wave", MAX_VALIDATORS);
        _setValidators(NETUID1, second, _evenWeights(MAX_VALIDATORS));

        assertEq(lens.totalStake(TOKEN1), DEPOSIT, "the recorded slots still price the whole position");

        vault.rebalance(NETUID1);

        for (uint256 i; i < MAX_VALIDATORS; ++i) {
            assertEq(_getVaultStake(first[i], NETUID1), 0, "old set fully swept");
        }
        assertEq(_vaultStakeAcross(second, NETUID1), DEPOSIT, "whole position landed on the new set");
        assertEq(_lastSeen(TOKEN1).length, MAX_VALIDATORS);
    }

    function test_UnwrapForTao_ExitsFullyRotatedPosition() public {
        _setValidatorCount(NETUID1, 3);
        _depositAndWrap(alice, NETUID1, DEPOSIT);

        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(alice.balance, 500 * TAO, "10,000 alpha sold at 0.05 TAO");
        assertEq(lens.totalStake(TOKEN1), 0);
    }

    /// @dev At 5e-10 TAO/alpha the chain moves only piles of 200,000 alpha or more.
    function test_Rebalance_DrainsRotationAtUnreadablePrice() public {
        bytes32[] memory pair = _setValidatorCount(NETUID1, 2);
        _depositAndWrap(alice, NETUID1, 1_000_000 * ALPHA);
        _setAlphaPriceReadsZero(NETUID1);

        _setValidatorCount(NETUID1, 1);
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(pair[1], NETUID1), 0, "dropped validator swept");
        assertEq(_getVaultStake(pair[0], NETUID1), 1_000_000 * ALPHA);
    }

    function test_Wrap_KeepsSmallPositionWholeWhenTargetsFallBelowFloor() public {
        bytes32[] memory hks = _setValidatorCount(NETUID1, MAX_VALIDATORS);
        // Each slot's target is at most 0.0172 alpha, below the 0.04-alpha move floor.
        _depositAndWrap(alice, NETUID1, ALPHA);

        assertEq(_getVaultStake(hks[0], NETUID1), ALPHA, "position stays where it landed");
        assertEq(lens.totalStake(TOKEN1), ALPHA, "and is fully priced");
    }

    function testFuzz_Wrap_KeepsTheWholeDepositAcrossAnyValidatorCount(uint256 count, uint256 amount) public {
        count = bound(count, 1, MAX_VALIDATORS);
        amount = bound(amount, MIN_SPREADABLE, MAX_SUBNET_ALPHA);

        bytes32[] memory hks = _setValidatorCount(NETUID1, count);
        _depositAndWrap(alice, NETUID1, amount);

        assertEq(_vaultStakeAcross(hks, NETUID1), amount, "every validator slot together holds the deposit");
        assertEq(lens.totalStake(TOKEN1), amount);
    }

    function testFuzz_Rebalance_RotationPreservesTotal(uint256 fromCount, uint256 toCount, uint256 amount) public {
        fromCount = bound(fromCount, 1, MAX_VALIDATORS);
        toCount = bound(toCount, 1, MAX_VALIDATORS);
        amount = bound(amount, MIN_SPREADABLE, MAX_SUBNET_ALPHA);

        _setValidatorCount(NETUID1, fromCount);
        _depositAndWrap(alice, NETUID1, amount);

        bytes32[] memory rotated = _hotkeysFrom("rotated", toCount);
        _setValidators(NETUID1, rotated, _evenWeights(toCount));

        vault.rebalance(NETUID1);

        assertEq(_vaultStakeAcross(rotated, NETUID1), amount, "whole position moved to the new set");
        assertEq(lens.totalStake(TOKEN1), amount);
        assertEq(_lastSeen(TOKEN1).length, toCount, "the remembered set follows the new one");
    }

    function testFuzz_Unwrap_DeliversPreviewAtAnyValidatorCount(uint256 count, uint256 amount, uint256 burnBps) public {
        count = bound(count, 1, MAX_VALIDATORS);
        amount = bound(amount, MIN_SPREADABLE, MAX_SUBNET_ALPHA);
        // At least 1% of 10 alpha clears the 0.04-alpha exit floor.
        burnBps = bound(burnBps, 100, BPS_BASE);

        bytes32[] memory hks = _setValidatorCount(NETUID1, count);
        _depositAndWrap(alice, NETUID1, amount);

        uint256 shares = vault.balanceOf(alice, TOKEN1) * burnBps / BPS_BASE;
        (uint256 previewAlpha,) = lens.previewUnwrap(TOKEN1, shares);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        assertEq(_stakeAcross(hks, _toSubstrate(alice), NETUID1), previewAlpha, "delivery matches the quote");
        assertEq(lens.totalStake(TOKEN1), amount - previewAlpha, "only the delivered alpha left the vault");
    }
}

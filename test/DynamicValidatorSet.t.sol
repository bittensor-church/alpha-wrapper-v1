// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { DepositScenarios } from "./helpers/DepositScenarios.sol";

/// @dev Even weights over 10 validators are 1000 bps each; over 3, 3333, 3333 and 3334.
contract DynamicValidatorSetTest is DepositScenarios {
    function _assertSpreadOnNetuid1(bytes32[] memory hks, uint256 eachStake, uint256 lastStake) private view {
        _assertSpread(hks, _subnetColdkey(NETUID1), NETUID1, eachStake, lastStake);
    }

    function _assertEvenSpreadOnNetuid1(bytes32[] memory hks, uint256 amount) private view {
        uint256 eachStake = amount * _evenWeights(hks.length)[0] / BPS_BASE;
        _assertSpreadOnNetuid1(hks, eachStake, amount - (hks.length - 1) * eachStake);
    }

    function test_Wrap_SpreadsAcrossFullValidatorCap() public {
        bytes32[] memory hks = _setValidatorCount(NETUID1, VALIDATOR_CAP);
        _depositAndWrap(alice, NETUID1, SPREAD_DEPOSIT);

        _assertSpreadOnNetuid1(hks, 1_000 * ALPHA, 1_000 * ALPHA);
        assertEq(lens.totalStake(TOKEN1), SPREAD_DEPOSIT);
        assertEq(_lastSeen(TOKEN1), hks, "every attested hotkey is recorded");
    }

    function test_Wrap_StakesWholePositionOnSingleValidator() public {
        bytes32[] memory hks = _setValidatorCount(NETUID1, 1);
        _depositAndWrap(alice, NETUID1, SPREAD_DEPOSIT);

        assertEq(_getVaultStake(hks[0], NETUID1), SPREAD_DEPOSIT);
        assertEq(lens.totalStake(TOKEN1), SPREAD_DEPOSIT);
        assertEq(_lastSeen(TOKEN1), hks, "the sole validator is recorded");
    }

    function test_Rebalance_ShrinkFromCapLeavesNoStaleTail() public {
        bytes32[] memory wide = _setValidatorCount(NETUID1, VALIDATOR_CAP);
        _depositAndWrap(alice, NETUID1, SPREAD_DEPOSIT);

        bytes32[] memory narrow = _setValidatorCount(NETUID1, 3);
        vault.rebalance(NETUID1);

        for (uint256 i = 3; i < VALIDATOR_CAP; ++i) {
            assertEq(_getVaultStake(wide[i], NETUID1), 0, "dropped validator still funded");
        }
        assertEq(_lastSeen(TOKEN1), narrow, "the record carries no stale tail");
        _assertSpreadOnNetuid1(narrow, 3_333 * ALPHA, 3_334 * ALPHA);
    }

    function test_Rebalance_GrowToCapSpreadsAcrossFullSet() public {
        _setValidatorCount(NETUID1, 3);
        _depositAndWrap(alice, NETUID1, SPREAD_DEPOSIT);

        bytes32[] memory wide = _setValidatorCount(NETUID1, VALIDATOR_CAP);
        vault.rebalance(NETUID1);

        _assertSpreadOnNetuid1(wide, 1_000 * ALPHA, 1_000 * ALPHA);
        assertEq(_lastSeen(TOKEN1), wide, "the record grows to the full set");
    }

    /// @dev The dropped 1 alpha clears the floor; the 9-way deficits it leaves (0.111 alpha) do too.
    function test_Rebalance_DrainsDroppedBalanceAndSpreadsIt() public {
        bytes32[] memory wide = _setValidatorCount(NETUID1, VALIDATOR_CAP);
        _depositAndWrap(alice, NETUID1, 10 * ALPHA);
        assertEq(_getVaultStake(wide[9], NETUID1), ALPHA, "1000 bps of 10 alpha");

        bytes32[] memory nine = _setValidatorCount(NETUID1, 9);
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(wide[9], NETUID1), 0, "dropped validator swept");
        assertEq(lens.totalStake(TOKEN1), 10 * ALPHA, "total conserved");
        _assertSpreadOnNetuid1(nine, 1_111_000_000, 1_112_000_000);
        assertEq(_lastSeen(TOKEN1), nine, "the record drops the tenth validator");
    }

    function test_Rebalance_SweepsFullRotationAtTheCap() public {
        bytes32[] memory first = _setValidatorCount(NETUID1, VALIDATOR_CAP);
        _depositAndWrap(alice, NETUID1, SPREAD_DEPOSIT);

        bytes32[] memory second = _hotkeysFrom("second-wave", VALIDATOR_CAP);
        _setValidators(NETUID1, second, _evenWeights(VALIDATOR_CAP));

        assertEq(lens.totalStake(TOKEN1), SPREAD_DEPOSIT, "the recorded slots still price the whole position");

        vault.rebalance(NETUID1);

        for (uint256 i; i < VALIDATOR_CAP; ++i) {
            assertEq(_getVaultStake(first[i], NETUID1), 0, "old set fully swept");
        }
        _assertSpreadOnNetuid1(second, 1_000 * ALPHA, 1_000 * ALPHA);
        assertEq(_lastSeen(TOKEN1), second, "the record follows the new set");
    }

    function test_UnwrapForTao_ExitsFullyRotatedPosition() public {
        _setValidatorCount(NETUID1, 3);
        _depositAndWrap(alice, NETUID1, SPREAD_DEPOSIT);

        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, 500 * TAO, "10,000 alpha sold at 0.05 TAO");
        assertEq(lens.totalStake(TOKEN1), 0);
    }

    function test_Rebalance_DrainsRotationAtUnreadablePrice() public {
        bytes32[] memory pair = _setValidatorCount(NETUID1, 2);
        _depositAndWrap(alice, NETUID1, LARGE_POSITION);
        _setAlphaPriceReadsZero(NETUID1);

        _setValidatorCount(NETUID1, 1);
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(pair[1], NETUID1), 0, "dropped validator swept");
        assertEq(_getVaultStake(pair[0], NETUID1), LARGE_POSITION);
    }

    function test_Wrap_KeepsSmallPositionWholeWhenTargetsFallBelowFloor() public {
        bytes32[] memory hks = _setValidatorCount(NETUID1, VALIDATOR_CAP);
        // Each slot's target is 0.01 alpha, below the 0.04-alpha floor.
        _depositAndWrap(alice, NETUID1, ALPHA / 10);

        assertEq(_getVaultStake(hks[0], NETUID1), ALPHA / 10, "position stays where it landed");
        assertEq(lens.totalStake(TOKEN1), ALPHA / 10, "and is fully priced");
    }

    function testFuzz_Wrap_SpreadsTheDepositByWeightAcrossAnyValidatorCount(uint256 count, uint256 amount) public {
        count = bound(count, 1, VALIDATOR_CAP);
        amount = bound(amount, MIN_SPREADABLE, MAX_SUBNET_ALPHA);

        bytes32[] memory hks = _setValidatorCount(NETUID1, count);
        _depositAndWrap(alice, NETUID1, amount);

        _assertEvenSpreadOnNetuid1(hks, amount);
        assertEq(lens.totalStake(TOKEN1), amount);
    }

    function testFuzz_Rebalance_RotationSpreadsTheWholePositionOnTheNewSet(
        uint256 fromCount,
        uint256 toCount,
        uint256 amount
    ) public {
        fromCount = bound(fromCount, 1, VALIDATOR_CAP);
        toCount = bound(toCount, 1, VALIDATOR_CAP);
        amount = bound(amount, MIN_SPREADABLE, MAX_SUBNET_ALPHA);

        _setValidatorCount(NETUID1, fromCount);
        _depositAndWrap(alice, NETUID1, amount);

        bytes32[] memory rotated = _hotkeysFrom("rotated", toCount);
        _setValidators(NETUID1, rotated, _evenWeights(toCount));

        vault.rebalance(NETUID1);

        _assertEvenSpreadOnNetuid1(rotated, amount);
        assertEq(lens.totalStake(TOKEN1), amount);
        assertEq(_lastSeen(TOKEN1), rotated, "the record follows the new set");
    }

    function testFuzz_Unwrap_DeliversPreviewAtAnyValidatorCount(uint256 count, uint256 amount, uint256 burnBps) public {
        count = bound(count, 1, VALIDATOR_CAP);
        amount = bound(amount, MIN_SPREADABLE, MAX_SUBNET_ALPHA);
        // At least 1% of 10 alpha clears the 0.04-alpha exit floor.
        burnBps = bound(burnBps, 100, BPS_BASE);

        bytes32[] memory hks = _setValidatorCount(NETUID1, count);
        _depositAndWrap(alice, NETUID1, amount);

        uint256 shares = vault.balanceOf(alice, TOKEN1) * burnBps / BPS_BASE;
        (uint256 previewAlpha,) = lens.previewUnwrap(TOKEN1, shares);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        // A first deposit backs 1e9 shares with each RAO, so a burn is worth shares / 1e9.
        assertEq(previewAlpha, shares / 1e9, "the quote prices the burn at the first-deposit rate");
        assertEq(_stakeAcross(hks, _toSubstrate(alice), NETUID1), shares / 1e9, "delivery matches the quote");
        assertEq(lens.totalStake(TOKEN1), amount - shares / 1e9, "only the delivered alpha left the vault");
    }
}

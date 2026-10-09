// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { BackingUnchanged, NothingToRecover } from "src/VaultErrors.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { MockStaking } from "./mocks/MockStaking.sol";

contract RecoveryDustTest is AlphaVaultTestBase {
    uint256 private constant EXPECTED = 6 * ALPHA / 10;
    /// @dev 0.04 alpha: the 2e6 RAO minimum stake at 0.05 TAO/alpha.
    uint256 private constant FLOOR = 4e7;
    uint256 private constant DUST = FLOOR / 2;
    /// @dev 3333 bps of EXPECTED: above the floor at 0.05 TAO/alpha, below the 0.2 alpha floor at 0.01.
    uint256 private constant THIRD_SLOT = 199_980_000;

    function _missingPosition() private returns (bytes32[] memory tips) {
        _depositAndWrap(alice, NETUID1, EXPECTED);
        bytes32[] memory keys = _hotkeys(hotkey1, hotkey2, hotkey3);
        tips = new bytes32[](keys.length);
        for (uint256 i; i < keys.length; ++i) {
            tips[i] = _buildSwapTrail(NETUID1, keys[i], 2);
        }
    }

    function _plant(bytes32 key, uint256 amount) private {
        MockStaking(STAKING_PRECOMPILE).setStake(key, _subnetColdkey(NETUID1), NETUID1, amount);
        _simulateHotkeyOwnerPresent(key);
    }

    function _emptyRecovery() private returns (bytes32[] memory tips, uint256 deadline) {
        tips = _missingPosition();
        vault.syncBacking(TOKEN1);
        deadline = lens.writeOffDeadline(TOKEN1);
        assertEq(_parkedStake(NETUID1), 0);
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, EXPECTED);
    }

    function test_RevertWhen_RecoveringASubFloorStray() public {
        _missingPosition();
        _plant(hotkey4, DUST);
        vault.syncBacking(TOKEN1);
        vm.expectRevert(NothingToRecover.selector);
        vault.recoverStray(TOKEN1, hotkey4);
    }

    function test_DustDuringEmptyRecovery_DoesNotBlockExpiryOrBurningWorthlessShares() public {
        (, uint256 deadline) = _emptyRecovery();
        _plant(hotkey1, DUST);
        assertEq(lens.locatedStake(TOKEN1), DUST);
        assertEq(lens.missingStake(TOKEN1), 580_000_000, "recorded dust is located backing");
        vm.warp(deadline - 1);
        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);

        vm.warp(deadline);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingWrittenOff(TOKEN1, EXPECTED, 0);
        vault.syncBacking(TOKEN1);
        assertEq(_getVaultStake(hotkey1, NETUID1), DUST);
        assertEq(lens.totalStake(TOKEN1), 0);
        assertEq(lens.writeOffDeadline(TOKEN1), 0);
        uint256 shares = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
        assertEq(vault.totalSupply(TOKEN1), 0);
    }

    function test_ParkedPile_CollectsDustWithoutExtendingTheWindow() public {
        (bytes32[] memory tips, uint256 deadline) = _emptyRecovery();
        bytes32 parking = vault.parkingHotkey();
        vault.recoverStray(TOKEN1, tips[2]);
        _plant(hotkey1, DUST);

        vm.expectEmit(true, true, false, true, address(vault));
        emit BackingRecovered(TOKEN1, parking, DUST);
        vault.syncBacking(TOKEN1);

        assertEq(_parkedStake(NETUID1), THIRD_SLOT + DUST);
        assertEq(_getVaultStake(hotkey1, NETUID1), 0);
        assertEq(lens.missingStake(TOKEN1), 380_020_000);
        assertEq(lens.writeOffDeadline(TOKEN1), deadline);
    }

    function test_AboveFloorReturnAtExpiry_CollectsPreviouslySkippedDust() public {
        (bytes32[] memory tips, uint256 deadline) = _emptyRecovery();
        _plant(hotkey1, DUST);
        _simulateOffVaultSwap(NETUID1, tips[2], hotkey3);
        vm.warp(deadline);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingWrittenOff(TOKEN1, EXPECTED, THIRD_SLOT + DUST);
        vault.syncBacking(TOKEN1);
        assertEq(_parkedStake(NETUID1), THIRD_SLOT + DUST);
        assertEq(_getVaultStake(hotkey1, NETUID1), 0);
        assertEq(_getVaultStake(hotkey3, NETUID1), 0);
    }

    function test_PriceRiseAtExpiry_CollectsDustThatNowClearsTheFloor() public {
        _missingPosition();
        _plant(hotkey1, DUST);
        vault.syncBacking(TOKEN1);
        assertEq(_parkedStake(NETUID1), 0);
        uint256 deadline = lens.writeOffDeadline(TOKEN1);
        // 0.02 alpha at 0.1 TAO/alpha is exactly the 2e6 RAO floor.
        _setAlphaPrice(NETUID1, 0.1e18);
        vm.warp(deadline);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingWrittenOff(TOKEN1, EXPECTED, DUST);
        vault.syncBacking(TOKEN1);
        assertEq(_parkedStake(NETUID1), DUST, "newly movable backing must not be written off");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0);
    }

    function test_PriceFallDuringRecovery_DoesNotLetDustBlockTheParkedBalance() public {
        (bytes32[] memory tips, uint256 deadline) = _emptyRecovery();
        vault.recoverStray(TOKEN1, tips[2]);
        _plant(hotkey1, DUST);
        _setAlphaPrice(NETUID1, 0.01e18);
        vm.warp(deadline);
        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), THIRD_SLOT, "the entire parked balance remains backing");
        assertEq(_getVaultStake(hotkey1, NETUID1), DUST);
        // A subsequent price recovery permits the holder's normal full alpha exit.
        _setAlphaPrice(NETUID1, ALPHA_PRICE);
        uint256 shares = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), THIRD_SLOT);
        assertEq(_getStake(vault.parkingHotkey(), alice, NETUID1), THIRD_SLOT);
    }

    function test_UnknownRoundedPrice_DoesNotAuthorizeADustWriteOff() public {
        (, uint256 deadline) = _emptyRecovery();
        _plant(hotkey1, DUST);
        _setAlphaPriceReadsZero(NETUID1);
        vm.warp(deadline);
        _expectChainRefusal();
        vault.syncBacking(TOKEN1);
    }

    function test_FailedAboveFloorCollection_DoesNotUseTheDustException() public {
        (, uint256 deadline) = _emptyRecovery();
        _plant(hotkey1, FLOOR);
        _plant(hotkey2, DUST);
        MockStaking(STAKING_PRECOMPILE).setMoveStakeReverts(true);
        vm.warp(deadline);
        _expectChainRefusal();
        vault.syncBacking(TOKEN1);
    }

    function _smallSet(uint256 count, uint256 dust, bool movable) private returns (uint256 located) {
        uint16 netuid = 9;
        _setRegBlock(netuid, 400);
        bytes32[] memory keys = _setValidatorCount(netuid, count);
        _simulateAlphaDepositHotkey(alice, netuid, ALPHA, keys[0]);
        _wrapHotkey(alice, netuid, keys[0]);
        uint256 tokenId = vault.currentTokenId(netuid);
        bytes32 coldkey = _subnetColdkey(netuid);
        for (uint256 i; i < count; ++i) {
            uint256 balance = movable && i == count - 1 ? FLOOR : dust;
            MockStaking(STAKING_PRECOMPILE).setStake(keys[i], coldkey, netuid, balance);
            located += balance;
        }
        vault.syncBacking(tokenId);
        assertEq(vault.recordedSlots(tokenId)[0].tracked, ALPHA);
        assertEq(_parkedStake(netuid), movable ? located : 0);
        uint256 deadline = lens.writeOffDeadline(tokenId);
        vm.warp(deadline);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingWrittenOff(tokenId, ALPHA, movable ? located : 0);
        vault.syncBacking(tokenId);
        assertEq(lens.totalStake(tokenId), movable ? located : 0);
        for (uint256 i; i < count; ++i) {
            assertEq(_getVaultStake(keys[i], netuid), movable ? 0 : dust);
        }
    }

    function test_TenDustBalances_DoNotBlockWriteOffEvenWhenTheirSumExceedsTheFloor() public {
        _smallSet(10, FLOOR - 1, false);
    }

    function test_OneBalanceAtTheFloor_CollectsAllNineDustBalances() public {
        _smallSet(10, FLOOR - 1, true);
    }

    function testFuzz_SmallSets_OnlySkipIndividuallySubFloorBalances(uint256 rawCount, uint256 rawDust, bool movable)
        public
    {
        _smallSet(bound(rawCount, 2, 10), bound(rawDust, VaultReads.TRACKED_SLACK_RAO + 1, FLOOR - 1), movable);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { VaultMath } from "src/libraries/VaultMath.sol";
import { MAX_VALIDATORS } from "src/interfaces/IValidatorRegistry.sol";
import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { BackingNotSecured, BackingUnchanged, NothingToRecover, ShortfallOnFile } from "src/VaultErrors.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { MockStaking } from "./mocks/MockStaking.sol";

contract RecoveryDeadlineTest is AlphaVaultTestBase {
    /// @dev 0.04 alpha: the 2e6 RAO minimum stake at 0.05 TAO/alpha.
    uint256 private constant FLOOR = 4e7;

    /// @dev 40 alpha at 2000 / 6000 / 2000 bps: 8 alpha is lost on hotkey1, 24 on hotkey2, and hotkey3's
    ///      8 alpha is parked at declaration.
    function _twoLosses() private returns (bytes32 firstTip, bytes32 secondTip, uint256 deadline) {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey3), _weights(2000, 6000, 2000));
        _depositAndWrap(alice, NETUID1, 40 * ALPHA);
        firstTip = _buildSwapTrail(NETUID1, hotkey1, 2);
        secondTip = _buildSwapTrail(NETUID1, hotkey2, 2);
        vault.syncBacking(TOKEN1);
        deadline = lens.writeOffDeadline(TOKEN1);
        assertEq(_parkedStake(NETUID1), 8 * ALPHA);
        assertEq(lens.missingStake(TOKEN1), 32 * ALPHA);
    }

    function test_LateSwap_CannotHideBackingSecuredBeforeTheDeadline() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.syncBacking(TOKEN1);
        uint256 deadline = lens.writeOffDeadline(TOKEN1);
        assertEq(_parkedStake(NETUID1), 19_998_000_000, "hotkey2 and hotkey3 hold 9.999 alpha each");
        assertEq(_getVaultStake(hotkey2, NETUID1), 0);

        vm.warp(deadline - 1);
        _buildSwapTrail(NETUID1, hotkey2, 2);
        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);

        vm.warp(deadline);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingWrittenOff(TOKEN1, 30 * ALPHA, 19_998_000_000);
        vault.syncBacking(TOKEN1);
        assertEq(_parkedStake(NETUID1), 19_998_000_000);
        assertEq(lens.writeOffDeadline(TOKEN1), 0);
    }

    function test_PartialRecovery_AcceptsTheLargerSourceFirstWithoutAttribution() public {
        (bytes32 firstTip, bytes32 secondTip, uint256 deadline) = _twoLosses();
        bytes32 parking = vault.parkingHotkey();
        vm.warp(deadline - 1);
        vm.expectEmit(true, true, false, true, address(vault));
        emit BackingRecovered(TOKEN1, parking, 24 * ALPHA);
        vault.recoverStray(TOKEN1, secondTip);
        assertEq(_parkedStake(NETUID1), 32 * ALPHA, "the larger source is credited without attribution");
        assertEq(lens.missingStake(TOKEN1), 8 * ALPHA);
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, 40 * ALPHA);
        assertEq(_getVaultStake(secondTip, NETUID1), 0);
        assertEq(lens.writeOffDeadline(TOKEN1), deadline, "partial recovery cannot extend the window");
        vm.expectRevert(ShortfallOnFile.selector);
        lens.totalStake(TOKEN1);
        vm.expectRevert(NothingToRecover.selector);
        vault.recoverStray(TOKEN1, secondTip);

        vault.recoverStray(TOKEN1, firstTip);
        assertEq(_parkedStake(NETUID1), 40 * ALPHA);
        assertEq(lens.missingStake(TOKEN1), 0);
        assertEq(lens.writeOffDeadline(TOKEN1), deadline, "only sync finalizes recovery");
        assertFalse(lens.isBackingIntact(TOKEN1));
        vault.syncBacking(TOKEN1);
        assertEq(lens.writeOffDeadline(TOKEN1), 0);
        assertEq(vault.recordedSlots(TOKEN1).length, 1);
        assertTrue(vault.awaitingAttestation(TOKEN1));
    }

    function test_ReturnedBalance_IsSecuredBeforeItsHotkeyCanSwapAgain() public {
        (bytes32 firstTip, bytes32 secondTip, uint256 deadline) = _twoLosses();
        bytes32 parking = vault.parkingHotkey();
        vm.warp(deadline - 2);
        _simulateOffVaultSwap(NETUID1, firstTip, hotkey1);
        assertEq(lens.locatedStake(TOKEN1), 16 * ALPHA, "the returned balance is counted once");
        vm.expectEmit(true, true, false, true, address(vault));
        emit BackingRecovered(TOKEN1, parking, 8 * ALPHA);
        vault.syncBacking(TOKEN1);
        assertEq(_getVaultStake(hotkey1, NETUID1), 0);
        assertEq(_parkedStake(NETUID1), 16 * ALPHA);
        assertEq(lens.writeOffDeadline(TOKEN1), deadline);

        vm.warp(deadline - 1);
        _simulateOffVaultSwap(NETUID1, hotkey1, firstTip);
        vm.warp(deadline);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingWrittenOff(TOKEN1, 40 * ALPHA, 16 * ALPHA);
        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), 16 * ALPHA);
        vault.recoverStray(TOKEN1, secondTip);
        assertEq(lens.totalStake(TOKEN1), 40 * ALPHA, "late recovery still belongs to current holders");
    }

    function test_ReturnAtExpiry_IsCollectedBeforeWriteOff() public {
        (bytes32 firstTip, bytes32 secondTip, uint256 deadline) = _twoLosses();
        _simulateOffVaultSwap(NETUID1, firstTip, hotkey1);
        _simulateOffVaultSwap(NETUID1, secondTip, hotkey2);
        vm.warp(deadline);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingShortfallCleared(TOKEN1);
        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), 40 * ALPHA);
        assertEq(_parkedStake(NETUID1), 40 * ALPHA);
        assertEq(lens.writeOffDeadline(TOKEN1), 0);
    }

    function test_PartialRecoveryAfterSync_PreservesItsClock() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 tip = _buildSwapTrail(NETUID1, hotkey1, 2);
        _buildSwapTrail(NETUID1, hotkey2, 2);
        vault.syncBacking(TOKEN1);
        vault.recoverStray(TOKEN1, tip);
        assertEq(_parkedStake(NETUID1), 20_001_000_000, "hotkey3's 9.999 alpha plus hotkey1's 10.002");
        assertEq(lens.missingStake(TOKEN1), 9_999_000_000);
        assertEq(_getVaultStake(tip, NETUID1), 0);
        assertEq(lens.writeOffDeadline(TOKEN1), block.timestamp + RECOVERY_WINDOW);
    }

    function test_FailedParking_RevertsAndStartsTheClockOnRetry() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        MockStaking(STAKING_PRECOMPILE).setMoveStakeReverts(true);
        _expectChainRefusal();
        vault.syncBacking(TOKEN1);
        vm.warp(block.timestamp + 1 days);
        MockStaking(STAKING_PRECOMPILE).setMoveStakeReverts(false);
        vault.syncBacking(TOKEN1);
        assertEq(lens.writeOffDeadline(TOKEN1), block.timestamp + RECOVERY_WINDOW);
    }

    function test_FailedCollectionAtExpiry_RevertsAndCanBeRetried() public {
        (bytes32 firstTip,, uint256 deadline) = _twoLosses();
        _simulateOffVaultSwap(NETUID1, firstTip, hotkey1);
        vm.warp(deadline);
        MockStaking(STAKING_PRECOMPILE).setMoveStakeReverts(true);
        _expectChainRefusal();
        vault.syncBacking(TOKEN1);
        MockStaking(STAKING_PRECOMPILE).setMoveStakeReverts(false);
        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), 16 * ALPHA);
    }

    function test_PartialRecovery_CannotCreditAnotherColdkeysStake() public {
        _twoLosses();
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey5, _toSubstrate(bob), NETUID1, 100 * ALPHA);
        _simulateHotkeyOwnerPresent(hotkey5);
        vm.expectRevert(NothingToRecover.selector);
        vault.recoverStray(TOKEN1, hotkey5);
    }

    function test_PartialRecovery_CreditsActualParkingBalanceAfterRounding() public {
        (,, uint256 deadline) = _twoLosses();
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey5, _subnetColdkey(NETUID1), NETUID1, ALPHA);
        _simulateHotkeyOwnerPresent(hotkey5);
        MockStaking(STAKING_PRECOMPILE).setMoveStakeRoundingLoss(5);
        vault.recoverStray(TOKEN1, hotkey5);
        assertEq(_parkedStake(NETUID1), 9 * ALPHA - 10, "two roller moves each lose 5 RAO");
        assertEq(lens.missingStake(TOKEN1), 31 * ALPHA + 10);
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, 40 * ALPHA);
        assertEq(lens.writeOffDeadline(TOKEN1), deadline);
    }

    function testFuzz_PartialRecovery_IsIndependentOfSourceOrder(uint256 rawSplit, bool secondSourceFirst) public {
        (bytes32 firstTip, bytes32 secondTip, uint256 deadline) = _twoLosses();
        uint256 minShortfall = BACKING_SLACK_RAO + 1;
        uint256 split = bound(rawSplit, minShortfall, 32 * ALPHA - minShortfall);
        MockStaking staking = MockStaking(STAKING_PRECOMPILE);
        staking.setStake(firstTip, _subnetColdkey(NETUID1), NETUID1, split);
        staking.setStake(secondTip, _subnetColdkey(NETUID1), NETUID1, 32 * ALPHA - split);
        bytes32 first = secondSourceFirst ? secondTip : firstTip;
        bytes32 second = secondSourceFirst ? firstTip : secondTip;
        vault.recoverStray(TOKEN1, first);
        assertEq(lens.missingStake(TOKEN1), secondSourceFirst ? split : 32 * ALPHA - split);
        assertEq(lens.writeOffDeadline(TOKEN1), deadline);
        vault.recoverStray(TOKEN1, second);
        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), 40 * ALPHA);
    }

    function testFuzz_Recovery_ParksEveryOtherSlotBeforeStartingTheClock(uint256 rawIndex) public {
        uint256 netuid = 9;
        _setRegBlock(netuid, 400);
        bytes32[] memory hotkeys = _setValidatorCount(netuid, MAX_VALIDATORS);
        _simulateAlphaDepositHotkey(alice, netuid, MAX_VALIDATORS * ALPHA, hotkeys[0]);
        _wrapHotkey(alice, netuid, hotkeys[0]);
        uint256 tokenId = vault.currentTokenId(netuid);
        uint256 index = bound(rawIndex, 0, MAX_VALIDATORS - 1);
        // 156 bps of 64 alpha per slot; the last slot takes the 172 bps remainder.
        uint256 lost = index == MAX_VALIDATORS - 1 ? 1_100_800_000 : 998_400_000;
        _buildSwapTrail(netuid, hotkeys[index], 2);
        vault.syncBacking(tokenId);
        assertEq(_parkedStake(netuid), MAX_VALIDATORS * ALPHA - lost);
        assertEq(lens.missingStake(tokenId), lost);
        for (uint256 i; i < hotkeys.length; ++i) {
            assertEq(_getVaultStake(hotkeys[i], netuid), 0);
        }
    }

    function test_FinalSync_CollectsKnownReturnsEvenWhenParkingAlreadyCoversTheObligation() public {
        (bytes32 first, bytes32 second, uint256 deadline) = _twoLosses();
        _simulateOffVaultSwap(NETUID1, first, hotkey1);
        MockStaking(STAKING_PRECOMPILE).setStake(second, _subnetColdkey(NETUID1), NETUID1, 32 * ALPHA);
        bytes32 record = keccak256(abi.encode(vault.recordedSlots(TOKEN1)));

        vault.recoverStray(TOKEN1, second);
        assertEq(_parkedStake(NETUID1), 40 * ALPHA);
        assertEq(_getVaultStake(hotkey1, NETUID1), 8 * ALPHA, "only the supplied source moved");
        assertEq(keccak256(abi.encode(vault.recordedSlots(TOKEN1))), record);
        assertEq(lens.writeOffDeadline(TOKEN1), deadline);
        assertFalse(lens.isBackingIntact(TOKEN1), "sync must finalize the record");

        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), 48 * ALPHA, "no returned backing was dropped at completion");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0);
        assertEq(vault.recordedSlots(TOKEN1).length, 1);
        assertEq(lens.writeOffDeadline(TOKEN1), 0);
        assertTrue(vault.awaitingAttestation(TOKEN1));
    }

    function test_RecoverStray_AcceptsAReturnAtAKnownCollectionKey() public {
        (bytes32 first,, uint256 deadline) = _twoLosses();
        _simulateOffVaultSwap(NETUID1, first, hotkey1);
        vault.recoverStray(TOKEN1, hotkey1);
        assertEq(_parkedStake(NETUID1), 16 * ALPHA);
        assertEq(_getVaultStake(hotkey1, NETUID1), 0);
        assertEq(lens.missingStake(TOKEN1), 24 * ALPHA);
        assertEq(lens.writeOffDeadline(TOKEN1), deadline);
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, 40 * ALPHA);
    }

    function test_RecoverStray_AfterExpiryStillLetsSyncClearFullCoverage() public {
        (bytes32 first, bytes32 second, uint256 deadline) = _twoLosses();
        vm.warp(deadline);
        vault.recoverStray(TOKEN1, first);
        vault.recoverStray(TOKEN1, second);
        assertEq(lens.writeOffDeadline(TOKEN1), deadline);
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, 40 * ALPHA);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingShortfallCleared(TOKEN1);
        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), 40 * ALPHA);
        assertEq(lens.writeOffDeadline(TOKEN1), 0);
    }

    function test_RevertWhen_RecoveringFromZeroOrParkingHotkey() public {
        _twoLosses();
        vm.expectRevert(NothingToRecover.selector);
        vault.recoverStray(TOKEN1, bytes32(0));
        bytes32 parking = vault.parkingHotkey();
        vm.expectRevert(NothingToRecover.selector);
        vault.recoverStray(TOKEN1, parking);
    }

    function test_RecoverStray_CanAnnexUntrackedParkingStakeToLiveBacking() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 parking = vault.parkingHotkey();
        MockStaking(STAKING_PRECOMPILE).setStake(parking, _subnetColdkey(NETUID1), NETUID1, 3 * ALPHA);
        vault.recoverStray(TOKEN1, parking);
        assertEq(lens.totalStake(TOKEN1), 33 * ALPHA);
        assertEq(_parkedStake(NETUID1), 0);
        assertEq(lens.writeOffDeadline(TOKEN1), 0);
        assertFalse(vault.awaitingAttestation(TOKEN1));
    }

    function test_MovableSourceFirst_EnablesNineSeparateDustRecoveries() public {
        uint256 dust = FLOOR / 2;
        uint256 dustSources = 9;
        _depositAndWrap(alice, NETUID1, ALPHA);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        _buildSwapTrail(NETUID1, hotkey2, 2);
        _buildSwapTrail(NETUID1, hotkey3, 2);
        vault.syncBacking(TOKEN1);
        uint256 deadline = lens.writeOffDeadline(TOKEN1);
        MockStaking staking = MockStaking(STAKING_PRECOMPILE);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        for (uint256 i; i < dustSources; ++i) {
            bytes32 source = keccak256(abi.encode("dust source", i));
            _simulateHotkeyOwnerPresent(source);
            staking.setStake(source, coldkey, NETUID1, dust);
            vm.expectRevert(NothingToRecover.selector);
            vault.recoverStray(TOKEN1, source);
        }
        _simulateHotkeyOwnerPresent(hotkey4);
        staking.setStake(hotkey4, coldkey, NETUID1, FLOOR);
        vault.recoverStray(TOKEN1, hotkey4);
        for (uint256 i; i < dustSources; ++i) {
            bytes32 source = keccak256(abi.encode("dust source", i));
            vault.recoverStray(TOKEN1, source);
            assertEq(_getVaultStake(source, NETUID1), 0);
        }
        uint256 collected = 220_000_000;
        assertEq(_parkedStake(NETUID1), collected, "0.04 alpha plus nine 0.02 alpha piles");
        assertEq(lens.missingStake(TOKEN1), 780_000_000);
        assertEq(lens.writeOffDeadline(TOKEN1), deadline);
        vm.warp(deadline);
        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), collected, "all ten collected balances survive write-off");
    }

    /// @dev Fault injection of the BackingNotSecured guard: a mock move leaves a residual at its source.
    function test_FaultInjection_MoveResidualAtDeclaration_HoldsTheClockUntilRetried() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        MockStaking staking = MockStaking(STAKING_PRECOMPILE);
        staking.setMoveStakeResidual(BACKING_SLACK_RAO + 1);
        vm.expectRevert(BackingNotSecured.selector);
        vault.syncBacking(TOKEN1);

        staking.setMoveStakeResidual(0);
        vault.syncBacking(TOKEN1);
        assertEq(_parkedStake(NETUID1), 19_998_000_000);
        assertEq(lens.missingStake(TOKEN1), 10_002_000_000);
        assertEq(lens.writeOffDeadline(TOKEN1), block.timestamp + RECOVERY_WINDOW);
    }

    /// @dev Fault injection of the BackingNotSecured guard: a mock move leaves a residual at its source.
    function test_FaultInjection_MoveResidualAtExpiry_HoldsTheWriteOffUntilRetried() public {
        (bytes32 first,, uint256 deadline) = _twoLosses();
        _simulateOffVaultSwap(NETUID1, first, hotkey1);
        vm.warp(deadline);
        MockStaking staking = MockStaking(STAKING_PRECOMPILE);
        staking.setMoveStakeResidual(BACKING_SLACK_RAO + 1);
        vm.expectRevert(BackingNotSecured.selector);
        vault.syncBacking(TOKEN1);

        staking.setMoveStakeResidual(0);
        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), 16 * ALPHA);
        assertEq(_getVaultStake(hotkey1, NETUID1), 0);
        assertEq(lens.writeOffDeadline(TOKEN1), 0);
    }

    function testFuzz_Declaration_ParksTheComplementOfAnyNonemptyLostSubset(uint256 rawCount, uint256 rawMask) public {
        uint256 netuid = 9;
        _setRegBlock(netuid, 400);
        uint256 count = bound(rawCount, 1, MAX_VALIDATORS);
        bytes32[] memory keys = _setValidatorCount(netuid, count);
        uint256 expected = count * ALPHA;
        _simulateAlphaDepositHotkey(alice, netuid, expected, keys[0]);
        _wrapHotkey(alice, netuid, keys[0]);
        uint256 tokenId = vault.currentTokenId(netuid);
        uint256 lostMask = bound(rawMask, 1, (uint256(1) << count) - 1);
        uint256 lost;
        for (uint256 i; i < count; ++i) {
            if (lostMask & (uint256(1) << i) != 0) {
                lost += _getVaultStake(keys[i], netuid);
                _buildSwapTrail(netuid, keys[i], 2);
            }
        }
        vault.syncBacking(tokenId);
        assertEq(_parkedStake(netuid), expected - lost);
        assertEq(lens.missingStake(tokenId), lost);
        assertEq(vault.recordedSlots(tokenId)[0].tracked, expected);
        assertEq(vault.recordedSlots(tokenId).length, count + 1, "no duplicate or empty collection entries");
        for (uint256 i; i < count; ++i) {
            assertEq(_getVaultStake(keys[i], netuid), 0);
        }

        vm.warp(lens.writeOffDeadline(tokenId));
        vault.syncBacking(tokenId);
        assertEq(lens.totalStake(tokenId), expected - lost, "expiry preserves every located balance");
        assertEq(lens.writeOffDeadline(tokenId), 0);
    }

    /// @dev 400 alpha keeps the wrap's move above the floor for every weight split.
    function testFuzz_MergedSlots_FinalizeAtDeclarationForAnySplit(uint256 rawWeight) public {
        uint16 firstWeight = uint16(bound(rawWeight, 1, VaultMath.BPS_BASE - 1));
        bytes32[] memory keys = new bytes32[](2);
        keys[0] = hotkey1;
        keys[1] = hotkey2;
        uint16[] memory weights = new uint16[](2);
        weights[0] = firstWeight;
        weights[1] = uint16(VaultMath.BPS_BASE) - firstWeight;
        _setValidators(NETUID1, keys, weights);
        _depositAndWrap(alice, NETUID1, 400 * ALPHA);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        _simulateOffVaultSwap(NETUID1, hotkey2, hotkey4);
        MockStaking staking = MockStaking(STAKING_PRECOMPILE);
        staking.setHotkeySuccessor(hotkey1, NETUID1, hotkey4);
        staking.setHotkeySuccessor(hotkey2, NETUID1, hotkey4);
        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), 400 * ALPHA);
        assertEq(_parkedStake(NETUID1), 400 * ALPHA);
        assertEq(lens.missingStake(TOKEN1), 0);
        assertEq(lens.writeOffDeadline(TOKEN1), 0);
        assertEq(vault.recordedSlots(TOKEN1).length, 1);
        assertTrue(vault.awaitingAttestation(TOKEN1));
        assertEq(_getVaultStake(hotkey1, NETUID1), 0);
        assertEq(_getVaultStake(hotkey2, NETUID1), 0);
        assertEq(_getVaultStake(hotkey4, NETUID1), 0);
    }
}

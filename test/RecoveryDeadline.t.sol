// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { MAX_VALIDATORS } from "src/interfaces/IValidatorRegistry.sol";
import { BackingScenarios } from "./helpers/BackingScenarios.sol";
import { BackingNotSecured, BackingUnchanged, NothingToRecover } from "src/VaultErrors.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { MockStaking } from "./mocks/MockStaking.sol";

contract RecoveryDeadlineTest is BackingScenarios {
    uint256 private constant DUST_SOURCES = 9;

    /// @dev 40 alpha at 2000 / 6000 / 2000 bps: 8 alpha is swept on hotkey1, 24 on hotkey2, and hotkey3's
    ///      8 alpha is parked at declaration.
    function _twoLossesDeclared() private returns (uint256 firstSwept, uint256 secondSwept, uint256 deadline) {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey3), _weights(2000, 6000, 2000));
        _depositAndWrap(alice, NETUID1, 40 * ALPHA);
        firstSwept = _sweepDuringCrash(NETUID1, hotkey1);
        secondSwept = _sweepDuringCrash(NETUID1, hotkey2);
        vault.syncBacking(TOKEN1);
        deadline = block.timestamp + RECOVERY_WINDOW;
        assertEq(_parkedStake(NETUID1), 8 * ALPHA, "hotkey3's 8 alpha is parked at declaration");
        assertEq(lens.missingStake(TOKEN1), 32 * ALPHA, "the 8 and 24 alpha swept are missing");
    }

    function _twoLosses() private returns (bytes32 firstTip, bytes32 secondTip, uint256 deadline) {
        uint256 firstSwept;
        uint256 secondSwept;
        (firstSwept, secondSwept, deadline) = _twoLossesDeclared();
        (firstTip, secondTip) = (hotkey4, hotkey5);
        _strangerReturns(NETUID1, firstTip, firstSwept);
        _strangerReturns(NETUID1, secondTip, secondSwept);
    }

    function test_LateSwap_CannotHideBackingSecuredBeforeTheDeadline() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _sweepDuringCrash(NETUID1, hotkey1);
        vault.syncBacking(TOKEN1);
        uint256 deadline = block.timestamp + RECOVERY_WINDOW;
        assertEq(_parkedStake(NETUID1), OTHER_TWO_SLOTS, "hotkey2 and hotkey3 hold 9.999 alpha each");
        assertEq(_getVaultStake(hotkey2, NETUID1), 0, "and both were emptied onto the parking hotkey");

        vm.warp(deadline - 1);
        _buildSwapTrail(NETUID1, hotkey2, 2);
        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);

        vm.warp(deadline);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingWrittenOff(TOKEN1, 30 * ALPHA, OTHER_TWO_SLOTS);
        vault.syncBacking(TOKEN1);
        assertEq(_parkedStake(NETUID1), OTHER_TWO_SLOTS, "the swap moved none of the secured backing");
        assertEq(lens.writeOffDeadline(TOKEN1), 0, "and the write-off stopped the clock");
    }

    function test_PartialRecovery_AcceptsTheLargerSourceFirstWithoutAttribution() public {
        (bytes32 firstTip, bytes32 secondTip, uint256 deadline) = _twoLosses();
        bytes32 parking = vault.parkingHotkey();
        vm.warp(deadline - 1);
        vm.expectEmit(true, true, true, true, address(vault));
        emit BackingRecovered(TOKEN1, secondTip, parking, 24 * ALPHA);
        vault.recoverStray(TOKEN1, secondTip);
        assertEq(_parkedStake(NETUID1), 32 * ALPHA, "the larger source is credited without attribution");
        assertEq(lens.missingStake(TOKEN1), 8 * ALPHA, "leaving the first slot's 8 alpha missing");
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, 40 * ALPHA, "against the whole obligation");
        assertEq(_getVaultStake(secondTip, NETUID1), 0, "the source was emptied");
        assertEq(lens.writeOffDeadline(TOKEN1), deadline, "partial recovery cannot extend the window");

        vault.recoverStray(TOKEN1, firstTip);
        assertEq(_parkedStake(NETUID1), 40 * ALPHA, "both sources are parked");
        assertEq(lens.missingStake(TOKEN1), 0, "nothing is missing");
        assertEq(lens.writeOffDeadline(TOKEN1), deadline, "only sync finalizes recovery");
        assertFalse(lens.isBackingIntact(TOKEN1), "so the loss is still on file");
        vault.syncBacking(TOKEN1);
        assertEq(lens.writeOffDeadline(TOKEN1), 0, "the sync stops the clock");
        assertEq(vault.recordedSlots(TOKEN1).length, 1, "on a record of the parking slot alone");
        assertTrue(vault.awaitingAttestation(TOKEN1), "which waits for the attesters");
    }

    function test_RevertWhen_RecoveringAnEmptiedSourceAgain() public {
        (, bytes32 secondTip, uint256 deadline) = _twoLosses();
        vm.warp(deadline - 1);
        vault.recoverStray(TOKEN1, secondTip);

        vm.expectRevert(NothingToRecover.selector);
        vault.recoverStray(TOKEN1, secondTip);
    }

    function test_ReturnedBalance_IsSecuredBeforeItsHotkeyCanSwapAgain() public {
        (bytes32 firstTip, bytes32 secondTip, uint256 deadline) = _twoLosses();
        vm.warp(deadline - 2);
        _simulateOffVaultSwap(NETUID1, firstTip, hotkey1);
        assertEq(lens.locatedStake(TOKEN1), 16 * ALPHA, "8 alpha parked and 8 returned, each counted once");
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingCollected(TOKEN1, 8 * ALPHA);
        vault.syncBacking(TOKEN1);
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "the return was collected");
        assertEq(_parkedStake(NETUID1), 16 * ALPHA, "onto the parking hotkey");
        assertEq(lens.writeOffDeadline(TOKEN1), deadline, "without moving the deadline");

        vm.warp(deadline - 1);
        _simulateOffVaultSwap(NETUID1, hotkey1, firstTip);
        vm.warp(deadline);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingWrittenOff(TOKEN1, 40 * ALPHA, 16 * ALPHA);
        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), 16 * ALPHA, "the write-off keeps the 16 alpha secured");
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
        assertEq(lens.totalStake(TOKEN1), 40 * ALPHA, "both returns count");
        assertEq(_parkedStake(NETUID1), 40 * ALPHA, "on the parking hotkey");
        assertEq(lens.writeOffDeadline(TOKEN1), 0, "and the loss is cleared, not written off");
    }

    function test_PartialRecoveryAfterSync_PreservesItsClock() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        uint256 firstSwept = _sweepDuringCrash(NETUID1, hotkey1);
        _sweepDuringCrash(NETUID1, hotkey2);
        vault.syncBacking(TOKEN1);
        _strangerReturns(NETUID1, hotkey4, firstSwept);
        vault.recoverStray(TOKEN1, hotkey4);
        assertEq(_parkedStake(NETUID1), 20_001_000_000, "hotkey3's 9.999 alpha plus hotkey1's 10.002");
        assertEq(lens.missingStake(TOKEN1), OTHER_SLOT, "hotkey2's 9.999 alpha is still missing");
        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "the source was emptied");
        assertEq(lens.writeOffDeadline(TOKEN1), block.timestamp + RECOVERY_WINDOW, "and the clock did not move");
    }

    function test_FailedParking_RevertsAndStartsTheClockOnRetry() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _sweepDuringCrash(NETUID1, hotkey1);
        MockStaking(STAKING_PRECOMPILE).setMoveStakeReverts(true);
        _expectChainRefusal();
        vault.syncBacking(TOKEN1);
        vm.warp(block.timestamp + 1 days);
        MockStaking(STAKING_PRECOMPILE).setMoveStakeReverts(false);
        vault.syncBacking(TOKEN1);
        assertEq(lens.writeOffDeadline(TOKEN1), block.timestamp + RECOVERY_WINDOW, "the clock starts on the retry");
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
        assertEq(lens.totalStake(TOKEN1), 16 * ALPHA, "the retry collects the 8 alpha return beside 8 parked");
    }

    function test_RevertWhen_RecoveringFromAHotkeyOnlyAnotherColdkeyStakesUnder() public {
        _twoLosses();
        bytes32 bobsHotkey = keccak256("bob's own validator");
        MockStaking(STAKING_PRECOMPILE).setStake(bobsHotkey, _toSubstrate(bob), NETUID1, 100 * ALPHA);
        _simulateHotkeyOwnerPresent(bobsHotkey);
        vm.expectRevert(NothingToRecover.selector);
        vault.recoverStray(TOKEN1, bobsHotkey);
    }

    function test_PartialRecovery_CreditsActualParkingBalanceAfterRounding() public {
        (,, uint256 deadline) = _twoLossesDeclared();
        _strangerReturns(NETUID1, hotkey5, ALPHA);
        MockStaking(STAKING_PRECOMPILE).setMoveStakeRoundingLoss(5);
        vault.recoverStray(TOKEN1, hotkey5);
        assertEq(_parkedStake(NETUID1), 9 * ALPHA - 10, "8 parked and 1 returned, two roller moves each lose 5 RAO");
        assertEq(lens.missingStake(TOKEN1), 31 * ALPHA + 10, "40 alpha less what the parking hotkey holds");
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, 40 * ALPHA, "against the whole obligation");
        assertEq(lens.writeOffDeadline(TOKEN1), deadline, "and the clock did not move");
    }

    function testFuzz_PartialRecovery_IsIndependentOfSourceOrder(uint256 rawSplit, bool secondSourceFirst) public {
        (,, uint256 deadline) = _twoLossesDeclared();
        uint256 split = bound(rawSplit, CRUMB, 32 * ALPHA - CRUMB);
        (bytes32 firstTip, bytes32 secondTip) = (hotkey4, hotkey5);
        _strangerReturns(NETUID1, firstTip, split);
        _strangerReturns(NETUID1, secondTip, 32 * ALPHA - split);
        bytes32 first = secondSourceFirst ? secondTip : firstTip;
        bytes32 second = secondSourceFirst ? firstTip : secondTip;

        vault.recoverStray(TOKEN1, first);
        assertEq(
            lens.missingStake(TOKEN1),
            secondSourceFirst ? split : 32 * ALPHA - split,
            "the pile not yet recovered is what is missing"
        );
        assertEq(lens.writeOffDeadline(TOKEN1), deadline, "and the clock did not move");
        vault.recoverStray(TOKEN1, second);
        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), 40 * ALPHA, "both piles together restore the whole position");
    }

    function test_FinalSync_CollectsKnownReturnsEvenWhenParkingAlreadyCoversTheObligation() public {
        (bytes32 first, bytes32 second, uint256 deadline) = _twoLosses();
        _simulateOffVaultSwap(NETUID1, first, hotkey1);
        _strangerReturns(NETUID1, second, 8 * ALPHA);
        bytes32 record = keccak256(abi.encode(vault.recordedSlots(TOKEN1)));

        vault.recoverStray(TOKEN1, second);
        assertEq(_parkedStake(NETUID1), 40 * ALPHA, "8 parked and the 32 alpha on the supplied source");
        assertEq(_getVaultStake(hotkey1, NETUID1), 8 * ALPHA, "only the supplied source moved");
        assertEq(keccak256(abi.encode(vault.recordedSlots(TOKEN1))), record, "the record is untouched");
        assertEq(lens.writeOffDeadline(TOKEN1), deadline, "and the clock did not move");
        assertFalse(lens.isBackingIntact(TOKEN1), "sync must finalize the record");

        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), 48 * ALPHA, "no returned backing was dropped at completion");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "the known return was collected");
        assertEq(vault.recordedSlots(TOKEN1).length, 1, "on a record of the parking slot alone");
        assertEq(lens.writeOffDeadline(TOKEN1), 0, "the sync stops the clock");
        assertTrue(vault.awaitingAttestation(TOKEN1), "and the position waits for the attesters");
    }

    function test_RecoverStray_AcceptsAReturnAtAKnownCollectionHotkey() public {
        (bytes32 first,, uint256 deadline) = _twoLosses();
        _simulateOffVaultSwap(NETUID1, first, hotkey1);
        vault.recoverStray(TOKEN1, hotkey1);
        assertEq(_parkedStake(NETUID1), 16 * ALPHA, "8 parked and the 8 alpha returned under hotkey1");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "the source was emptied");
        assertEq(lens.missingStake(TOKEN1), 24 * ALPHA, "the second slot's 24 alpha is still missing");
        assertEq(lens.writeOffDeadline(TOKEN1), deadline, "and the clock did not move");
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, 40 * ALPHA, "against the whole obligation");
    }

    function test_RecoverStray_AfterExpiryStillLetsSyncClearFullCoverage() public {
        (bytes32 first, bytes32 second, uint256 deadline) = _twoLosses();
        vm.warp(deadline);
        vault.recoverStray(TOKEN1, first);
        vault.recoverStray(TOKEN1, second);
        assertEq(lens.writeOffDeadline(TOKEN1), deadline, "recovery past the deadline does not finalize it");
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, 40 * ALPHA, "the obligation stands");
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingShortfallCleared(TOKEN1);
        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), 40 * ALPHA, "the sync clears instead of writing off");
        assertEq(lens.writeOffDeadline(TOKEN1), 0, "and stops the clock");
    }

    function test_RevertWhen_RecoveringFromAnEmptyHotkeyOrParking() public {
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
        _strangerReturns(NETUID1, parking, 3 * ALPHA);

        vault.recoverStray(TOKEN1, parking);

        assertEq(lens.totalStake(TOKEN1), 33 * ALPHA, "the parking pile joins the live backing");
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, FIRST_SLOT + 3 * ALPHA, "booked on the first slot");
        assertEq(_parkedStake(NETUID1), 0, "leaving the parking hotkey empty");
        assertEq(lens.writeOffDeadline(TOKEN1), 0, "with no clock started");
        assertFalse(vault.awaitingAttestation(TOKEN1), "and nothing parked");
    }

    function test_MovableSourceFirst_EnablesNineSeparateDustRecoveries() public {
        _depositAndWrap(alice, NETUID1, ALPHA);
        _sweepEverySlot();
        vault.syncBacking(TOKEN1);
        uint256 deadline = block.timestamp + RECOVERY_WINDOW;
        for (uint256 i; i < DUST_SOURCES; ++i) {
            bytes32 source = keccak256(abi.encode("dust source", i));
            _strangerReturns(NETUID1, source, DUST);
            vm.expectRevert(NothingToRecover.selector);
            vault.recoverStray(TOKEN1, source);
        }
        _strangerReturns(NETUID1, hotkey4, ALPHA_FLOOR);
        vault.recoverStray(TOKEN1, hotkey4);
        for (uint256 i; i < DUST_SOURCES; ++i) {
            bytes32 source = keccak256(abi.encode("dust source", i));
            vault.recoverStray(TOKEN1, source);
            assertEq(_getVaultStake(source, NETUID1), 0, "the movable parking pile carries each dust source home");
        }
        assertEq(_parkedStake(NETUID1), 220_000_000, "0.04 alpha plus nine 0.02 alpha piles");
        assertEq(lens.missingStake(TOKEN1), 780_000_000, "1 alpha less the 0.22 alpha collected");
        assertEq(lens.writeOffDeadline(TOKEN1), deadline, "and the clock did not move");
        vm.warp(deadline);
        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), 220_000_000, "all ten collected balances survive write-off");
    }

    /// @dev Fault injection of the BackingNotSecured guard: a mock move leaves a residual at its source.
    function test_MoveLeavingAResidualAtDeclaration_HoldsTheClockUntilRetried() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _sweepDuringCrash(NETUID1, hotkey1);
        MockStaking staking = MockStaking(STAKING_PRECOMPILE);
        staking.setMoveStakeResidual(1_001);
        vm.expectRevert(BackingNotSecured.selector);
        vault.syncBacking(TOKEN1);

        staking.setMoveStakeResidual(0);
        vault.syncBacking(TOKEN1);
        assertEq(_parkedStake(NETUID1), OTHER_TWO_SLOTS, "the retry parks the two unswept slots");
        assertEq(lens.missingStake(TOKEN1), FIRST_SLOT, "the first slot's 10.002 alpha is missing");
        assertEq(lens.writeOffDeadline(TOKEN1), block.timestamp + RECOVERY_WINDOW, "and the clock starts then");
    }

    /// @dev Fault injection of the BackingNotSecured guard: a mock move leaves a residual at its source.
    function test_MoveLeavingAResidualAtExpiry_HoldsTheWriteOffUntilRetried() public {
        (bytes32 first,, uint256 deadline) = _twoLosses();
        _simulateOffVaultSwap(NETUID1, first, hotkey1);
        vm.warp(deadline);
        MockStaking staking = MockStaking(STAKING_PRECOMPILE);
        staking.setMoveStakeResidual(1_001);
        vm.expectRevert(BackingNotSecured.selector);
        vault.syncBacking(TOKEN1);

        staking.setMoveStakeResidual(0);
        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), 16 * ALPHA, "the retry writes off around 8 parked and 8 collected");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "the return was collected");
        assertEq(lens.writeOffDeadline(TOKEN1), 0, "and the clock is gone");
    }

    function testFuzz_Declaration_ParksTheComplementOfAnyNonemptyLostSubset(uint256 rawCount, uint256 rawMask) public {
        uint256 count = bound(rawCount, 1, MAX_VALIDATORS);
        uint256 expected = count * ALPHA;
        (bytes32[] memory hotkeys, uint256 tokenId) = _wideSetPosition(count, expected);
        uint256 lostMask = bound(rawMask, 1, (uint256(1) << count) - 1);
        uint256 lost;
        for (uint256 i; i < count; ++i) {
            if (lostMask & (uint256(1) << i) != 0) {
                lost += _sweepDuringCrash(WIDE_SET_NETUID, hotkeys[i]);
            }
        }
        vault.syncBacking(tokenId);
        assertEq(_parkedStake(WIDE_SET_NETUID), expected - lost, "every unswept slot is parked");
        assertEq(lens.missingStake(tokenId), lost, "every swept slot is missing");
        assertEq(vault.recordedSlots(tokenId)[0].tracked, expected, "against the whole obligation");
        assertEq(vault.recordedSlots(tokenId).length, count + 1, "no duplicate or empty collection entries");
        for (uint256 i; i < count; ++i) {
            assertEq(_getVaultStake(hotkeys[i], WIDE_SET_NETUID), 0, "nothing stays on a recorded hotkey");
        }

        vm.warp(block.timestamp + RECOVERY_WINDOW);
        vault.syncBacking(tokenId);
        assertEq(lens.totalStake(tokenId), expected - lost, "expiry preserves every located balance");
        assertEq(lens.writeOffDeadline(tokenId), 0, "and stops the clock");
    }

    /// @dev 400 alpha keeps the wrap's move above the floor for every weight split.
    function testFuzz_MergedSlots_FinalizeAtDeclarationForAnySplit(uint256 rawWeight) public {
        uint16 firstWeight = uint16(bound(rawWeight, 1, 9_999));
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(firstWeight, 10_000 - firstWeight));
        _depositAndWrap(alice, NETUID1, 400 * ALPHA);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        _simulateOffVaultSwap(NETUID1, hotkey2, hotkey4);
        MockStaking staking = MockStaking(STAKING_PRECOMPILE);
        staking.setHotkeySuccessor(hotkey1, NETUID1, hotkey4);
        staking.setHotkeySuccessor(hotkey2, NETUID1, hotkey4);
        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), 400 * ALPHA, "the merged pile is counted once");
        assertEq(_parkedStake(NETUID1), 400 * ALPHA, "and parked whole");
        assertEq(lens.missingStake(TOKEN1), 0, "nothing is missing");
        assertEq(lens.writeOffDeadline(TOKEN1), 0, "so no clock starts");
        assertEq(vault.recordedSlots(TOKEN1).length, 1, "on a record of the parking slot alone");
        assertTrue(vault.awaitingAttestation(TOKEN1), "which waits for the attesters");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "nothing stays on the first swapped hotkey");
        assertEq(_getVaultStake(hotkey2, NETUID1), 0, "nor on the second");
        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "nor on the shared successor");
    }
}

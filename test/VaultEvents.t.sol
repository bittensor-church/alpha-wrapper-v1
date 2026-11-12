// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { BackingScenarios } from "./helpers/BackingScenarios.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";

contract VaultEventsTest is BackingScenarios {
    uint256 private constant DEPOSIT = 30 * ALPHA;

    function test_Wrap_RecordsEachOpenedSlotAndTheChosenHotkey() public {
        _simulateAlphaDeposit(alice, NETUID1, DEPOSIT);

        vm.expectEmit(true, true, true, true, address(vault));
        emit SlotRelocated(TOKEN1, 0, bytes32(0), hotkey1);
        vm.expectEmit(true, true, true, true, address(vault));
        emit SlotRelocated(TOKEN1, 1, bytes32(0), hotkey2);
        vm.expectEmit(true, true, true, true, address(vault));
        emit SlotRelocated(TOKEN1, 2, bytes32(0), hotkey3);
        vm.expectEmit(true, true, true, true, address(vault));
        emit Deposited(alice, TOKEN1, hotkey1, DEPOSIT, 3e19);
        _wrapHotkey(alice, NETUID1, hotkey1);
    }

    function test_Wrap_LeavesUnmovedSlotsUnannounced() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        _simulateAlphaDeposit(bob, NETUID1, DEPOSIT);

        vm.recordLogs();
        vm.expectEmit(true, true, true, true, address(vault));
        emit Deposited(bob, TOKEN1, hotkey2, DEPOSIT, 3e19);
        _wrapHotkey(bob, NETUID1, hotkey2);

        assertEq(_countLogs(vm.getRecordedLogs(), SlotRelocated.selector), 0, "every slot stays where it was");
    }

    function test_Wrap_NamesTheChosenEntryWhenTheAlphaLandsOnItsSuccessor() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        _simulateAlphaDeposit(bob, NETUID1, DEPOSIT);

        vm.expectEmit(true, true, true, true, address(vault));
        emit Deposited(bob, TOKEN1, hotkey1, DEPOSIT, 3e19);
        _wrapHotkey(bob, NETUID1, hotkey1);

        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "nothing lands on the swapped-away hotkey");
        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, hotkey4);
    }

    function test_Unwrap_NamesAForeignDestinationColdkey() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, DEPOSIT);

        vm.expectEmit(true, true, false, true, address(vault));
        emit Unwrapped(alice, TOKEN1, _toSubstrate(bob), shares, DEPOSIT);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(bob), 0);

        assertEq(_stakeAcross(_hotkeys(hotkey1, hotkey2, hotkey3), _toSubstrate(bob), NETUID1), DEPOSIT);
    }

    function test_SyncBacking_RecordsAFollowedSwap() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);

        vm.expectEmit(true, true, true, true, address(vault));
        emit SlotRelocated(TOKEN1, 0, hotkey1, hotkey4);
        vault.syncBacking(TOKEN1);

        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, hotkey4);
    }

    function test_Rebalance_RecordsARotationOntoTheNewlyAttestedHotkey() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );

        vm.expectEmit(true, true, true, true, address(vault));
        emit SlotRelocated(TOKEN1, 0, hotkey1, hotkey4);
        vault.rebalance(NETUID1);
    }

    function test_Rebalance_ClosesTheSlotOfADroppedValidator() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));

        vm.expectEmit(true, true, true, true, address(vault));
        emit SlotRelocated(TOKEN1, 2, hotkey3, bytes32(0));
        vault.rebalance(NETUID1);

        assertEq(vault.recordedSlots(TOKEN1).length, 2);
    }

    function test_SyncBacking_RecordsTheRecoveryMovesAndClosesCollectionSlots() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        uint256 swept = _sweepDuringCrash(NETUID1, hotkey1);

        vm.recordLogs();
        vm.expectEmit(true, true, true, true, address(vault));
        emit SlotRelocated(TOKEN1, 0, hotkey1, PARKING_HOTKEY);
        vm.expectEmit(true, true, true, true, address(vault));
        emit SlotRelocated(TOKEN1, 1, hotkey2, hotkey1);
        vm.expectEmit(true, true, true, true, address(vault));
        emit SlotRelocated(TOKEN1, 2, hotkey3, hotkey2);
        vm.expectEmit(true, true, true, true, address(vault));
        emit SlotRelocated(TOKEN1, 3, bytes32(0), hotkey3);
        vault.syncBacking(TOKEN1);
        assertEq(_countLogs(vm.getRecordedLogs(), SlotRelocated.selector), 4, "parking leads, the rest renumber");

        _strangerReturns(NETUID1, hotkey4, swept);
        vault.recoverStray(TOKEN1, hotkey4);

        vm.expectEmit(true, true, true, true, address(vault));
        emit SlotRelocated(TOKEN1, 3, hotkey3, bytes32(0));
        vm.expectEmit(true, true, true, true, address(vault));
        emit SlotRelocated(TOKEN1, 2, hotkey2, bytes32(0));
        vm.expectEmit(true, true, true, true, address(vault));
        emit SlotRelocated(TOKEN1, 1, hotkey1, bytes32(0));
        vault.syncBacking(TOKEN1);

        assertEq(vault.recordedSlots(TOKEN1).length, 1);
    }

    function test_SyncBacking_KeepsASwappedAwayHotkeyAsACollectionSlot() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        _simulatePerSubnetSwap(NETUID1, hotkey1, hotkey4);
        _sweepDuringCrash(NETUID1, hotkey2);

        vm.expectEmit(true, true, true, true, address(vault));
        emit SlotRelocated(TOKEN1, 0, hotkey1, PARKING_HOTKEY);
        vm.expectEmit(true, true, true, true, address(vault));
        emit SlotRelocated(TOKEN1, 1, hotkey2, hotkey4);
        vm.expectEmit(true, true, true, true, address(vault));
        emit SlotRelocated(TOKEN1, 2, hotkey3, hotkey2);
        vm.expectEmit(true, true, true, true, address(vault));
        emit SlotRelocated(TOKEN1, 3, bytes32(0), hotkey3);
        vm.expectEmit(true, true, true, true, address(vault));
        emit SlotRelocated(TOKEN1, 4, bytes32(0), hotkey1);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingShortfallDeclared(TOKEN1, DEPOSIT, 20.001e9);
        vault.syncBacking(TOKEN1);

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots.length, 5, "parking, the three resolved hotkeys and the swapped-away one, each once");
        assertEq(slots[0].tracked, DEPOSIT, "parking carries the whole obligation");
        assertEq(slots[4].stakedUnder, hotkey1, "the swapped-away hotkey stays a collection slot");
        assertEq(slots[4].tracked, 0);
        assertEq(_parkedStake(NETUID1), 20.001e9, "the successor's and hotkey3's alpha are parked");
    }

    function test_SyncBacking_ReleasesParkingBeforeDeclaringANewShortfall() public {
        (, uint256 parkedAtNonce) = _parkedPosition(DEPOSIT);
        assertEq(parkedAtNonce, SETUP_NONCE, "parked at the only attestation so far");
        _sweepDuringCrash(NETUID1, PARKING_HOTKEY);

        vm.expectEmit(true, false, false, true, address(vault));
        emit ParkingReleased(TOKEN1, SETUP_NONCE);
        vault.syncBacking(TOKEN1);

        (uint256 shortSince, uint256 nonceAfter) = vault.recovery(TOKEN1);
        assertEq(shortSince, block.timestamp, "a new recovery window is open");
        assertEq(nonceAfter, 0);
    }

    function test_Rebalance_ReleasesParkingAfterANewerAttestation() public {
        _parkedPosition(DEPOSIT);
        _reattestValidators(NETUID1);

        vm.expectEmit(true, false, false, true, address(vault));
        emit ParkingReleased(TOKEN1, SETUP_NONCE);
        vault.rebalance(NETUID1);

        assertFalse(vault.awaitingAttestation(TOKEN1));
    }

    function test_Unwrap_PartialExitKeepsParking() public {
        (uint256 shares,) = _parkedPosition(DEPOSIT);

        vm.recordLogs();
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 1);

        assertEq(_countLogs(vm.getRecordedLogs(), ParkingReleased.selector), 0, "the position stays parked");
        assertTrue(vault.awaitingAttestation(TOKEN1));
    }

    function test_Unwrap_ReleasesParkingWhenNoSharesRemain() public {
        (uint256 shares,) = _parkedPosition(DEPOSIT);

        vm.expectEmit(true, false, false, true, address(vault));
        emit ParkingReleased(TOKEN1, SETUP_NONCE);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 1);

        (, uint256 nonceAfter) = vault.recovery(TOKEN1);
        assertEq(nonceAfter, 0);
    }

    function test_UnwrapForTao_ReleasesParkingWhenNoSharesRemain() public {
        (uint256 shares,) = _parkedPosition(DEPOSIT);

        vm.expectEmit(true, false, false, true, address(vault));
        emit ParkingReleased(TOKEN1, SETUP_NONCE);
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        (, uint256 nonceAfter) = vault.recovery(TOKEN1);
        assertEq(nonceAfter, 0);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Vm } from "forge-std/Test.sol";
import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";

contract VaultEventsTest is AlphaVaultTestBase {
    uint256 private constant DEPOSIT = 30 * ALPHA;

    function _parkedPosition() private returns (uint256 shares, uint256 parkedAtNonce) {
        shares = _depositAndWrap(alice, NETUID1, DEPOSIT);
        uint256 swept = _sweepDuringCrash(NETUID1, hotkey1);
        vault.syncBacking(TOKEN1);
        _strangerReturns(NETUID1, hotkey4, swept);
        vault.recoverStray(TOKEN1, hotkey4);
        vault.syncBacking(TOKEN1);
        (, parkedAtNonce) = vault.recovery(TOKEN1);
    }

    function _countLogs(Vm.Log[] memory logs, bytes32 selector) private view returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(vault) && logs[i].topics[0] == selector) ++count;
        }
    }

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
        _wrapHotkey(bob, NETUID1, hotkey2);

        assertEq(_countLogs(vm.getRecordedLogs(), SlotRelocated.selector), 0, "every slot stays where it was");
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
        bytes32 parking = vault.parkingHotkey();

        vm.expectEmit(true, true, true, true, address(vault));
        emit SlotRelocated(TOKEN1, 0, hotkey1, parking);
        vm.expectEmit(true, true, true, true, address(vault));
        emit SlotRelocated(TOKEN1, 3, bytes32(0), hotkey3);
        vault.syncBacking(TOKEN1);

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

    function test_Rebalance_ReleasesParkingAfterANewerAttestation() public {
        (, uint256 parkedAtNonce) = _parkedPosition();
        _reattestCurrentSet(NETUID1);

        vm.expectEmit(true, false, false, true, address(vault));
        emit ParkingReleased(TOKEN1, parkedAtNonce);
        vault.rebalance(NETUID1);

        assertFalse(vault.awaitingAttestation(TOKEN1));
    }

    function test_Unwrap_PartialExitKeepsParking() public {
        (uint256 shares,) = _parkedPosition();

        vm.recordLogs();
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 1);

        assertEq(_countLogs(vm.getRecordedLogs(), ParkingReleased.selector), 0, "the position stays parked");
        assertTrue(vault.awaitingAttestation(TOKEN1));
    }

    function test_Unwrap_ReleasesParkingWhenNoSharesRemain() public {
        (uint256 shares, uint256 parkedAtNonce) = _parkedPosition();

        vm.expectEmit(true, false, false, true, address(vault));
        emit ParkingReleased(TOKEN1, parkedAtNonce);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 1);

        (, uint256 nonceAfter) = vault.recovery(TOKEN1);
        assertEq(nonceAfter, 0);
    }

    function test_UnwrapForTao_ReleasesParkingWhenNoSharesRemain() public {
        (uint256 shares, uint256 parkedAtNonce) = _parkedPosition();

        vm.expectEmit(true, false, false, true, address(vault));
        emit ParkingReleased(TOKEN1, parkedAtNonce);
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        (, uint256 nonceAfter) = vault.recovery(TOKEN1);
        assertEq(nonceAfter, 0);
    }
}

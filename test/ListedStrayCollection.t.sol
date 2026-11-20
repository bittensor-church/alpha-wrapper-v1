// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { BackingScenarios } from "./helpers/BackingScenarios.sol";
import { BackingUnchanged } from "src/VaultErrors.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { MAX_VALIDATORS } from "src/interfaces/IValidatorRegistry.sol";

contract ListedStrayCollectionTest is BackingScenarios {
    bytes32 private constant SUCCESSOR = keccak256("successor");
    bytes32 private constant SECOND_SUCCESSOR = keccak256("second-successor");

    uint256 private constant NETUID2_DEPOSIT = 10 * ALPHA;
    uint256 private constant LARGER_SLOT = NETUID2_DEPOSIT * NETUID2_BPS_HK2 / BPS_BASE;
    uint256 private constant SMALLER_SLOT = NETUID2_DEPOSIT * NETUID2_BPS_HK1 / BPS_BASE;
    uint256 private constant NETUID2_NONCE_AFTER_SET_UP = 1;
    uint256 private constant SMALLEST_STRAY = ALPHA / 10;
    uint256 private constant ELEVEN_RISING_STRAYS = 66 * SMALLEST_STRAY;
    uint256 private constant TEN_LARGEST_STRAYS = ELEVEN_RISING_STRAYS - SMALLEST_STRAY;

    function _swapOntoVacatedHotkey(uint256 netuid, bytes32 vacated, bytes32 successor, bytes32 moved) private {
        _simulateFollowedSwap(netuid, vacated, successor);
        _simulatePerSubnetSwap(netuid, moved, vacated);
    }

    function _largerSlotOnTheSmallerSlotsVacatedHotkey() private returns (uint256 shares) {
        shares = _depositAndWrap(alice, NETUID2, NETUID2_DEPOSIT);
        _swapOntoVacatedHotkey(NETUID2, hotkey1, SUCCESSOR, hotkey2);
        assertEq(_getVaultStake(hotkey1, NETUID2), LARGER_SLOT, "the larger slot's pile sits under the vacated hotkey");
        assertEq(_getVaultStake(SUCCESSOR, NETUID2), SMALLER_SLOT, "the smaller slot's pile followed");
    }

    function _elevenRisingStraysReturned() private returns (bytes32[] memory strays) {
        strays = _hotkeysFrom("stray", MAX_VALIDATORS + 1);
        for (uint256 i; i < strays.length; ++i) {
            _strangerReturns(NETUID1, strays[i], (i + 1) * SMALLEST_STRAY);
        }
    }

    function test_CrossAssignedSlots_ReadShortUntilSynced() public {
        _largerSlotOnTheSmallerSlotsVacatedHotkey();

        assertFalse(lens.isBackingIntact(TOKEN2), "the smaller pile cannot cover the larger slot");
        assertEq(lens.locatedStake(TOKEN2), LARGER_SLOT, "the smaller slot reads the larger pile as its own");
        assertEq(lens.missingStake(TOKEN2), SMALLER_SLOT, "and the smaller pile is unaccounted for");
        assertEq(lens.writeOffDeadline(TOKEN2), type(uint256).max, "with no clock running before a sync");
    }

    function test_CrossAssignedSlots_OneSyncParksThePositionWhole() public {
        uint256 shares = _largerSlotOnTheSmallerSlotsVacatedHotkey();

        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingParked(TOKEN2, NETUID2_DEPOSIT, NETUID2_NONCE_AFTER_SET_UP);
        vm.prank(bob);
        vault.syncBacking(TOKEN2);

        assertEq(lens.writeOffDeadline(TOKEN2), 0, "no recovery window opens");
        assertEq(lens.totalStake(TOKEN2), NETUID2_DEPOSIT, "nothing is left to write off");
        assertEq(_parkedStake(NETUID2), NETUID2_DEPOSIT, "both piles rest on the parking hotkey");
        assertEq(_getVaultStake(hotkey1, NETUID2), 0, "none under the vacated hotkey");
        assertEq(_getVaultStake(SUCCESSOR, NETUID2), 0, "none under the successor");
        assertTrue(vault.awaitingAttestation(TOKEN2), "the position waits for the registry");

        _setValidators(NETUID2, _hotkeys(hotkey1, SUCCESSOR), _weights(6000, 4000));
        vm.prank(alice);
        vault.unwrap(TOKEN2, shares, _toSubstrate(alice), 0);
        assertEq(
            _getStake(hotkey1, alice, NETUID2),
            NETUID2_DEPOSIT,
            "the holder exits with the whole deposit after the release"
        );
    }

    function test_CrossAssignedSlots_ParkedPositionPaysBothExits() public {
        uint256 shares = _largerSlotOnTheSmallerSlotsVacatedHotkey();
        vault.syncBacking(TOKEN2);

        vm.prank(alice);
        vault.unwrap(TOKEN2, shares / 2, _toSubstrate(alice), 0);
        assertEq(_getStake(vault.parkingHotkey(), alice, NETUID2), 5 * ALPHA, "half the shares exit with 5 alpha");

        vm.prank(alice);
        vault.unwrapForTao(TOKEN2, shares / 2, 0);
        assertEq(alice.balance, 0.25e18, "the other half sells 5 alpha at 0.05 TAO/alpha");
    }

    function testFuzz_CrossAssignedSlots_AreNeverWrittenOff(uint256 deposit, uint256 rawWeight, bool firstSlotMoves)
        public
    {
        deposit = bound(deposit, 10 * ALPHA, 100_000 * ALPHA);
        uint16 firstWeight = uint16(bound(rawWeight, 1_000, 9_000));
        _setValidators(NETUID2, _hotkeys(hotkey2, hotkey1), _weights(firstWeight, BPS_BASE - firstWeight));
        _depositAndWrap(alice, NETUID2, deposit);

        if (firstSlotMoves) _swapOntoVacatedHotkey(NETUID2, hotkey1, SUCCESSOR, hotkey2);
        else _swapOntoVacatedHotkey(NETUID2, hotkey2, SUCCESSOR, hotkey1);

        if (!lens.isBackingIntact(TOKEN2)) vault.syncBacking(TOKEN2);

        assertEq(lens.writeOffDeadline(TOKEN2), 0, "no recovery window opens");
        assertEq(lens.totalStake(TOKEN2), deposit, "the whole deposit still backs the shares");
    }

    function testFuzz_ThreeSlotSwapCycle_IsNeverWrittenOff(uint256 deposit, uint256 rawFirst, uint256 rawSecond)
        public
    {
        deposit = bound(deposit, 30 * ALPHA, 100_000 * ALPHA);
        uint16 firstWeight = uint16(bound(rawFirst, 1_000, 4_500));
        uint16 secondWeight = uint16(bound(rawSecond, 1_000, 4_500));
        _setValidators(
            NETUID1,
            _hotkeys(hotkey1, hotkey2, hotkey3),
            _weights(firstWeight, secondWeight, BPS_BASE - firstWeight - secondWeight)
        );
        _depositAndWrap(alice, NETUID1, deposit);

        _swapOntoVacatedHotkey(NETUID1, hotkey2, SUCCESSOR, hotkey1);
        _swapOntoVacatedHotkey(NETUID1, hotkey3, SECOND_SUCCESSOR, SUCCESSOR);

        if (!lens.isBackingIntact(TOKEN1)) vault.syncBacking(TOKEN1);

        assertEq(lens.writeOffDeadline(TOKEN1), 0, "no recovery window opens");
        assertEq(lens.totalStake(TOKEN1), deposit, "the whole deposit still backs the shares");
    }

    function test_SyncBacking_DeclaresWithAListedStrayCoveringPartOfTheLoss() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _sweepDuringCrash(NETUID1, hotkey1);
        _strangerReturns(NETUID1, hotkey4, 3 * ALPHA);

        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingShortfallDeclared(TOKEN1, 30 * ALPHA, OTHER_TWO_SLOTS + 3 * ALPHA);
        vault.syncBacking(TOKEN1);

        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "the stray is drained onto the parking hotkey");
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots.length, 4, "the record holds parking and the three slots' hotkeys");
        for (uint256 i; i < slots.length; ++i) {
            assertTrue(slots[i].stakedUnder != hotkey4, "and does not name the stray");
        }
    }

    function test_SyncBacking_ClearsADeclaredShortfallFromAListedStray() public {
        _declaredShortfall();
        _strangerReturns(NETUID1, hotkey4, FIRST_SLOT);

        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingShortfallCleared(TOKEN1);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingParked(TOKEN1, 30 * ALPHA, SETUP_NONCE);
        vm.prank(bob);
        vault.syncBacking(TOKEN1);

        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "the stray is collected");
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "and the backing is whole");
    }

    function test_SyncBacking_CollectsAPartialReturnWithoutMovingTheDeadline() public {
        _declaredShortfall();
        uint256 deadline = lens.writeOffDeadline(TOKEN1);
        _strangerReturns(NETUID1, hotkey4, 3 * ALPHA);

        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingCollected(TOKEN1, 3 * ALPHA);
        vault.syncBacking(TOKEN1);

        assertEq(_parkedStake(NETUID1), OTHER_TWO_SLOTS + 3 * ALPHA, "19.998 alpha located and the 3 alpha returned");
        assertEq(lens.writeOffDeadline(TOKEN1), deadline, "the deadline did not move");
        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);
    }

    function test_WriteOff_CollectsAListedStrayBeforeBookingTheLoss() public {
        _declaredShortfall();
        _strangerReturns(NETUID1, hotkey4, 3 * ALPHA);

        vm.warp(lens.writeOffDeadline(TOKEN1));
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingWrittenOff(TOKEN1, 30 * ALPHA, OTHER_TWO_SLOTS + 3 * ALPHA);
        vault.syncBacking(TOKEN1);

        assertEq(
            lens.totalStake(TOKEN1),
            OTHER_TWO_SLOTS + 3 * ALPHA,
            "only the 7.002 alpha that never returned is written off"
        );
        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "leaving nothing for a later recovery");
    }

    function test_SyncBacking_CollectsTheLargestStraysFirst() public {
        _declaredShortfall();
        bytes32[] memory strays = _elevenRisingStraysReturned();

        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingCollected(TOKEN1, TEN_LARGEST_STRAYS);
        vault.syncBacking(TOKEN1);
        assertEq(_getVaultStake(strays[0], NETUID1), SMALLEST_STRAY, "the smallest stray waits for the next sync");
        assertEq(_vaultStakeAcross(strays, NETUID1), SMALLEST_STRAY, "and the ten larger ones are home");

        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingCollected(TOKEN1, SMALLEST_STRAY);
        vault.syncBacking(TOKEN1);
        assertEq(_vaultStakeAcross(strays, NETUID1), 0, "which collects it");
    }

    function test_WriteOff_LeavesAStrayPastTheTenLargestForRecoverStray() public {
        _declaredShortfall();
        bytes32[] memory strays = _elevenRisingStraysReturned();

        vm.warp(lens.writeOffDeadline(TOKEN1));
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingWrittenOff(TOKEN1, 30 * ALPHA, OTHER_TWO_SLOTS + TEN_LARGEST_STRAYS);
        vault.syncBacking(TOKEN1);
        assertEq(_getVaultStake(strays[0], NETUID1), SMALLEST_STRAY, "the smallest stray is written off with the loss");

        vault.recoverStray(TOKEN1, strays[0]);
        assertEq(
            lens.totalStake(TOKEN1),
            OTHER_TWO_SLOTS + TEN_LARGEST_STRAYS + SMALLEST_STRAY,
            "and joins the backing once recovered"
        );
    }

    function test_SyncBacking_CollectsAStrayAtTheMoveFloor() public {
        _declaredShortfall();
        _strangerReturns(NETUID1, hotkey4, ALPHA_FLOOR);

        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingCollected(TOKEN1, ALPHA_FLOOR);
        vault.syncBacking(TOKEN1);
    }

    function test_SyncBacking_LeavesAStrayJustBelowTheMoveFloor() public {
        _declaredShortfall();
        _strangerReturns(NETUID1, hotkey4, ALPHA_FLOOR - 1);

        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);

        assertEq(_getVaultStake(hotkey4, NETUID1), ALPHA_FLOOR - 1, "the stray waits for recoverStray");
    }

    function test_StrayUnderAnOwnerlessHotkey_WaitsForRecoverStrayToClaimIt() public {
        _declaredShortfall();
        _strangerReturns(NETUID1, hotkey4, 3 * ALPHA);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey4, true);

        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);
        (bool owned,) = MockStaking(STAKING_PRECOMPILE).getHotkeyOwner(hotkey4);
        assertFalse(owned, "the sync claims nothing");

        vm.expectEmit(true, true, true, true, address(vault));
        emit BackingRecovered(TOKEN1, hotkey4, vault.parkingHotkey(), 3 * ALPHA);
        vault.recoverStray(TOKEN1, hotkey4);
        assertEq(_hotkeyOwner(hotkey4), _cloneOwnerColdkey(NETUID1), "recoverStray claims it for the clone's owner");
    }

    function test_StrayUnderAnUnclaimableHotkey_DoesNotBlockTheWriteOff() public {
        _declaredShortfall();
        _strangerReturns(NETUID1, hotkey4, 3 * ALPHA);
        MockStaking staking = MockStaking(STAKING_PRECOMPILE);
        staking.setHotkeyDeleted(hotkey4, true);
        staking.setHashedSchemeHotkey(hotkey4, true);

        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);
        vm.warp(lens.writeOffDeadline(TOKEN1));
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingWrittenOff(TOKEN1, 30 * ALPHA, OTHER_TWO_SLOTS);
        vault.syncBacking(TOKEN1);

        staking.setHashedSchemeHotkey(hotkey4, false);
        vault.recoverStray(TOKEN1, hotkey4);
        assertEq(
            lens.totalStake(TOKEN1),
            OTHER_TWO_SLOTS + 3 * ALPHA,
            "the stray joins the backing once its hotkey can be claimed"
        );
    }

    function test_SyncBacking_LeavesStraysWhileThePriceReadsZero() public {
        _declaredShortfall();
        _strangerReturns(NETUID1, hotkey4, 3 * ALPHA);
        _setAlphaPriceReadsZero(NETUID1);

        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);

        _setAlphaPrice(NETUID1, ALPHA_PRICE);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingCollected(TOKEN1, 3 * ALPHA);
        vault.syncBacking(TOKEN1);
    }

    function test_SyncBacking_IgnoresEmptyListEntriesAtAZeroMinimum() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey3), _weights(2000, 6000, 2000));
        _depositAndWrap(alice, NETUID1, 40 * ALPHA);
        _sweepDuringCrash(NETUID1, hotkey3);
        _fillListTo(_subnetColdkey(NETUID1), 6);
        MockStaking(STAKING_PRECOMPILE).setChainMinStake(0);

        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingShortfallDeclared(TOKEN1, 40 * ALPHA, 32 * ALPHA);
        vault.syncBacking(TOKEN1);
    }

    function test_StrayBelowTheMoveFloor_DoesNotBlockTheDeclarationOrTheWriteOff() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _sweepEverySlot();
        _strangerReturns(NETUID1, hotkey4, DUST);

        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingShortfallDeclared(TOKEN1, 30 * ALPHA, 0);
        vault.syncBacking(TOKEN1);
        vm.warp(lens.writeOffDeadline(TOKEN1));
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingWrittenOff(TOKEN1, 30 * ALPHA, 0);
        vault.syncBacking(TOKEN1);

        assertEq(_getVaultStake(hotkey4, NETUID1), DUST, "the dust is still in place");
    }

    function test_RevertWhen_SyncingAnIntactPositionBesideAListedStray() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _strangerReturns(NETUID1, hotkey4, 3 * ALPHA);

        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);

        assertEq(_getVaultStake(hotkey4, NETUID1), 3 * ALPHA, "the stray waits for recoverStray");
    }
}

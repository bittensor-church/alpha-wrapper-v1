// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { MAX_STRAYS_PER_COLLECTION } from "./AlphaVaultTestBase.sol";
import { BackingScenarios } from "./helpers/BackingScenarios.sol";
import { BackingUnchanged } from "src/VaultErrors.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

/// Tests that `syncBacking` collects the alpha the clone holds under listed hotkeys the record does not
/// name, so alpha a hotkey swap relocated is parked rather than written off.
contract ListedStrayCollectionTest is BackingScenarios {
    bytes32 private constant SUCCESSOR = keccak256("successor");
    bytes32 private constant SECOND_SUCCESSOR = keccak256("second-successor");

    /// @dev NETUID2 attests hotkey2 at 60% and hotkey1 at 40%: 10 alpha puts 6 and 4 alpha under them.
    uint256 private constant LARGER_SLOT = 6 * ALPHA;
    uint256 private constant SMALLER_SLOT = 4 * ALPHA;
    /// @dev The registry nonce setUp's attestation leaves on NETUID2.
    uint256 private constant NETUID2_SETUP_NONCE = 1;
    /// @dev The ten larger of the eleven strays, 0.2 to 1.1 alpha.
    uint256 private constant TEN_LARGER_STRAYS = 65 * ALPHA / 10;

    /// @dev One validator swaps its hotkey on every subnet; the other swaps its own hotkey onto the vacated
    ///      one on this subnet, which erases the vacated hotkey's edge and writes its own.
    function _swapOntoVacatedHotkey(uint256 netuid, bytes32 vacated, bytes32 successor, bytes32 moved) private {
        _simulateFollowedSwap(netuid, vacated, successor);
        _simulatePerSubnetSwap(netuid, moved, vacated);
    }

    function _largerSlotOnTheSmallerSlotsVacatedHotkey() private returns (uint256 shares) {
        shares = _depositAndWrap(alice, NETUID2, 10 * ALPHA);
        _swapOntoVacatedHotkey(NETUID2, hotkey1, SUCCESSOR, hotkey2);
        assertEq(_getVaultStake(hotkey1, NETUID2), LARGER_SLOT, "the larger slot's pile sits under the vacated hotkey");
        assertEq(_getVaultStake(SUCCESSOR, NETUID2), SMALLER_SLOT, "the smaller slot's pile followed");
    }

    /// @dev Eleven strays of 0.1 to 1.1 alpha: 6.6 alpha, short of the 10.002 alpha lost.
    function _elevenStraysReturned() private returns (bytes32[] memory strays) {
        strays = _hotkeysFrom("stray", MAX_STRAYS_PER_COLLECTION + 1);
        for (uint256 i; i < strays.length; ++i) {
            _strangerReturns(NETUID1, strays[i], (i + 1) * ALPHA / 10);
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
        emit BackingParked(TOKEN2, 10 * ALPHA, NETUID2_SETUP_NONCE);
        vm.prank(bob);
        vault.syncBacking(TOKEN2);

        assertEq(lens.writeOffDeadline(TOKEN2), 0, "no recovery window opens");
        assertEq(lens.totalStake(TOKEN2), 10 * ALPHA, "nothing is left to write off");
        assertEq(_parkedStake(NETUID2), 10 * ALPHA, "both piles rest on the parking hotkey");
        assertEq(_getVaultStake(hotkey1, NETUID2), 0, "none under the vacated hotkey");
        assertEq(_getVaultStake(SUCCESSOR, NETUID2), 0, "none under the successor");
        assertTrue(vault.awaitingAttestation(TOKEN2), "the position waits for the registry");

        _setValidators(NETUID2, _hotkeys(hotkey1, SUCCESSOR), _weights(6000, 4000));
        vm.prank(alice);
        vault.unwrap(TOKEN2, shares, _toSubstrate(alice), 0);
        assertEq(
            _getStake(hotkey1, alice, NETUID2), 10 * ALPHA, "the holder exits with the whole deposit after the release"
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

    /// @dev Whichever slot moves onto the other's vacated hotkey, and whatever their sizes, the position is
    ///      located or parked whole.
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

    /// @dev hotkey2 and hotkey3 swap on every subnet; hotkey1 moves onto the vacated hotkey2 and hotkey2's
    ///      successor onto the vacated hotkey3, so each slot's own hotkey holds another slot's pile or nothing.
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
        bytes32[] memory strays = _elevenStraysReturned();

        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingCollected(TOKEN1, TEN_LARGER_STRAYS);
        vault.syncBacking(TOKEN1);
        assertEq(_getVaultStake(strays[0], NETUID1), ALPHA / 10, "the smallest stray waits for the next sync");
        assertEq(_vaultStakeAcross(strays, NETUID1), ALPHA / 10, "and the ten larger ones are home");

        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingCollected(TOKEN1, ALPHA / 10);
        vault.syncBacking(TOKEN1);
        assertEq(_vaultStakeAcross(strays, NETUID1), 0, "which collects it");
    }

    /// @dev A write-off never waits on strays, or gifts could hold it off for good.
    function test_WriteOff_LeavesAStrayPastTheTenLargestForRecoverStray() public {
        _declaredShortfall();
        bytes32[] memory strays = _elevenStraysReturned();

        vm.warp(lens.writeOffDeadline(TOKEN1));
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingWrittenOff(TOKEN1, 30 * ALPHA, OTHER_TWO_SLOTS + TEN_LARGER_STRAYS);
        vault.syncBacking(TOKEN1);
        assertEq(_getVaultStake(strays[0], NETUID1), ALPHA / 10, "the smallest stray is written off with the loss");

        vault.recoverStray(TOKEN1, strays[0]);
        assertEq(
            lens.totalStake(TOKEN1),
            OTHER_TWO_SLOTS + TEN_LARGER_STRAYS + ALPHA / 10,
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

    /// @dev The chain refuses the claim of a hotkey under its hashed account scheme, and stake cannot move
    ///      from a hotkey nobody owns.
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

    /// @dev A zero price read proves no pile clears the floor.
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

    /// @dev Fault injection: no runtime sets a zero stake minimum. The clone lists four hotkeys for another
    ///      subnet; holding nothing here, they must not count as strays.
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

    /// @dev A stray below the move floor stays put and blocks nothing.
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

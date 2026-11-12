// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { BackingScenarios } from "./helpers/BackingScenarios.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";
import {
    AttestedHotkeyRetired,
    BackingShortfall,
    BackingUnchanged,
    NothingToRecover,
    NothingToUnwrap,
    Parked,
    ShortfallOnFile,
    SlippageExceeded,
    SlotMaskOutOfRange,
    SubnetCloneNotPrepared,
    SubnetDissolved,
    SubnetInDissolutionBlackoutPeriod,
    WithdrawTooSmall
} from "src/VaultErrors.sol";
import { IAlphaVaultAbi } from "src/interfaces/IAlphaVaultAbi.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

/// Tests how the vault handles alpha that goes missing: declaring the loss, parking what it can find
/// on its own hotkey, holding the parked position until the attesters publish again, and writing off
/// what never comes back.
contract BackingRecoveryTest is BackingScenarios {
    struct LateCohorts {
        uint256 incumbentShares;
        uint256 incumbentValueBefore;
        uint256 incumbentValueAtRecovery;
        uint256 backingBefore;
        uint256 backingAfterWriteOff;
        uint256 finalizedWriteOff;
        uint256 recapitalizationDeposit;
        uint256 recapitalizerShares;
        uint256 recapitalizerValueBefore;
    }

    uint256 private constant PARKED_DEPOSIT = 30 * ALPHA;

    function _declaredShortfall() private returns (uint256 shares) {
        shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _sweepDuringCrash(NETUID1, hotkey1);
        vault.syncBacking(TOKEN1);
    }

    function _declaredShortfallReturnedUnder(bytes32 stray) private returns (uint256 shares) {
        shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        uint256 swept = _sweepDuringCrash(NETUID1, hotkey1);
        vault.syncBacking(TOKEN1);
        _strangerReturns(NETUID1, stray, swept);
    }

    function test_SyncBacking_DeclaresTheShortfall() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _sweepDuringCrash(NETUID1, hotkey1);

        assertEq(lens.writeOffDeadline(TOKEN1), type(uint256).max, "short, but nothing is on file before the sync");
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingShortfallDeclared(TOKEN1, 30 * ALPHA, OTHER_TWO_SLOTS);
        vm.prank(bob);
        vault.syncBacking(TOKEN1);

        assertEq(lens.writeOffDeadline(TOKEN1), block.timestamp + RECOVERY_WINDOW, "the window runs from here");
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, 30 * ALPHA, "the pool preserves the whole obligation");
        assertEq(_parkedStake(NETUID1), OTHER_TWO_SLOTS, "located backing is secured before the clock starts");
        assertFalse(lens.isBackingIntact(TOKEN1), "and the token reports itself short");
    }

    function test_SyncBacking_KeepsAFollowedSwapInTheRecord() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);

        vault.syncBacking(TOKEN1);

        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, hotkey4, "the record kept the hotkey the swap reached");
        assertEq(lens.writeOffDeadline(TOKEN1), 0, "which is not a loss and needs no clock");
        _simulateFollowedSwap(NETUID1, hotkey4, hotkey5);
        assertTrue(lens.isBackingIntact(TOKEN1), "so the next hop resolves from there");
        vault.rebalance(NETUID1);
        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, hotkey5, "and a priced call records the next hop");
        assertEq(_getVaultStake(hotkey5, NETUID1), FIRST_SLOT, "where the first slot's 10.002 alpha stays whole");
    }

    function test_RevertWhen_SyncingATokenThatAccountsForItself() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);

        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);
    }

    function test_RevertWhen_SyncingATokenWithNoPosition() public {
        vm.expectRevert(SubnetCloneNotPrepared.selector);
        vault.syncBacking(TOKEN1);
    }

    function test_RevertWhen_SyncingARetiredTokenId() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _reregisterSubnet(NETUID1);

        vm.expectRevert(SubnetDissolved.selector);
        vault.syncBacking(TOKEN1);
    }

    function test_RevertWhen_SyncingWhileTheSubnetIsDissolving() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _sweepDuringCrash(NETUID1, hotkey1);
        _setDissolving(NETUID1, true);

        vm.expectRevert(SubnetInDissolutionBlackoutPeriod.selector);
        vault.syncBacking(TOKEN1);
    }

    function test_RevertWhen_WrappingWhileAShortfallIsOnFile() public {
        _declaredShortfall();
        _simulateAlphaDeposit(bob, NETUID1, 6 * ALPHA);

        vm.expectRevert(ShortfallOnFile.selector);
        _wrapHotkey(bob, NETUID1, hotkey2);
    }

    function test_RevertWhen_UnwrappingForTaoWhileAShortfallIsOnFile() public {
        uint256 shares = _declaredShortfall();

        vm.prank(alice);
        vm.expectRevert(ShortfallOnFile.selector);
        vault.unwrapForTao(TOKEN1, shares / 4, 0);
    }

    /// @dev Alpha that comes back on its own does not reopen the vault; only a sync takes the loss off file.
    function test_DeclaredShortfall_HoldsTheTokenShutUntilSynced() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        uint256 swept = _sweepDuringCrash(NETUID1, hotkey1);
        vault.syncBacking(TOKEN1);

        _strangerReturns(NETUID1, hotkey1, swept);

        assertFalse(lens.isBackingIntact(TOKEN1), "the loss is still on file");
        vm.expectRevert(ShortfallOnFile.selector);
        vault.rebalance(NETUID1);
        vm.prank(alice);
        vm.expectRevert(ShortfallOnFile.selector);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 0);

        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingShortfallCleared(TOKEN1);
        vault.syncBacking(TOKEN1);

        assertTrue(lens.isBackingIntact(TOKEN1), "the sync took it off file");
        assertEq(lens.writeOffDeadline(TOKEN1), 0, "and stopped the clock");
        _reattestValidators(NETUID1);
        vault.rebalance(NETUID1);
        assertEq(_parkedStake(NETUID1), 0, "the next attestation takes the position off the parking hotkey");
        assertEq(_getVaultStake(hotkey1, NETUID1), FIRST_SLOT, "back onto the set by weight");
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "with the backing whole");
    }

    /// @dev A cleared loss must not lend its expired clock to a later shortfall.
    function test_ClearedShortfall_StartsAFreshClockOnTheNextLoss() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        uint256 swept = _sweepDuringCrash(NETUID1, hotkey1);
        vault.syncBacking(TOKEN1);
        _strangerReturns(NETUID1, hotkey1, swept);
        vault.syncBacking(TOKEN1);

        _reattestValidators(NETUID1);
        vault.rebalance(NETUID1);
        vm.warp(block.timestamp + 2 * RECOVERY_WINDOW);
        _sweepDuringCrash(NETUID1, hotkey1);
        vault.syncBacking(TOKEN1);

        assertEq(lens.writeOffDeadline(TOKEN1), block.timestamp + RECOVERY_WINDOW, "the new loss gets a full window");
        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);
    }

    function test_RecoverStray_ParksTheWholePosition() public {
        _declaredShortfallReturnedUnder(hotkey4);
        assertFalse(lens.isBackingIntact(TOKEN1), "the loss is visible first");
        bytes32 parking = vault.parkingHotkey();

        vm.expectEmit(true, true, true, true, address(vault));
        emit BackingRecovered(TOKEN1, hotkey4, parking, FIRST_SLOT);
        vm.prank(bob);
        vault.recoverStray(TOKEN1, hotkey4);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingParked(TOKEN1, 30 * ALPHA, SETUP_NONCE);
        vault.syncBacking(TOKEN1);

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots.length, 1, "the record collapses to one slot");
        assertEq(slots[0].stakedUnder, parking, "on the parking hotkey");
        assertEq(slots[0].attested, parking, "attested as the parking hotkey");
        assertEq(slots[0].tracked, 30 * ALPHA, "expecting the whole position");
        assertEq(_parkedStake(NETUID1), 30 * ALPHA, "which is where the alpha is");
        assertEq(_totalVaultStakeAcrossHotkeys(NETUID1) + _getVaultStake(hotkey4, NETUID1), 0, "nothing stays behind");
        assertTrue(lens.isBackingIntact(TOKEN1), "the position accounts for itself");
        assertEq(lens.writeOffDeadline(TOKEN1), 0, "the clock is gone");
        assertTrue(vault.awaitingAttestation(TOKEN1), "and it waits for the attesters");
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "backing whole after recovery");
    }

    function test_RecoverStray_RequiresSyncToDeclareTheLoss() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        uint256 swept = _sweepDuringCrash(NETUID1, hotkey1);
        vm.expectRevert(abi.encodeWithSelector(BackingShortfall.selector, NETUID1, hotkey1, FIRST_SLOT));
        vm.prank(bob);
        vault.recoverStray(TOKEN1, hotkey4);

        vault.syncBacking(TOKEN1);
        _strangerReturns(NETUID1, hotkey4, swept);
        vault.recoverStray(TOKEN1, hotkey4);
        vault.syncBacking(TOKEN1);
        assertTrue(vault.awaitingAttestation(TOKEN1), "once declared, the recovery parks the position");
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "with the backing whole");
    }

    function test_RevertWhen_RecoveringTheTipOfATrailTheSearchLocated() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 tip = _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.syncBacking(TOKEN1);
        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, tip, "the sync records the hotkey found on the list");

        vm.expectRevert(NothingToRecover.selector);
        vm.prank(bob);
        vault.recoverStray(TOKEN1, tip);
    }

    function test_RecoverStray_CoversTwoLossesInSeparateCalls() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        uint256 firstSwept = _sweepDuringCrash(NETUID1, hotkey1);
        uint256 secondSwept = _sweepDuringCrash(NETUID1, hotkey2);
        vault.syncBacking(TOKEN1);
        _strangerReturns(NETUID1, hotkey4, firstSwept);
        _strangerReturns(NETUID1, hotkey5, secondSwept);

        vm.prank(bob);
        vault.recoverStray(TOKEN1, hotkey4);
        vm.prank(bob);
        vault.recoverStray(TOKEN1, hotkey5);
        vault.syncBacking(TOKEN1);

        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "both lumps are home");
        assertEq(_parkedStake(NETUID1), 30 * ALPHA, "on the parking hotkey");
    }

    function test_RecoverStray_BringsAnEmissionGrownLumpHome() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _sweepDuringCrash(NETUID1, hotkey1);
        vault.syncBacking(TOKEN1);
        _strangerReturns(NETUID1, hotkey4, FIRST_SLOT + 2 * ALPHA);

        vm.prank(bob);
        vault.recoverStray(TOKEN1, hotkey4);
        vault.syncBacking(TOKEN1);

        assertEq(lens.totalStake(TOKEN1), 32 * ALPHA, "the emissions came home with the lump");
    }

    /// @dev The chain refuses to move stake from a hotkey nobody owns; the clone's owner contract claims it and moves on.
    function test_RecoverStray_ClaimsAnOwnerlessSourceForTheCloneOwner() public {
        _declaredShortfallReturnedUnder(hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey4, true);

        vm.prank(bob);
        vault.recoverStray(TOKEN1, hotkey4);
        vault.syncBacking(TOKEN1);

        assertEq(_hotkeyOwner(hotkey4), _cloneOwnerColdkey(NETUID1), "the clone's owner contract, not the caller");
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "and the alpha is parked");
    }

    function test_RecoverStray_ParksPartialCoverageWithoutChangingTheDeadline() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        uint256 swept = _sweepDuringCrash(NETUID1, hotkey1);
        vault.syncBacking(TOKEN1);
        uint256 deadline = block.timestamp + RECOVERY_WINDOW;
        _strangerReturns(NETUID1, hotkey4, swept / 3);
        _strangerReturns(NETUID1, hotkey5, swept);

        vm.prank(bob);
        vault.recoverStray(TOKEN1, hotkey4);
        assertFalse(lens.isBackingIntact(TOKEN1), "the loss still stands");
        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "the partial recovery is secured");
        assertEq(lens.missingStake(TOKEN1), 6_668_000_000, "10.002 alpha lost less the 3.334 alpha returned");
        assertEq(lens.writeOffDeadline(TOKEN1), deadline, "and the deadline did not move");

        vm.prank(bob);
        vault.recoverStray(TOKEN1, hotkey5);
        vault.syncBacking(TOKEN1);
        assertTrue(lens.isBackingIntact(TOKEN1), "the hotkey covering the loss parks it");
        assertEq(lens.writeOffDeadline(TOKEN1), 0, "and the window ends");
    }

    function test_RevertWhen_RecoveringFromAHotkeyHoldingNothing() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);

        vm.expectRevert(NothingToRecover.selector);
        vault.recoverStray(TOKEN1, hotkey5);
    }

    function test_RevertWhen_RecoveringFromTheSlotsOwnHotkey() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);

        vm.expectRevert(NothingToRecover.selector);
        vault.recoverStray(TOKEN1, hotkey1);
    }

    function test_RevertWhen_RecoveringFromAHotkeyASlotResolvesTo() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);

        vm.expectRevert(NothingToRecover.selector);
        vm.prank(bob);
        vault.recoverStray(TOKEN1, hotkey4);
    }

    function test_RevertWhen_RecoveringOnATokenWithNoSlots() public {
        vault.createMailbox(NETUID1, keccak256("fixture-creation"));
        _strangerReturns(NETUID1, hotkey4, 5 * ALPHA);

        vm.expectRevert(NothingToRecover.selector);
        vault.recoverStray(TOKEN1, hotkey4);
    }

    function test_RevertWhen_RecoveringBeforeTheCloneExists() public {
        vm.expectRevert(SubnetCloneNotPrepared.selector);
        vault.recoverStray(TOKEN1, hotkey4);
    }

    function test_RevertWhen_RecoveringOnARetiredTokenId() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _reregisterSubnet(NETUID1);

        vm.expectRevert(SubnetDissolved.selector);
        vault.recoverStray(TOKEN1, hotkey4);
    }

    function test_RecoverStray_AnnexesADonationToTheFirstSlot() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _strangerReturns(NETUID1, hotkey4, 3 * ALPHA);

        vm.expectEmit(true, true, true, true, address(vault));
        emit BackingRecovered(TOKEN1, hotkey4, hotkey1, 3 * ALPHA);
        vault.recoverStray(TOKEN1, hotkey4);

        assertEq(lens.totalStake(TOKEN1), 33 * ALPHA, "the donation is new backing");
        assertFalse(vault.awaitingAttestation(TOKEN1), "and nothing parked");
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, FIRST_SLOT + 3 * ALPHA, "booked on the first slot");
    }

    function test_RecoverStray_CarriesAStrayBelowTheMoveFloorHomeWithTheSlotsOwnPile() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _strangerReturns(NETUID1, hotkey4, CRUMB);

        vm.expectEmit(true, true, true, true, address(vault));
        emit BackingRecovered(TOKEN1, hotkey4, hotkey1, CRUMB);
        vault.recoverStray(TOKEN1, hotkey4);

        assertEq(lens.totalStake(TOKEN1), 30_002_000_000, "30 alpha and the 0.002 alpha stray");
        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "and nothing stays behind");
    }

    function test_RecoverStray_AnnexReanchorsASlotFollowedThroughASwap() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        _strangerReturns(NETUID1, hotkey5, 3 * ALPHA);
        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, hotkey1, "the record still shows the swapped hotkey");

        vm.expectEmit(true, true, true, true, address(vault));
        emit SlotRelocated(TOKEN1, 0, hotkey1, hotkey4);
        vm.expectEmit(true, true, true, true, address(vault));
        emit BackingRecovered(TOKEN1, hotkey5, hotkey4, 3 * ALPHA);
        vault.recoverStray(TOKEN1, hotkey5);

        VaultReads.Slot memory slot = vault.recordedSlots(TOKEN1)[0];
        assertEq(slot.stakedUnder, hotkey4, "the slot now points at the successor holding its stake");
        assertEq(slot.tracked, FIRST_SLOT + 3 * ALPHA, "and expects exactly what sits there");
        assertEq(_getVaultStake(hotkey5, NETUID1), 0, "the stray came home");
        assertEq(lens.totalStake(TOKEN1), 33 * ALPHA, "as new backing");
    }

    function test_RevertWhen_NeitherTheStrayNorTheSlotCanMoveTheirPile() public {
        _depositAndWrap(alice, NETUID1, ALPHA);
        // At 0.001 TAO/alpha the 2e6 RAO floor is 2 alpha, above the 0.3334 alpha slot and the 0.1 alpha stray.
        _setAlphaPrice(NETUID1, 0.001e18);
        _strangerReturns(NETUID1, hotkey4, ALPHA / 10);

        vm.expectRevert(IAlphaVaultAbi.ConsolidationBelowFloor.selector);
        vault.recoverStray(TOKEN1, hotkey4);
    }

    function test_RevertWhen_DepositingRebalancingOrSyncingAParkedPositionBeforeANewAttestation() public {
        _parkedPosition(PARKED_DEPOSIT);

        _simulateAlphaDeposit(bob, NETUID1, ALPHA);
        vm.expectRevert(Parked.selector);
        vm.prank(bob);
        vault.wrap(NETUID1, hotkey1, 0);
        vm.expectRevert(Parked.selector);
        vault.rebalance(NETUID1);
        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);
    }

    function test_ParkedPosition_PaysAlphaExitsFromTheParkingHotkey() public {
        (uint256 shares,) = _parkedPosition(PARKED_DEPOSIT);
        bytes32 parking = vault.parkingHotkey();

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 1);

        assertEq(_getStake(parking, alice, NETUID1), 7_500_000_000, "the exit is delivered on the parking hotkey");
        assertEq(_parkedStake(NETUID1), 22_500_000_000, "leaving the rest parked");
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, 22_500_000_000, "with the record following");
        assertTrue(vault.awaitingAttestation(TOKEN1), "and the position still waiting");
    }

    function test_ParkedPosition_PaysTaoExitsFromTheParkingHotkey() public {
        (uint256 shares,) = _parkedPosition(PARKED_DEPOSIT);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 2, 0);

        assertEq(alice.balance, 0.75e18, "15 alpha sold at 0.05 TAO/alpha");
        assertEq(_parkedStake(NETUID1), 15 * ALPHA, "from the parked balance");
        assertTrue(vault.awaitingAttestation(TOKEN1), "which stays parked");
    }

    function test_RevertWhen_AParkedTaoExitExcludesItsOnlySlot() public {
        (uint256 shares,) = _parkedPosition(PARKED_DEPOSIT);

        vm.prank(alice);
        vm.expectRevert(WithdrawTooSmall.selector);
        vault.unwrapForTao(TOKEN1, shares / 2, 0, 1 << 0);
    }

    function test_RevertWhen_AParkedTaoExitExcludesASlotPastTheParkingSlot() public {
        (uint256 shares,) = _parkedPosition(PARKED_DEPOSIT);

        vm.prank(alice);
        vm.expectRevert(SlotMaskOutOfRange.selector);
        vault.unwrapForTao(TOKEN1, shares / 2, 0, 1 << 1);
    }

    function test_ParkedPosition_FullTaoExitReleasesIt() public {
        (uint256 shares,) = _parkedPosition(PARKED_DEPOSIT);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(vault.totalSupply(TOKEN1), 0, "nothing outstanding");
        assertFalse(vault.awaitingAttestation(TOKEN1), "with no shares left there is nothing to hold");
        _depositAndWrap(bob, NETUID1, 5 * ALPHA);
        assertEq(lens.totalStake(TOKEN1), 5 * ALPHA, "and the next depositor starts a fresh position");
    }

    /// @dev Stake is keyed by hotkey, coldkey and netuid, so one parking hotkey serves every subnet.
    function test_ParkedPosition_LeavesOtherSubnetsUntouched() public {
        _parkedPosition(PARKED_DEPOSIT);

        uint256 shares = _depositAndWrap(bob, NETUID2, 10 * ALPHA);
        vault.rebalance(NETUID2);
        vm.prank(bob);
        vault.unwrap(TOKEN2, shares / 2, _toSubstrate(bob), 0);

        assertFalse(vault.awaitingAttestation(TOKEN2), "the other subnet is not parked");
        assertEq(_parkedStake(NETUID2), 0, "and holds nothing on the parking hotkey");
        assertEq(_parkedStake(NETUID1), 30 * ALPHA, "while the parked subnet's balance did not move");
        assertTrue(vault.awaitingAttestation(TOKEN1), "and still waits for its own attesters");
    }

    function test_ParkedPosition_KeepsTransfersAndClaimsLive() public {
        (uint256 shares,) = _parkedPosition(PARKED_DEPOSIT);
        _donateToClone(vault.subnetClone(TOKEN1), 4 * TAO);

        vm.prank(alice);
        vault.safeTransferFrom(alice, bob, TOKEN1, shares / 2, "");
        assertEq(vault.balanceOf(bob, TOKEN1), 1.5e19, "shares move while parked");

        assertEq(
            _claimQuotedAmount(alice, TOKEN1),
            3_999_999_999_000_000_000,
            "4 TAO over 3e19 shares, floored on the index and to whole RAO"
        );
    }

    function test_ParkedPosition_FullExitRetiresEveryShare() public {
        (uint256 shares,) = _parkedPosition(PARKED_DEPOSIT);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        assertEq(vault.totalSupply(TOKEN1), 0, "nothing outstanding");
        assertEq(_parkedStake(NETUID1), 0, "and nothing left parked");
        assertEq(_getStake(vault.parkingHotkey(), alice, NETUID1), 30 * ALPHA, "the holder took the position");
        assertFalse(vault.awaitingAttestation(TOKEN1), "with no shares left there is nothing to hold");

        _depositAndWrap(bob, NETUID1, 5 * ALPHA);
        assertEq(lens.totalStake(TOKEN1), 5 * ALPHA, "and the next depositor starts a fresh position");
    }

    function _exitEveryShare() private {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
        assertEq(vault.totalSupply(TOKEN1), 0, "nobody holds the token");
    }

    function _paidSweep(bytes32 hotkey) private {
        MockStaking(STAKING_PRECOMPILE).sweepSmallNomination(hotkey, vault.subnetClone(TOKEN1), NETUID1);
    }

    function testFuzz_WriteOffAtZeroSupply_ReopensTheEmptyToken(uint256 rawGift) public {
        // From the 0.002 alpha transfer minimum to just below the 0.04 alpha the vault can move.
        uint256 gift = bound(rawGift, CRUMB, ALPHA_FLOOR - 1);
        _exitEveryShare();
        _strangerReturns(NETUID1, hotkey3, gift);
        vault.rebalance(NETUID1);
        assertEq(vault.recordedSlots(TOKEN1)[2].tracked, gift, "the unheld stake is recorded");

        _paidSweep(hotkey3);
        vault.syncBacking(TOKEN1);
        assertEq(lens.writeOffDeadline(TOKEN1), block.timestamp + RECOVERY_WINDOW, "the loss is declared");
        _simulateAlphaDeposit(bob, NETUID1, 5 * ALPHA);
        vm.prank(bob);
        vm.expectRevert(ShortfallOnFile.selector);
        vault.wrap(NETUID1, hotkey1, 0);

        vm.warp(lens.writeOffDeadline(TOKEN1));
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingWrittenOff(TOKEN1, gift, 0);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingParked(TOKEN1, 0, 0);
        vault.syncBacking(TOKEN1);

        assertFalse(vault.awaitingAttestation(TOKEN1), "nobody holds a share to protect");
        assertEq(vault.totalSupply(TOKEN1), 0, "and no share was minted on the way");
        assertEq(lens.totalStake(TOKEN1), 0, "nothing was located");
        _wrap(bob, NETUID1);
        assertEq(vault.balanceOf(bob, TOKEN1), 5e18, "deposits reopen without a registry update");
        assertEq(lens.totalStake(TOKEN1), 5 * ALPHA, "backed by the deposit alone");
        vault.rebalance(NETUID1);
        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);
    }

    function test_WriteOffAtZeroSupply_KeepsTheLocatedAlphaForTheNextDepositor() public {
        _exitEveryShare();
        _strangerReturns(NETUID1, hotkey1, 50_000_000);
        _strangerReturns(NETUID1, hotkey3, 30_000_000);
        vault.rebalance(NETUID1);
        assertEq(lens.totalStake(TOKEN1), 80_000_000, "the vault records stake nobody holds shares for");

        _sweepDuringCrash(NETUID1, hotkey3);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingShortfallDeclared(TOKEN1, 80_000_000, 50_000_000);
        vault.syncBacking(TOKEN1);
        vm.warp(lens.writeOffDeadline(TOKEN1));
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingWrittenOff(TOKEN1, 80_000_000, 50_000_000);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingParked(TOKEN1, 50_000_000, 0);
        vault.syncBacking(TOKEN1);

        assertFalse(vault.awaitingAttestation(TOKEN1), "nobody holds a share to protect");
        assertEq(_parkedStake(NETUID1), 50_000_000, "the located alpha rests on the parking hotkey");
        assertEq(lens.writeOffDeadline(TOKEN1), 0, "the clock is gone");

        _depositAndWrap(bob, NETUID1, 5 * ALPHA);
        assertEq(lens.totalStake(TOKEN1), 5_050_000_000, "the deposit carries the parked alpha onto the attested set");
        assertEq(_parkedStake(NETUID1), 0, "leaving the parking hotkey empty");
        assertEq(vault.recordedSlots(TOKEN1).length, 3, "on a record of the attested set");
    }

    function _positionReturnedAsDust() private {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _sweepEverySlot();
        _strangerReturns(NETUID1, hotkey1, DUST);
    }

    function test_SubFloorBacking_IsDeclaredAndWrittenOffInPlace() public {
        _positionReturnedAsDust();

        vault.syncBacking(TOKEN1);
        assertEq(lens.writeOffDeadline(TOKEN1), block.timestamp + RECOVERY_WINDOW, "the loss is declared");
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, 30 * ALPHA, "the pool preserves the whole obligation");
        assertEq(_getVaultStake(hotkey1, NETUID1), 20_000_000, "the 0.02 alpha of dust stays below the move floor");

        vm.warp(lens.writeOffDeadline(TOKEN1));
        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), 0, "nothing movable was located");
        assertEq(_getVaultStake(hotkey1, NETUID1), 20_000_000, "and the dust is still in place");
        assertTrue(vault.awaitingAttestation(TOKEN1), "the emptied position waits for the attesters");
    }

    function test_DustLeftByAWriteOff_ComesHomeWithALaterFind() public {
        _positionReturnedAsDust();
        _runOutRecoveryWindow(TOKEN1);

        _strangerReturns(NETUID1, hotkey5, ALPHA);
        vault.recoverStray(TOKEN1, hotkey5);
        vault.recoverStray(TOKEN1, hotkey1);

        assertEq(lens.totalStake(TOKEN1), 1_020_000_000, "the 1 alpha find carries the 0.02 alpha of dust home");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "leaving nothing under the swept hotkey");
    }

    /// @dev 0.3 alpha is below the 0.4 alpha nominator minimum at 0.05 TAO/alpha; its sweep pays 0.015 TAO.
    function test_SweptParkedPosition_IsWrittenOffAndItsSaleStaysClaimable() public {
        uint256 parked = 3 * ALPHA / 10;
        (uint256 shares,) = _parkedPosition(parked);
        bytes32 parking = vault.parkingHotkey();
        _paidSweep(parking);

        assertFalse(lens.isBackingIntact(TOKEN1), "the parked position is short");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BackingShortfall.selector, NETUID1, parking, parked));
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingShortfallDeclared(TOKEN1, parked, 0);
        vault.syncBacking(TOKEN1);
        vm.warp(lens.writeOffDeadline(TOKEN1));
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingWrittenOff(TOKEN1, parked, 0);
        vault.syncBacking(TOKEN1);

        assertEq(_claimQuotedAmount(alice, TOKEN1), 0.015e18, "the sale's TAO is the holders' claim");
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
        assertEq(vault.totalSupply(TOKEN1), 0, "and the emptied shares retire");
    }

    function test_NewAttestation_ReleasesTheParkedPosition() public {
        _parkedPosition(PARKED_DEPOSIT);

        _reattestValidators(NETUID1);
        assertFalse(vault.awaitingAttestation(TOKEN1), "the newer nonce lifts the hold");
        vault.rebalance(NETUID1);

        assertEq(_parkedStake(NETUID1), 0, "the parking hotkey is empty again");
        assertEq(vault.recordedSlots(TOKEN1).length, 3, "the record follows the attested set");
        assertEq(_getVaultStake(hotkey1, NETUID1), FIRST_SLOT, "spread by weight");
        assertEq(_getVaultStake(hotkey2, NETUID1), OTHER_SLOT, "spread by weight");
        assertEq(_getVaultStake(hotkey3, NETUID1), OTHER_SLOT, "spread by weight");
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "with nothing lost in the release");
        (, uint256 parkedAtNonce) = vault.recovery(TOKEN1);
        assertEq(parkedAtNonce, 0, "and the position is ordinary again");
    }

    function test_Wrap_ReleasesAParkedPositionAfterANewAttestation() public {
        _parkedPosition(PARKED_DEPOSIT);
        _reattestValidators(NETUID1);

        _simulateAlphaDeposit(bob, NETUID1, 6 * ALPHA);
        vm.expectEmit(true, false, false, true, address(vault));
        emit ParkingReleased(TOKEN1, SETUP_NONCE);
        _wrapHotkey(bob, NETUID1, hotkey2);

        assertEq(vault.balanceOf(bob, TOKEN1), 6e18, "6 alpha against 30 alpha on 3e19 shares");
        assertEq(_parkedStake(NETUID1), 0, "and the parked alpha moved onto the set with it");
        assertEq(lens.totalStake(TOKEN1), 36 * ALPHA, "backing whole across the release");
    }

    function test_ReplacingTheLostAttestedHotkey_RoutesParkedAlphaToTheSuccessor() public {
        _parkedPosition(PARKED_DEPOSIT);

        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "nothing goes back to the lost hotkey");
        assertEq(_getVaultStake(hotkey4, NETUID1), FIRST_SLOT, "its weight went to the successor");
        assertEq(_parkedStake(NETUID1), 0, "and the parking hotkey is empty");
    }

    function test_LateFoundAlpha_JoinsTheParkedPosition() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        uint256 swept = _sweepDuringCrash(NETUID1, hotkey1);
        _runOutRecoveryWindow(TOKEN1);
        assertTrue(vault.awaitingAttestation(TOKEN1), "the write-off parks what is left");
        assertEq(_parkedStake(NETUID1), OTHER_TWO_SLOTS, "the two unswept slots' 19.998 alpha");

        _strangerReturns(NETUID1, hotkey4, swept);
        vault.recoverStray(TOKEN1, hotkey4);

        assertEq(_parkedStake(NETUID1), 30 * ALPHA, "the find joins the parked alpha");
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "and the backing is whole again");
    }

    function _dissolveWithPot(uint256 pot) private {
        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(TOKEN1, pot);
        _simulateDissolutionCompleted(NETUID1);
    }

    function test_DissolvedSubnet_PaysAParkedPositionInTao() public {
        (uint256 shares,) = _parkedPosition(PARKED_DEPOSIT);
        _dissolveWithPot(1.5e18);

        vm.expectEmit(true, true, false, true, address(vault));
        emit DissolvedSubnetUnwrapped(alice, TOKEN1, 1.5e19, 0.75e18);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice), 0);

        assertEq(alice.balance, 0.75e18, "half the shares take half the 1.5 TAO pot");
    }

    function test_DissolvedSubnet_PaysAPositionWithAShortfallOnFile() public {
        uint256 shares = _declaredShortfall();
        _dissolveWithPot(1.5e18);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice), 0);

        assertEq(alice.balance, 0.75e18, "half the shares take half the 1.5 TAO pot");
    }

    function test_WriteOff_ParksWhatIsLeft() public {
        _declaredShortfall();

        vm.warp(lens.writeOffDeadline(TOKEN1));
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingWrittenOff(TOKEN1, 30 * ALPHA, OTHER_TWO_SLOTS);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingParked(TOKEN1, OTHER_TWO_SLOTS, SETUP_NONCE);
        vm.prank(bob);
        vault.syncBacking(TOKEN1);

        assertEq(lens.totalStake(TOKEN1), OTHER_TWO_SLOTS, "the quote answers on what is there");
        assertEq(_parkedStake(NETUID1), OTHER_TWO_SLOTS, "parked on the vault's hotkey");
        assertEq(lens.writeOffDeadline(TOKEN1), 0, "with no clock left running");
        assertTrue(vault.awaitingAttestation(TOKEN1), "waiting for the attesters");
    }

    function _writtenOffEmptyPosition() private returns (uint256 shares) {
        shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _sweepEverySlot();
        _runOutRecoveryWindow(TOKEN1);
    }

    function test_WriteOff_WithNothingLocatedParksAnEmptyPosition() public {
        uint256 shares = _writtenOffEmptyPosition();

        assertEq(lens.totalStake(TOKEN1), 0, "nothing is left");
        (uint256 quote,) = lens.previewUnwrap(TOKEN1, shares);
        assertEq(quote, 0, "the shares quote zero alpha");

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
        assertEq(vault.balanceOf(alice, TOKEN1), 0, "a zero floor retires the shares");
    }

    function test_RevertWhen_ExitingAnEmptyPositionWithANonzeroFloor() public {
        uint256 shares = _writtenOffEmptyPosition();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, 0));
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 1);
    }

    function test_WrittenOffEmptyPosition_RefusesATaoExitUntilTheAlphaIsFound() public {
        uint256 shares = _writtenOffEmptyPosition();

        vm.prank(alice);
        vm.expectRevert(NothingToUnwrap.selector);
        vault.unwrapForTao(TOKEN1, shares, 0);

        _strangerReturns(NETUID1, hotkey4, FIRST_SLOT);
        vault.recoverStray(TOKEN1, hotkey4);
        assertEq(_parkedStake(NETUID1), FIRST_SLOT, "the watcher parks the first slot's alpha");

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);
        assertEq(alice.balance, 0.5001e18, "the kept shares sell the found 10.002 alpha at 0.05 TAO/alpha");
    }

    function testFuzz_RevertWhen_WritingOffBeforeTheDeadline(uint256 offset) public {
        _declaredShortfall();
        uint256 deadline = lens.writeOffDeadline(TOKEN1);

        vm.warp(bound(offset, deadline - RECOVERY_WINDOW, deadline - 1));

        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);
        vm.expectRevert(ShortfallOnFile.selector);
        lens.totalStake(TOKEN1);
    }

    function testFuzz_WriteOff_FallsDueFromTheDeadlineOn(uint256 offset) public {
        _declaredShortfall();
        uint256 deadline = lens.writeOffDeadline(TOKEN1);

        vm.warp(bound(offset, deadline, deadline + RECOVERY_WINDOW));
        vault.syncBacking(TOKEN1);

        assertTrue(vault.awaitingAttestation(TOKEN1), "the loss is booked from the deadline on");
        assertEq(lens.totalStake(TOKEN1), OTHER_TWO_SLOTS, "and the quote answers on what is left");
    }

    function test_PastTheDeadline_OnlySyncBackingBooksTheLoss() public {
        uint256 shares = _declaredShortfall();

        vm.warp(lens.writeOffDeadline(TOKEN1));
        vm.expectRevert(ShortfallOnFile.selector);
        lens.totalStake(TOKEN1);
        vm.expectRevert(ShortfallOnFile.selector);
        vault.rebalance(NETUID1);
        vm.prank(alice);
        vm.expectRevert(ShortfallOnFile.selector);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 0);

        vm.prank(bob);
        vault.syncBacking(TOKEN1);

        assertEq(lens.totalStake(TOKEN1), OTHER_TWO_SLOTS, "the quote answers on what is there");
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 0);
        assertEq(_getStake(vault.parkingHotkey(), alice, NETUID1), 4_999_500_000, "a quarter of the 19.998 alpha left");
    }

    function test_RecoveryWindow_SetAtDeploymentDrivesTheDeadline() public {
        (vault, lens) = _deployVaultAndLens(address(registry), 1 hours);
        _depositAndWrap(alice, NETUID1, 10 * ALPHA);
        _sweepDuringCrash(NETUID1, hotkey1);

        vault.syncBacking(TOKEN1);

        assertEq(lens.writeOffDeadline(TOKEN1), block.timestamp + 1 hours, "the deadline runs on the deployed window");
        vm.warp(block.timestamp + 1 hours);
        vault.syncBacking(TOKEN1);
        assertTrue(vault.awaitingAttestation(TOKEN1), "and the write-off falls due on it too");
        assertEq(lens.totalStake(TOKEN1), 6_666_000_000, "leaving the two unswept 3.333 alpha slots");
    }

    function test_LateFoundAlpha_IsAWindfallForTheCurrentCohort() public {
        uint256 aliceShares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        uint256 swept = _sweepDuringCrash(NETUID1, hotkey1);
        _runOutRecoveryWindow(TOKEN1);
        _reattestValidators(NETUID1);
        vault.rebalance(NETUID1);

        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares, _toSubstrate(alice), 0);
        uint256 bobShares = _depositAndWrap(bob, NETUID1, 10 * ALPHA);

        _strangerReturns(NETUID1, hotkey4, swept);
        vm.prank(alice);
        vault.recoverStray(TOKEN1, hotkey4);

        assertEq(lens.totalStake(TOKEN1), 20_002_000_000, "the find is new backing");
        vm.prank(bob);
        vault.unwrap(TOKEN1, bobShares, _toSubstrate(bob), 0);
        assertEq(
            _userStakeAcrossHotkeys(bob, NETUID1),
            20_001_999_998,
            "the holder at recovery takes it: 1e19 * (20.002e9 + 1) / (1e19 + 1e9), floored"
        );
        assertEq(vault.balanceOf(alice, TOKEN1), 0, "not the cohort that bore the loss");
    }

    /// @dev No growth on hidden backing here. Partial-loss deposits exercise material cohort splits;
    ///      full-loss deposits are bounded below the virtual-rate supply cap.
    function testFuzz_LateRecovery_CannotDiluteIncumbentByMoreThanFinalizedWriteOff(
        uint256 incumbentDeposit,
        uint256 recapitalizationSeed,
        uint256 hiddenSlotCount
    ) public {
        incumbentDeposit = bound(incumbentDeposit, 30 * ALPHA, 100_000 * ALPHA);
        hiddenSlotCount = bound(hiddenSlotCount, 1, 3);

        LateCohorts memory cohorts = _openIncumbentCohort(incumbentDeposit);

        bytes32[] memory recordedHotkeys = _hotkeys(hotkey1, hotkey2, hotkey3);
        uint256[] memory piles = new uint256[](hiddenSlotCount);
        uint256 hidden;
        for (uint256 i; i < hiddenSlotCount; ++i) {
            piles[i] = _sweepDuringCrash(NETUID1, recordedHotkeys[i]);
            hidden += piles[i];
        }

        _runOutRecoveryWindow(TOKEN1);
        cohorts.backingAfterWriteOff = lens.totalStake(TOKEN1);
        cohorts.finalizedWriteOff = cohorts.backingBefore - cohorts.backingAfterWriteOff;
        assertEq(cohorts.finalizedWriteOff, hidden, "the finalized deficit is exactly the hidden principal");

        _reattestValidators(NETUID1);
        cohorts.recapitalizationDeposit = cohorts.backingAfterWriteOff == 0
            ? bound(recapitalizationSeed, ALPHA_FLOOR, ALPHA)
            : bound(recapitalizationSeed, cohorts.backingAfterWriteOff / 4, cohorts.backingAfterWriteOff * 4);
        _addRecapitalizer(cohorts);
        for (uint256 i; i < hiddenSlotCount; ++i) {
            bytes32 stray = keccak256(abi.encode("stray", i));
            _strangerReturns(NETUID1, stray, piles[i]);
            vm.prank(bob);
            vault.recoverStray(TOKEN1, stray);
        }

        assertEq(
            lens.totalStake(TOKEN1),
            incumbentDeposit + cohorts.recapitalizationDeposit,
            "recovery restores only the written-off principal plus the new deposit"
        );

        uint256 recapitalizerRecoveryGain = _assertLateCohortOutcome(cohorts);
        if (cohorts.backingAfterWriteOff == 0) {
            assertGe(
                recapitalizerRecoveryGain,
                cohorts.finalizedWriteOff - cohorts.finalizedWriteOff / 1_000_000,
                "a valid post-wipeout deposit captures nearly all of the recovered principal"
            );
        }
    }

    function test_LateAttestation_AdoptsWrittenOffAlphaForCurrentCohort() public {
        LateCohorts memory cohorts = _openIncumbentCohort(30 * ALPHA);

        bytes32 successor = keccak256(abi.encode("attested-successor"));
        uint256 swept = _sweepDuringCrash(NETUID1, hotkey1);
        _runOutRecoveryWindow(TOKEN1);
        cohorts.backingAfterWriteOff = lens.totalStake(TOKEN1);
        cohorts.finalizedWriteOff = cohorts.backingBefore - cohorts.backingAfterWriteOff;
        assertEq(cohorts.finalizedWriteOff, FIRST_SLOT, "the written-off principal is the first slot");
        _strangerReturns(NETUID1, successor, swept);

        _reattestValidators(NETUID1);
        cohorts.recapitalizationDeposit = OTHER_TWO_SLOTS;
        _addRecapitalizer(cohorts);
        assertEq(
            cohorts.recapitalizerShares, 29_999_999_999_499_849_985, "19.998e9 * (3e19 + 1e9) / (19.998e9 + 1), floored"
        );

        _setValidators(
            NETUID1, _hotkeys(successor, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
        vault.rebalance(NETUID1);

        assertEq(lens.totalStake(TOKEN1), 49_998_000_000, "settlement adopts the funded successor exactly once");
        (uint256 incumbentValueAfter,) = lens.previewUnwrap(TOKEN1, cohorts.incumbentShares);
        (uint256 recapitalizerValueAfter,) = lens.previewUnwrap(TOKEN1, cohorts.recapitalizerShares);
        assertEq(incumbentValueAfter, 24_999_000_000, "the incumbent recovers 5.001 alpha of the write-off");
        assertEq(recapitalizerValueAfter, 24_998_999_999, "and the recapitalizer gains the same 5.001 alpha");
        _assertLateCohortOutcome(cohorts);
    }

    function _openIncumbentCohort(uint256 deposit) internal returns (LateCohorts memory cohorts) {
        cohorts.incumbentShares = _depositAndWrap(alice, NETUID1, deposit);
        cohorts.backingBefore = lens.totalStake(TOKEN1);
        assertEq(cohorts.backingBefore, deposit, "the incumbent's deposit is the whole backing");
        (cohorts.incumbentValueBefore,) = lens.previewUnwrap(TOKEN1, cohorts.incumbentShares);
    }

    function _addRecapitalizer(LateCohorts memory cohorts) internal {
        cohorts.recapitalizerShares = _depositAndWrap(bob, NETUID1, cohorts.recapitalizationDeposit);
        (cohorts.recapitalizerValueBefore,) = lens.previewUnwrap(TOKEN1, cohorts.recapitalizerShares);
        (cohorts.incumbentValueAtRecovery,) = lens.previewUnwrap(TOKEN1, cohorts.incumbentShares);
    }

    function _assertLateCohortOutcome(LateCohorts memory cohorts) internal view returns (uint256 recapitalizerGain) {
        (uint256 incumbentValueAfter,) = lens.previewUnwrap(TOKEN1, cohorts.incumbentShares);
        assertLe(
            cohorts.incumbentValueBefore,
            incumbentValueAfter + cohorts.finalizedWriteOff,
            "incumbents cannot lose more than the finalized write-off"
        );

        (uint256 recapitalizerValueAfter,) = lens.previewUnwrap(TOKEN1, cohorts.recapitalizerShares);
        assertLe(
            recapitalizerValueAfter,
            cohorts.recapitalizationDeposit + cohorts.finalizedWriteOff,
            "the recapitalizer cannot capture more than the balance that returned"
        );
        recapitalizerGain = recapitalizerValueAfter - cohorts.recapitalizerValueBefore;
        uint256 incumbentGain = incumbentValueAfter - cohorts.incumbentValueAtRecovery;
        // Each value read floors once, so each cohort's gain is within one RAO of its exact share.
        assertApproxEqAbs(
            recapitalizerGain * cohorts.incumbentShares,
            incumbentGain * cohorts.recapitalizerShares,
            cohorts.incumbentShares + cohorts.recapitalizerShares,
            "both cohorts gain the same per share"
        );
    }

    function _squattedVacatedHotkeyBesideItsSuccessor() private {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey4), _weights(3334, 3333, 3333));
        _simulateFollowedSwap(NETUID1, hotkey4, hotkey5);
        _simulateSquatter(hotkey4);
    }

    function test_SquattedVacatedHotkey_ReceivesTheEmptySlotsAllocation() public {
        _squattedVacatedHotkeyBesideItsSuccessor();

        vault.rebalance(NETUID1);

        assertEq(
            _getVaultStake(hotkey4, NETUID1),
            OTHER_SLOT,
            "the attested hotkey receives its 9.999 alpha, whoever holds it"
        );
        assertEq(_getVaultStake(hotkey5, NETUID1), 0, "and the validator's successor nothing");
    }

    function test_PublishingTheSuccessor_MovesTheAllocationOffTheSquattedHotkey() public {
        _squattedVacatedHotkeyBesideItsSuccessor();
        vault.rebalance(NETUID1);

        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey5), _weights(3334, 3333, 3333));
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "the dropped hotkey is consolidated away");
        assertEq(_getVaultStake(hotkey5, NETUID1), OTHER_SLOT, "onto the published successor");
    }

    function _squattedHotkeyBehindAFollowedSwap() private returns (uint256 shares) {
        shares = _positionFollowingASwap(hotkey5);
        _simulateSquatter(hotkey1);
    }

    function test_SquattedHotkeyBehindAFollowedSwap_EmptiedSlotStaysOnTheSuccessor() public {
        _squattedHotkeyBehindAFollowedSwap();
        _drainTheFirstSlot(alice, NETUID1);

        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "the claimed hotkey receives nothing");
        assertEq(
            _getVaultStake(hotkey5, NETUID1),
            REFILLED_FIRST_SLOT,
            "3334 bps of the remaining 19.998 alpha stay with the successor"
        );
        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, hotkey5, "the slot keeps answering under the successor");
    }

    function testFuzz_SquattedHotkeyBehindAFollowedSwap_DepositsAfterAFullExitLandOnTheSuccessor(uint256 amount)
        public
    {
        amount = bound(amount, ALPHA, 1_000 * ALPHA);
        uint256 shares = _squattedHotkeyBehindAFollowedSwap();
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
        assertEq(lens.totalStake(TOKEN1), 0, "the full exit left nothing behind");

        _depositAndWrap(bob, NETUID1, amount);

        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "the claimed hotkey receives nothing");
        assertEq(
            _getVaultStake(hotkey5, NETUID1), amount * 3334 / 10_000, "3334 bps of the deposit land on the successor"
        );
        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, hotkey5, "the slot keeps answering under the successor");
    }

    function test_ValidatorSwappingBackToItsAttestedHotkey_EmptiedSlotReturnsToIt() public {
        _positionWithADrainedSwap(hotkey5);
        _simulatePerSubnetSwap(NETUID1, hotkey5, hotkey1);

        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey5, NETUID1), 0, "the hotkey the validator left receives nothing");
        assertEq(
            _getVaultStake(hotkey1, NETUID1),
            REFILLED_FIRST_SLOT,
            "3334 bps of the remaining 19.998 alpha return to the attested hotkey"
        );
        assertEq(
            vault.recordedSlots(TOKEN1)[0].stakedUnder, hotkey1, "the slot answers under its attested hotkey again"
        );
    }

    function test_SquattedHotkeyBehindAFollowedSwap_AllRailsKeepWorking() public {
        uint256 aliceShares = _squattedHotkeyBehindAFollowedSwap();
        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares, _toSubstrate(alice), 0);

        _assertEveryRailWorks(hotkey1, 17_500_000_000);

        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "nothing is ever staked toward the claimed hotkey");
        assertEq(_getVaultStake(hotkey5, NETUID1), 5_834_500_000, "3334 bps of 17.5 alpha rest on the successor");
    }

    function test_SquattedHotkeyBehindAFollowedSwap_PartialExitsPayAndRealignOntoTheSuccessor() public {
        _squattedHotkeyBehindAFollowedSwap();
        _drainTheFirstSlot(alice, NETUID1);
        uint256 remaining = vault.balanceOf(alice, TOKEN1);

        (uint256 quotedAlpha,) = lens.previewUnwrap(TOKEN1, remaining / 4);
        assertEq(quotedAlpha, 4_999_500_000, "a quarter of the remaining 19.998 alpha");
        vm.prank(alice);
        vault.unwrap(TOKEN1, remaining / 4, _toSubstrate(alice), 0);
        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), 4_999_500_000, "the partial alpha exit paid the quote");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "the claimed hotkey receives nothing");
        assertEq(
            _getVaultStake(hotkey5, NETUID1), 4_999_999_950, "the exit realigned the slot's weight onto the successor"
        );
        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, hotkey5, "the slot keeps answering under the successor");

        uint256 taoBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, remaining / 4, 0);
        assertEq(
            alice.balance - taoBefore, 249_975_000e9, "the TAO exit drained hotkey2's 4.9995 alpha at 0.05 TAO/alpha"
        );
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "and still nothing sits on the claimed hotkey");
        assertTrue(lens.isBackingIntact(TOKEN1), "record sound throughout");
    }

    function _followedHotkeySwappedOnWithTheSlotEmpty() private {
        _positionWithADrainedSwap(hotkey5);
        _simulateFollowedSwap(NETUID1, hotkey5, hotkey4);
    }

    function test_ValidatorSwappingOnFromTheFollowedHotkey_EmptiedSlotFollowsToTheNewHotkey() public {
        _followedHotkeySwappedOnWithTheSlotEmpty();

        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "nothing returns to the unowned attested hotkey");
        assertEq(_getVaultStake(hotkey5, NETUID1), 0, "nothing lands on the hotkey the validator left");
        assertEq(
            _getVaultStake(hotkey4, NETUID1),
            REFILLED_FIRST_SLOT,
            "3334 bps of the remaining 19.998 alpha follow to the validator's new hotkey"
        );
        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, hotkey4, "the slot answers under the new hotkey");
    }

    function test_RevertWhen_FollowedHotkeySwappedOnAndNoHotkeyIsOwned() public {
        _followedHotkeySwappedOnWithTheSlotEmpty();
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey4, true);

        _simulateAlphaDeposit(bob, NETUID1, 6 * ALPHA);
        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey1));
        _wrapHotkey(bob, NETUID1, hotkey2);

        uint256 quarter = vault.balanceOf(alice, TOKEN1) / 4;
        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey1));
        vm.prank(alice);
        vault.unwrap(TOKEN1, quarter, _toSubstrate(alice), 0);
    }

    function test_OwnerlessFundedHotkey_RefusesAlignmentUntilReplaced() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);

        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey1));
        vault.rebalance(NETUID1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey1));
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 0);

        _setValidators(NETUID1, _hotkeys(hotkey2, hotkey3), _weights(5000, 5000));
        vault.rebalance(NETUID1);

        assertEq(
            _hotkeyOwner(hotkey1),
            _cloneOwnerColdkey(NETUID1),
            "the clone's owner contract claimed the ownerless hotkey to roll it"
        );
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "and rolled its alpha onto the set");
        assertEq(_getVaultStake(hotkey2, NETUID1), 15 * ALPHA, "half of 30 alpha on the first remaining validator");
        assertEq(_getVaultStake(hotkey3, NETUID1), 15 * ALPHA, "half of 30 alpha on the second");
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "losing nothing");
    }

    /// @dev A coldkey swap moves every hotkey of the validator to the new coldkey.
    function test_ValidatorColdkeySwap_ChangesNothingForTheVault() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        MockStaking(STAKING_PRECOMPILE).setHotkeyOwner(hotkey1, keccak256("validator-successor-coldkey"));

        vault.rebalance(NETUID1);
        assertEq(_getVaultStake(hotkey1, NETUID1), FIRST_SLOT, "the stake stays where it is, whoever owns the hotkey");
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "and the backing is whole");

        assertEq(_depositAndWrap(bob, NETUID1, 6 * ALPHA), 6e18, "a deposit mints 1e9 shares per RAO");
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 0);

        assertEq(registry.nonces(NETUID1), SETUP_NONCE, "no new attestation was needed");
        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), 7_500_000_000, "a quarter of alice's 30 alpha exits");
        assertEq(lens.totalStake(TOKEN1), 28_500_000_000, "36 alpha less the 7.5 alpha exit");
        assertTrue(lens.isBackingIntact(TOKEN1), "and the record stays sound");
    }

    function _parkFirstSlotReturnedShortBy(uint256 missing) private {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _sweepDuringCrash(NETUID1, hotkey1);

        vault.syncBacking(TOKEN1);
        _strangerReturns(NETUID1, hotkey4, FIRST_SLOT - missing);
        vault.recoverStray(TOKEN1, hotkey4);
        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "partial finds are secured too");
    }

    function test_RecoverStray_CompletesWhenShortByTheSlack() public {
        _parkFirstSlotReturnedShortBy(BACKING_SLACK_RAO);

        vault.syncBacking(TOKEN1);

        assertTrue(vault.awaitingAttestation(TOKEN1), "1,000 RAO short is accounting dust");
        assertEq(_parkedStake(NETUID1), 29_999_999_000, "30 alpha less 1,000 RAO is parked");
        assertEq(lens.totalStake(TOKEN1), 29_999_999_000, "and is what the record expects");
    }

    function test_RevertWhen_FinishingARecoveryOneRaoPastTheSlack() public {
        _parkFirstSlotReturnedShortBy(BACKING_SLACK_RAO + 1);

        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);
    }

    function testFuzz_RecoverStray_CompletesWithinTheSlack(uint256 missing) public {
        missing = bound(missing, 0, BACKING_SLACK_RAO);
        _parkFirstSlotReturnedShortBy(missing);

        vault.syncBacking(TOKEN1);

        assertTrue(vault.awaitingAttestation(TOKEN1), "pooled coverage within 1,000 RAO completes recovery");
        assertEq(_parkedStake(NETUID1), 30 * ALPHA - missing, "with everything returned on the parking hotkey");
    }

    function testFuzz_RecoverStray_PreservesTheUnrecoveredDeficit(uint256 missing) public {
        missing = bound(missing, BACKING_SLACK_RAO + 1, 2 * BACKING_SLACK_RAO);
        _parkFirstSlotReturnedShortBy(missing);

        assertFalse(vault.awaitingAttestation(TOKEN1), "completion requires pooled coverage");
        assertEq(lens.missingStake(TOKEN1), missing, "the deficit past the slack stays on file");
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, 30 * ALPHA, "against the whole obligation");
    }

    function test_SquattedFundedHotkey_StaysFunded() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulateSquatter(hotkey1);

        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey1, NETUID1), FIRST_SLOT, "the stake stays where it is, whoever holds the hotkey");
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "and the backing is whole");
    }
}

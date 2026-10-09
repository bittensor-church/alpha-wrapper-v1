// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { AlphaVaultLens } from "src/AlphaVaultLens.sol";
import { BasicValidatorRegistry } from "src/BasicValidatorRegistry.sol";
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
    SubnetInDissolutionBlackoutPeriod,
    WithdrawTooSmall
} from "src/VaultErrors.sol";
import { IAlphaVaultAbi } from "src/interfaces/IAlphaVaultAbi.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

/// Tests how the vault handles alpha that goes missing: declaring the loss, parking what it can find
/// on its own hotkey, holding the parked position until the attesters publish again, and writing off
/// what never comes back.
contract BackingRecoveryTest is AlphaVaultTestBase {
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

    /// @dev 30 alpha at 3334 / 3333 / 3333 bps: hotkey1 holds 10.002 alpha, hotkey2 and hotkey3 9.999 each.
    uint256 private constant FIRST_SLOT = 10_002_000_000;
    uint256 private constant OTHER_TWO_SLOTS = 19_998_000_000;
    /// @dev 0.04 alpha: the 2e6 RAO minimum stake at 0.05 TAO/alpha.
    uint256 private constant FLOOR = 4e7;
    /// @dev The registry nonce setUp's attestation leaves on NETUID1.
    uint256 private constant SETUP_NONCE = 1;

    /// @dev Swaps hotkey1's slot away along an unfollowed trail and declares the loss.
    function _declaredShortfall() private returns (uint256 shares) {
        shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.syncBacking(TOKEN1);
    }

    // --- Declaring and clearing a shortfall ---------------------------------------------------

    function test_SyncBacking_DeclaresTheShortfall() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _buildSwapTrail(NETUID1, hotkey1, 2);

        assertEq(
            lens.writeOffDeadline(TOKEN1),
            VaultReads.UNDECLARED_SHORTFALL,
            "short, but nothing is on file before the sync"
        );
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingShortfallDeclared(TOKEN1, 30 * ALPHA, OTHER_TWO_SLOTS);
        vm.prank(bob);
        vault.syncBacking(TOKEN1);

        assertEq(lens.writeOffDeadline(TOKEN1), block.timestamp + RECOVERY_WINDOW, "the window runs from here");
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, 30 * ALPHA, "the pool preserves the whole obligation");
        assertEq(_parkedStake(NETUID1), OTHER_TWO_SLOTS, "located backing is secured before the clock starts");
        assertFalse(lens.isBackingIntact(TOKEN1), "and the token reports itself short");
    }

    function test_SyncBacking_CannotPushTheDeadlineOut() public {
        _declaredShortfall();

        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);
    }

    function test_SyncBacking_KeepsAFollowedSwapInTheRecord() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);

        vault.syncBacking(TOKEN1);

        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey4, "the record kept the key the swap reached");
        assertEq(lens.writeOffDeadline(TOKEN1), 0, "which is not a loss and needs no clock");
        _simulateFollowedSwap(NETUID1, hotkey4, hotkey5);
        assertTrue(lens.isBackingIntact(TOKEN1), "so the next hop resolves from there");
        assertEq(_getVaultStake(hotkey5, NETUID1), FIRST_SLOT, "where the alpha now is");
        vault.rebalance(NETUID1);
    }

    function test_RevertWhen_SyncingATokenThatAccountsForItself() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);

        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);
    }

    function test_RevertWhen_SyncingATokenWithNoPosition() public {
        vm.expectRevert(NothingToUnwrap.selector);
        vault.syncBacking(TOKEN1);
    }

    function test_RevertWhen_SyncingARetiredTokenId() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _reregisterSubnet(NETUID1);

        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);
    }

    function test_RevertWhen_SyncingWhileTheSubnetIsDissolving() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        _setDissolving(NETUID1, true);

        vm.expectRevert(SubnetInDissolutionBlackoutPeriod.selector);
        vault.syncBacking(TOKEN1);
    }

    function test_RevertWhen_WrappingWhileAShortfallIsOnFile() public {
        _declaredShortfall();
        _simulateAlphaDepositHotkey(bob, NETUID1, 6 * ALPHA, hotkey2);

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
        bytes32 tip = _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.syncBacking(TOKEN1);

        _simulateOffVaultSwap(NETUID1, tip, hotkey1);

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
        _reattestCurrentSet(NETUID1);
        vault.rebalance(NETUID1);
    }

    /// @dev A cleared loss must not lend its expired clock to a later shortfall.
    function test_ClearedShortfall_StartsAFreshClockOnTheNextLoss() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 tip = _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.syncBacking(TOKEN1);
        _simulateOffVaultSwap(NETUID1, tip, hotkey1);
        vault.syncBacking(TOKEN1);

        _reattestCurrentSet(NETUID1);
        vault.rebalance(NETUID1);
        vm.warp(block.timestamp + 2 * RECOVERY_WINDOW);
        _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.syncBacking(TOKEN1);

        assertEq(lens.writeOffDeadline(TOKEN1), block.timestamp + RECOVERY_WINDOW, "the new loss gets a full window");
        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);
    }

    // --- Recovery parks the position ------------------------------------------------------------

    function test_RecoverStray_ParksTheWholePosition() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        vault.syncBacking(TOKEN1);
        assertFalse(lens.isBackingIntact(TOKEN1), "the loss is visible first");
        bytes32 parking = vault.parkingHotkey();

        vm.expectEmit(true, true, false, true, address(vault));
        emit BackingRecovered(TOKEN1, parking, FIRST_SLOT);
        vm.prank(bob);
        vault.recoverStray(TOKEN1, hotkey4);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingParked(TOKEN1, 30 * ALPHA, SETUP_NONCE);
        vault.syncBacking(TOKEN1);

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots.length, 1, "the record collapses to one slot");
        assertEq(slots[0].active, parking, "on the parking hotkey");
        assertEq(slots[0].logical, parking, "named by the parking hotkey");
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
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        vm.expectPartialRevert(BackingShortfall.selector);
        vm.prank(bob);
        vault.recoverStray(TOKEN1, hotkey4);

        vault.syncBacking(TOKEN1);
        vault.recoverStray(TOKEN1, hotkey4);
        vault.syncBacking(TOKEN1);
        assertTrue(vault.awaitingAttestation(TOKEN1));
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA);
    }

    function test_RecoverStray_ResolvesATwoHopTrail() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 tip = _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.syncBacking(TOKEN1);

        vm.prank(bob);
        vault.recoverStray(TOKEN1, tip);
        vault.syncBacking(TOKEN1);

        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "the watcher-supplied source accounts for the loss");
        assertEq(_getVaultStake(tip, NETUID1), 0, "and the trail's tip is empty");
    }

    function test_RecoverStray_CoversTwoLossesInSeparateCalls() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        _simulateOffVaultSwap(NETUID1, hotkey2, hotkey5);
        vault.syncBacking(TOKEN1);

        vm.prank(bob);
        vault.recoverStray(TOKEN1, hotkey4);
        vm.prank(bob);
        vault.recoverStray(TOKEN1, hotkey5);
        vault.syncBacking(TOKEN1);

        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "both lumps are home");
        assertEq(_parkedStake(NETUID1), 30 * ALPHA, "on the parking hotkey");
    }

    /// @dev Two attested slots swapped onto one key: nothing is missing, so no source is needed.
    function test_SyncBacking_ParksMergedSlotsWithoutASource() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        _simulateOffVaultSwap(NETUID1, hotkey2, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey1, NETUID1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey2, NETUID1, hotkey4);
        vault.syncBacking(TOKEN1);

        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "the merged balance is counted once");
        assertEq(_parkedStake(NETUID1), 30 * ALPHA, "on the parking hotkey");
    }

    function test_RecoverStray_BringsAnEmissionGrownLumpHome() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, _subnetColdkey(NETUID1), NETUID1, FIRST_SLOT + 2 * ALPHA);
        vault.syncBacking(TOKEN1);

        vm.prank(bob);
        vault.recoverStray(TOKEN1, hotkey4);
        vault.syncBacking(TOKEN1);

        assertEq(lens.totalStake(TOKEN1), 32 * ALPHA, "the emissions came home with the lump");
    }

    /// @dev The chain refuses to move stake from a hotkey nobody owns; the vault claims it and moves on.
    function test_RecoverStray_ClaimsAnOwnerlessSourceForTheVault() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey4, true);
        vault.syncBacking(TOKEN1);

        vm.prank(bob);
        vault.recoverStray(TOKEN1, hotkey4);
        vault.syncBacking(TOKEN1);

        (bool exists, bytes32 owner) = MockStaking(STAKING_PRECOMPILE).getHotkeyOwner(hotkey4);
        assertTrue(exists, "the source has an owner again");
        assertEq(owner, _toSubstrate(address(vault)), "the vault, not the caller");
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "and the alpha is parked");
    }

    /// @dev Synthetic split backing exercises the coverage guard; ordinary swaps move whole entries.
    function test_RecoverStray_ParksPartialCoverageWithoutChangingTheDeadline() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, coldkey, NETUID1, FIRST_SLOT / 3);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey5, coldkey, NETUID1, FIRST_SLOT);
        _simulateSameOwner(hotkey1, hotkey4);
        _simulateSameOwner(hotkey1, hotkey5);
        vault.syncBacking(TOKEN1);
        uint256 deadline = lens.writeOffDeadline(TOKEN1);

        vm.prank(bob);
        vault.recoverStray(TOKEN1, hotkey4);
        assertFalse(lens.isBackingIntact(TOKEN1), "the loss still stands");
        assertEq(_getStakeForColdkey(hotkey4, coldkey, NETUID1), 0, "the partial recovery is secured");
        assertEq(lens.missingStake(TOKEN1), 6_668_000_000, "only the aggregate remainder is missing");
        assertEq(lens.writeOffDeadline(TOKEN1), deadline, "and the deadline did not move");

        vm.prank(bob);
        vault.recoverStray(TOKEN1, hotkey5);
        vault.syncBacking(TOKEN1);
        assertTrue(lens.isBackingIntact(TOKEN1), "the key covering the loss parks it");
        assertEq(lens.writeOffDeadline(TOKEN1), 0, "and the window ends");
    }

    function test_RevertWhen_RecoveringFromAKeyHoldingNothing() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);

        vm.expectRevert(NothingToRecover.selector);
        vault.recoverStray(TOKEN1, hotkey5);
    }

    function test_RevertWhen_RecoveringFromTheSlotsOwnKey() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);

        vm.expectRevert(NothingToRecover.selector);
        vault.recoverStray(TOKEN1, hotkey1);
    }

    function test_RevertWhen_RecoveringFromAKeyASlotResolvesTo() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);

        vm.expectRevert(NothingToRecover.selector);
        vm.prank(bob);
        vault.recoverStray(TOKEN1, hotkey4);
    }

    function test_RevertWhen_RecoveringOnATokenWithNoSlots() public {
        vault.createMailbox(NETUID1, keccak256("fixture-creation"));
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, _subnetColdkey(NETUID1), NETUID1, 5 * ALPHA);

        vm.expectRevert(NothingToRecover.selector);
        vault.recoverStray(TOKEN1, hotkey4);
    }

    function test_RevertWhen_RecoveringOnARetiredTokenId() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _reregisterSubnet(NETUID1);

        vm.expectRevert(NothingToRecover.selector);
        vault.recoverStray(TOKEN1, hotkey4);
    }

    // --- Strays with nothing missing join the live backing -------------------------------------

    function test_RecoverStray_AnnexesADonationToTheFirstSlot() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, _subnetColdkey(NETUID1), NETUID1, 3 * ALPHA);
        _simulateHotkeyOwnerPresent(hotkey4);

        vm.expectEmit(true, true, false, true, address(vault));
        emit BackingRecovered(TOKEN1, hotkey1, 3 * ALPHA);
        vault.recoverStray(TOKEN1, hotkey4);

        assertEq(lens.totalStake(TOKEN1), 33 * ALPHA, "the donation is new backing");
        assertFalse(vault.awaitingAttestation(TOKEN1), "and nothing parked");
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, FIRST_SLOT + 3 * ALPHA, "booked on the first slot");
    }

    /// @dev The slot's own pile carries a stray the chain would refuse to move on its own.
    function test_RecoverStray_CarriesADustStrayHomeWithTheSlotsOwnPile() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, _subnetColdkey(NETUID1), NETUID1, 1);
        _simulateHotkeyOwnerPresent(hotkey4);

        vm.expectEmit(true, true, false, true, address(vault));
        emit BackingRecovered(TOKEN1, hotkey1, 1);
        vault.recoverStray(TOKEN1, hotkey4);

        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA + 1, "the dust is home");
        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "and nothing stays behind");
    }

    /// @dev A slot the resolver follows through a swap is re-anchored to the key that holds its stake.
    function test_RecoverStray_AnnexReanchorsASlotFollowedThroughASwap() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey5, _subnetColdkey(NETUID1), NETUID1, 3 * ALPHA);
        _simulateHotkeyOwnerPresent(hotkey5);
        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey1, "the record still names the swapped key");

        vm.expectEmit(true, true, false, true, address(vault));
        emit BackingRecovered(TOKEN1, hotkey4, 3 * ALPHA);
        vault.recoverStray(TOKEN1, hotkey5);

        VaultReads.Slot memory slot = vault.recordedSlots(TOKEN1)[0];
        assertEq(slot.active, hotkey4, "the slot now points at the successor holding its stake");
        assertEq(slot.tracked, FIRST_SLOT + 3 * ALPHA, "and expects exactly what sits there");
        assertEq(_getVaultStake(hotkey5, NETUID1), 0, "the stray came home");
        assertEq(lens.totalStake(TOKEN1), 33 * ALPHA, "as new backing");
    }

    function test_RevertWhen_NeitherTheStrayNorTheSlotCanMoveTheirPile() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _plantVaultStakes(NETUID1, 1, 1, 1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, _subnetColdkey(NETUID1), NETUID1, 1);
        _simulateHotkeyOwnerPresent(hotkey4);

        vm.expectRevert(IAlphaVaultAbi.ConsolidationBelowFloor.selector);
        vault.recoverStray(TOKEN1, hotkey4);
    }

    // --- Life on the parking hotkey --------------------------------------------------------------

    function _parkedPosition() private returns (uint256 shares) {
        return _parkedPosition(30 * ALPHA);
    }

    function _parkedPosition(uint256 amount) private returns (uint256 shares) {
        shares = _depositAndWrap(alice, NETUID1, amount);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        vault.syncBacking(TOKEN1);
        vault.recoverStray(TOKEN1, hotkey4);
        vault.syncBacking(TOKEN1);
        assertTrue(vault.awaitingAttestation(TOKEN1), "the fixture needs a parked position");
    }

    function test_ParkedPosition_RefusesDepositsAndAlignmentUntilANewAttestation() public {
        _parkedPosition();

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
        uint256 shares = _parkedPosition();
        bytes32 parking = vault.parkingHotkey();

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 1);

        assertEq(_getStake(parking, alice, NETUID1), 7_500_000_000, "the exit is delivered on the parking hotkey");
        assertEq(_parkedStake(NETUID1), 22_500_000_000, "leaving the rest parked");
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, 22_500_000_000, "with the record following");
        assertTrue(vault.awaitingAttestation(TOKEN1), "and the position still waiting");
    }

    function test_ParkedPosition_PaysTaoExitsFromTheParkingHotkey() public {
        uint256 shares = _parkedPosition();

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 2, 0);

        assertEq(alice.balance, 0.75e18, "15 alpha sold at 0.05 TAO/alpha");
        assertEq(_parkedStake(NETUID1), 15 * ALPHA, "from the parked balance");
        assertTrue(vault.awaitingAttestation(TOKEN1), "which stays parked");
    }

    function test_RevertWhen_AParkedTaoExitExcludesItsOnlySlot() public {
        uint256 shares = _parkedPosition();

        vm.prank(alice);
        vm.expectRevert(WithdrawTooSmall.selector);
        vault.unwrapForTao(TOKEN1, shares / 2, 0, 1 << 0);
    }

    function test_RevertWhen_AParkedTaoExitExcludesASlotPastTheParkingSlot() public {
        uint256 shares = _parkedPosition();

        vm.prank(alice);
        vm.expectRevert(SlotMaskOutOfRange.selector);
        vault.unwrapForTao(TOKEN1, shares / 2, 0, 1 << 1);
    }

    function test_ParkedPosition_FullTaoExitReleasesIt() public {
        uint256 shares = _parkedPosition();

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(vault.totalSupply(TOKEN1), 0, "nothing outstanding");
        assertFalse(vault.awaitingAttestation(TOKEN1), "with no shares left there is nothing to hold");
        _depositAndWrap(bob, NETUID1, 5 * ALPHA);
        assertEq(lens.totalStake(TOKEN1), 5 * ALPHA, "and the next depositor starts a fresh position");
    }

    /// @dev Stake is keyed by hotkey, coldkey and netuid, so one parking hotkey serves every subnet.
    function test_ParkedPosition_LeavesOtherSubnetsUntouched() public {
        _parkedPosition();

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
        uint256 shares = _parkedPosition();
        _donateToClone(vault.subnetClone(TOKEN1), 4 * TAO);

        vm.prank(alice);
        vault.safeTransferFrom(alice, bob, TOKEN1, shares / 2, "");
        assertEq(vault.balanceOf(bob, TOKEN1), shares / 2, "shares move while parked");

        assertEq(
            _claimQuotedAmount(alice, TOKEN1),
            3_999_999_999_000_000_000,
            "4 TAO over 3e19 shares, floored on the index and to whole RAO"
        );
    }

    function test_ParkedPosition_FullExitRetiresEveryShare() public {
        uint256 shares = _parkedPosition();

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        assertEq(vault.totalSupply(TOKEN1), 0, "nothing outstanding");
        assertEq(_parkedStake(NETUID1), 0, "and nothing left parked");
        assertEq(_getStake(vault.parkingHotkey(), alice, NETUID1), 30 * ALPHA, "the holder took the position");
        assertFalse(vault.awaitingAttestation(TOKEN1), "with no shares left there is nothing to hold");

        _depositAndWrap(bob, NETUID1, 5 * ALPHA);
        assertEq(lens.totalStake(TOKEN1), 5 * ALPHA, "and the next depositor starts a fresh position");
    }

    function test_SubFloorBacking_DeclaresWritesOffAndRemainsRecoverable() public {
        uint256 dust = FLOOR / 2;
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, dust);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey3, coldkey, NETUID1, 0);
        vault.syncBacking(TOKEN1);
        assertEq(lens.writeOffDeadline(TOKEN1), block.timestamp + RECOVERY_WINDOW);
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, 30 * ALPHA);
        assertEq(_getVaultStake(hotkey1, NETUID1), dust);
        vm.warp(lens.writeOffDeadline(TOKEN1));
        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), 0);
        assertEq(_getVaultStake(hotkey1, NETUID1), dust);
        assertTrue(vault.awaitingAttestation(TOKEN1));
        // A later larger find can carry the abandoned dust home for the existing holders.
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey5, coldkey, NETUID1, ALPHA);
        _simulateHotkeyOwnerPresent(hotkey5);
        vault.recoverStray(TOKEN1, hotkey5);
        vault.recoverStray(TOKEN1, hotkey1);
        assertEq(lens.totalStake(TOKEN1), ALPHA + dust);
        assertEq(_getVaultStake(hotkey1, NETUID1), 0);
    }

    /// @dev The chain force-sells a whole nominator position below its minimum and credits the TAO to the
    ///      coldkey. 0.3 alpha is below the 0.4 alpha minimum at 0.05 TAO/alpha and sells for 0.015 TAO.
    function test_SweptParkedPosition_IsWrittenOffAndItsSaleStaysClaimable() public {
        uint256 parked = 3 * ALPHA / 10;
        uint256 shares = _parkedPosition(parked);
        address clone = vault.subnetClone(TOKEN1);
        MockStaking(STAKING_PRECOMPILE).setStake(vault.parkingHotkey(), _toSubstrate(clone), NETUID1, 0);
        _donateToClone(clone, 0.015e18);

        assertFalse(lens.isBackingIntact(TOKEN1), "the parked position is short");
        vm.prank(alice);
        vm.expectPartialRevert(BackingShortfall.selector);
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
        _parkedPosition();

        _reattestCurrentSet(NETUID1);
        assertFalse(vault.awaitingAttestation(TOKEN1), "the newer nonce lifts the hold");
        vault.rebalance(NETUID1);

        assertEq(_parkedStake(NETUID1), 0, "the parking hotkey is empty again");
        assertEq(vault.recordedSlots(TOKEN1).length, 3, "the record follows the attested set");
        assertEq(_getVaultStake(hotkey1, NETUID1), FIRST_SLOT, "spread by weight");
        assertEq(_getVaultStake(hotkey2, NETUID1), 9_999_000_000, "spread by weight");
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "with nothing lost in the release");
        (, uint256 parkedAtNonce) = vault.recovery(TOKEN1);
        assertEq(parkedAtNonce, 0, "and the position is ordinary again");
    }

    function test_SameHotkeyResubmission_ReleasesTheParkedPosition() public {
        BasicValidatorRegistry basicRegistry = new BasicValidatorRegistry(address(this));
        basicRegistry.setValidator(NETUID1, hotkey1);
        (vault, lens) = _deployVaultAndLens(address(basicRegistry));
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        vault.syncBacking(TOKEN1);
        vault.recoverStray(TOKEN1, hotkey4);
        vault.syncBacking(TOKEN1);
        assertTrue(vault.awaitingAttestation(TOKEN1), "the fixture needs a parked position");

        basicRegistry.setValidator(NETUID1, hotkey1);
        assertFalse(vault.awaitingAttestation(TOKEN1), "resubmitting the same hotkey advances the nonce");
        vault.rebalance(NETUID1);

        assertEq(_parkedStake(NETUID1), 0, "the parking hotkey is empty again");
        assertEq(_getVaultStake(hotkey1, NETUID1), 30 * ALPHA, "and the resubmitted validator holds it all");
    }

    function test_Wrap_ReleasesAParkedPositionAfterANewAttestation() public {
        _parkedPosition();
        _reattestCurrentSet(NETUID1);

        _simulateAlphaDepositHotkey(bob, NETUID1, 6 * ALPHA, hotkey2);
        _wrapHotkey(bob, NETUID1, hotkey2);

        assertEq(vault.balanceOf(bob, TOKEN1), 6e18, "6 alpha against 30 alpha on 3e19 shares");
        assertEq(_parkedStake(NETUID1), 0, "and the parked alpha moved onto the set with it");
        assertEq(lens.totalStake(TOKEN1), 36 * ALPHA, "backing whole across the release");
    }

    function test_ReplacingTheLostName_RoutesParkedAlphaToTheSuccessor() public {
        _parkedPosition();

        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "nothing goes back to the lost name");
        assertEq(_getVaultStake(hotkey4, NETUID1), FIRST_SLOT, "its weight went to the successor");
        assertEq(_parkedStake(NETUID1), 0, "and the parking hotkey is empty");
    }

    function test_LateFoundAlpha_JoinsTheParkedPosition() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        _runOutRecoveryWindow(TOKEN1);
        assertTrue(vault.awaitingAttestation(TOKEN1), "the write-off parks what is left");
        assertEq(_parkedStake(NETUID1), OTHER_TWO_SLOTS);

        vault.recoverStray(TOKEN1, hotkey4);

        assertEq(_parkedStake(NETUID1), 30 * ALPHA, "the find joins the parked alpha");
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "and the backing is whole again");
    }

    // --- Subnet dissolution --------------------------------------------------------------------

    function _dissolveWithPot(uint256 pot) private {
        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(TOKEN1, pot);
        _simulateDissolutionCompleted(NETUID1);
    }

    function test_DissolvedSubnet_PaysAParkedPositionInTao() public {
        uint256 shares = _parkedPosition();
        _dissolveWithPot(1.5e18);

        vm.expectEmit(true, true, false, true, address(vault));
        emit DissolvedSubnetUnwrapped(alice, TOKEN1, shares / 2, 0.75e18);
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

    // --- Writing a loss off ----------------------------------------------------------------------

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
        bytes32[] memory recordedHotkeys = _hotkeys(hotkey1, hotkey2, hotkey3);
        for (uint256 i; i < recordedHotkeys.length; ++i) {
            _simulateOffVaultSwap(NETUID1, recordedHotkeys[i], keccak256(abi.encode("gone", i)));
        }
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
    }

    function test_RecoveryWindow_SetAtDeploymentDrivesTheDeadline() public {
        (AlphaVault hourVault, AlphaVaultLens hourLens) = _deployVaultAndLens(address(registry), 1 hours);
        uint256 tokenId = hourVault.currentTokenId(NETUID1);
        vm.prank(alice);
        (address mailbox,) = hourVault.createMailbox(NETUID1, keccak256("fixture-creation"));
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _toSubstrate(mailbox), NETUID1, 10 * ALPHA);
        vm.prank(alice);
        hourVault.wrap(NETUID1, hotkey1, 0);

        bytes32 coldkey = _toSubstrate(hourVault.subnetClone(tokenId));
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, coldkey, NETUID1, 3_334_000_000);
        hourVault.syncBacking(tokenId);

        assertEq(
            hourLens.writeOffDeadline(tokenId), block.timestamp + 1 hours, "the deadline runs on the deployed window"
        );
        vm.warp(block.timestamp + 1 hours);
        hourVault.syncBacking(tokenId);
        assertTrue(hourVault.awaitingAttestation(tokenId), "and the write-off falls due on it too");
    }

    // --- Who a late recovery belongs to --------------------------------------------------------

    function test_LateFoundAlpha_IsAWindfallForTheCurrentCohort() public {
        uint256 aliceShares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        _runOutRecoveryWindow(TOKEN1);
        _reattestCurrentSet(NETUID1);
        vault.rebalance(NETUID1);

        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares, _toSubstrate(alice), 0);
        uint256 bobShares = _depositAndWrap(bob, NETUID1, 10 * ALPHA);

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
        uint256 hidden;
        for (uint256 i; i < hiddenSlotCount; ++i) {
            hidden += _getVaultStake(recordedHotkeys[i], NETUID1);
            _simulateOffVaultSwap(NETUID1, recordedHotkeys[i], keccak256(abi.encode("stray", i)));
        }

        _runOutRecoveryWindow(TOKEN1);
        cohorts.backingAfterWriteOff = lens.totalStake(TOKEN1);
        cohorts.finalizedWriteOff = cohorts.backingBefore - cohorts.backingAfterWriteOff;
        assertEq(cohorts.finalizedWriteOff, hidden, "the finalized deficit is exactly the hidden principal");

        _reattestCurrentSet(NETUID1);
        cohorts.recapitalizationDeposit = cohorts.backingAfterWriteOff == 0
            ? bound(recapitalizationSeed, FLOOR, ALPHA)
            : bound(recapitalizationSeed, cohorts.backingAfterWriteOff / 4, cohorts.backingAfterWriteOff * 4);
        _addRecapitalizer(cohorts);
        for (uint256 i; i < hiddenSlotCount; ++i) {
            vm.prank(bob);
            vault.recoverStray(TOKEN1, keccak256(abi.encode("stray", i)));
        }

        assertEq(
            lens.totalStake(TOKEN1),
            cohorts.backingBefore + cohorts.recapitalizationDeposit,
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
        _simulateOffVaultSwap(NETUID1, hotkey1, successor);
        _runOutRecoveryWindow(TOKEN1);
        cohorts.backingAfterWriteOff = lens.totalStake(TOKEN1);
        cohorts.finalizedWriteOff = cohorts.backingBefore - cohorts.backingAfterWriteOff;
        assertEq(cohorts.finalizedWriteOff, FIRST_SLOT, "the successor holds exactly the written-off principal");

        _reattestCurrentSet(NETUID1);
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

    // --- Names that answer to the wrong coldkey --------------------------------------------------

    function test_SquattedVacatedName_SendsAllocationToTheSuccessorInstead() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey4), _weights(3334, 3333, 3333));
        _simulateFollowedSwap(NETUID1, hotkey4, hotkey5);
        _simulateSquatter(hotkey4);

        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "nothing goes to the squatted name");
        assertEq(_getVaultStake(hotkey5, NETUID1), 9_999_000_000, "its weight goes to the validator's successor");
    }

    function test_SquattedVacatedNameWithNoSuccessor_IsRetired() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey4), _weights(3334, 3333, 3333));
        _simulateSquatter(hotkey4);

        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey4));
        vault.rebalance(NETUID1);
    }

    function test_OwnerlessFundedKey_RefusesAlignmentUntilReplaced() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);

        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey1));
        vault.rebalance(NETUID1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey1));
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 0);

        _setValidators(NETUID1, _hotkeys(hotkey2, hotkey3), _weights(5000, 5000));
        vault.rebalance(NETUID1);

        (, bytes32 owner) = MockStaking(STAKING_PRECOMPILE).getHotkeyOwner(hotkey1);
        assertEq(owner, _toSubstrate(address(vault)), "the vault claimed the ownerless key to roll it");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "and rolled its alpha onto the set");
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "losing nothing");
    }

    /// @dev A coldkey swap moves every hotkey of the validator to the new coldkey; the attesters confirm it.
    function test_ValidatorColdkeySwap_RetiresItsSlotUntilReattested() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        MockStaking(STAKING_PRECOMPILE).setHotkeyOwner(hotkey1, keccak256("the validator's new coldkey"));

        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey1));
        vault.rebalance(NETUID1);

        _reattestCurrentSet(NETUID1);
        vault.rebalance(NETUID1);
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "the position is whole under the new coldkey");
    }

    /// @dev hotkey1's slot returns on hotkey4 short by `missing` RAO and is collected into parking.
    function _firstSlotReturnedShortBy(uint256 missing) private {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, coldkey, NETUID1, FIRST_SLOT - missing);
        _simulateSameOwner(hotkey1, hotkey4);

        vault.syncBacking(TOKEN1);
        vault.recoverStray(TOKEN1, hotkey4);
        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "partial finds are secured too");
    }

    function testFuzz_RecoverStray_CompletesWithinTheSlack(uint256 missing) public {
        _firstSlotReturnedShortBy(bound(missing, 0, BACKING_SLACK_RAO));

        vault.syncBacking(TOKEN1);

        assertTrue(vault.awaitingAttestation(TOKEN1), "pooled coverage within the slack completes recovery");
    }

    function testFuzz_RecoverStray_PreservesTheUnrecoveredDeficit(uint256 missing) public {
        missing = bound(missing, BACKING_SLACK_RAO + 1, 2 * BACKING_SLACK_RAO);
        _firstSlotReturnedShortBy(missing);

        assertFalse(vault.awaitingAttestation(TOKEN1), "completion requires pooled coverage");
        assertEq(lens.missingStake(TOKEN1), missing);
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, 30 * ALPHA);
    }

    function test_SquattedFundedKey_IsRetiredNotFunded() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);
        _simulateSquatter(hotkey1);

        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey1));
        vault.rebalance(NETUID1);
    }
}

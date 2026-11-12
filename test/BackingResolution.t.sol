// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { BackingScenarios } from "./helpers/BackingScenarios.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";
import {
    AttestedHotkeyRetired,
    BackingShortfall,
    BackingUnchanged,
    NothingToRecover,
    ShortfallOnFile
} from "src/VaultErrors.sol";
import { IAlphaVaultAbi } from "src/interfaces/IAlphaVaultAbi.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { IStaking, STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

contract BackingResolutionTest is BackingScenarios {
    uint256 private constant SINGLE_VALIDATOR_NETUID = 5;

    function _recordedCutEdge() private {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _cutTheEdge(hotkey1, hotkey4);
        vault.syncBacking(TOKEN1);
    }

    function test_CutEdge_ResolvesOnTheStakingList() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _cutTheEdge(hotkey1, hotkey4);

        assertTrue(lens.isBackingIntact(TOKEN1), "the list shows where the alpha went");
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "the moved pile still counts");
        assertEq(lens.resolvedBacking(TOKEN1).hotkeys[0], hotkey4, "the slot answers under the found hotkey");
        vault.syncBacking(TOKEN1);
        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, hotkey4, "one sync records it");
        assertEq(lens.writeOffDeadline(TOKEN1), 0, "and no clock runs");
    }

    function test_RevertWhen_SyncingAgainAfterRecordingACutEdge() public {
        _recordedCutEdge();

        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);
    }

    function test_RevertWhen_RecoveringFromTheHotkeyACutEdgeResolvedTo() public {
        _recordedCutEdge();

        vm.expectRevert(NothingToRecover.selector);
        vault.recoverStray(TOKEN1, hotkey4);
    }

    function test_EdgeRepointedAtAnEmptyHotkey_ResolvesOnTheStakingList() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        _simulateSquatter(hotkey1);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey1, NETUID1, hotkey5);

        assertTrue(lens.isBackingIntact(TOKEN1), "an edge to an empty hotkey is not followed");
        assertEq(lens.resolvedBacking(TOKEN1).hotkeys[0], hotkey4, "the list shows the hotkey holding the pile");
        vault.rebalance(NETUID1);
        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, hotkey4, "and a priced call records it");
    }

    function test_CutEdge_AllRailsKeepWorking() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _cutTheEdge(hotkey1, hotkey4);

        _assertEveryRailWorks(hotkey1, 47_500_000_000);

        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, hotkey4, "the slot keeps answering under the found hotkey");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "nothing lands on the vacated hotkey");
        vm.prank(alice);
        vault.unwrap(TOKEN1, 4e19, _toSubstrate(alice), 0);
        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), 40 * ALPHA, "the first holder exits both deposits in full");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "and still nothing sits on the vacated hotkey");
    }

    function test_TwoMovedSlots_EachResolveToTheirOwnPile() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey3), _weights(2000, 6000, 2000));
        _depositAndWrap(alice, NETUID1, 40 * ALPHA);
        _cutTheEdge(hotkey2, hotkey5);
        _cutTheEdge(hotkey1, hotkey4);

        VaultReads.Backing memory backing = lens.resolvedBacking(TOKEN1);

        assertEq(backing.hotkeys[0], hotkey4, "the 8 alpha slot takes the 8 alpha pile, not the 24 listed first");
        assertEq(backing.hotkeys[1], hotkey5, "the 24 alpha slot takes its own pile");
        assertEq(backing.hotkeys[2], hotkey3, "the untouched slot stays where it is");
        assertEq(backing.total, 40 * ALPHA, "every pile is counted once");
        assertTrue(lens.isBackingIntact(TOKEN1), "with nothing short");
        vault.syncBacking(TOKEN1);
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[0].stakedUnder, hotkey4, "the sync records the first slot under its 8 alpha pile");
        assertEq(slots[1].stakedUnder, hotkey5, "and the second under its 24 alpha pile");
    }

    function _moveTheEqualWeightSlots(uint256 firstPileGain, uint256 secondPileGain) private returns (uint256 shares) {
        shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _cutTheEdge(hotkey1, hotkey4);
        _cutTheEdge(hotkey2, hotkey5);
        MockStaking mock = MockStaking(STAKING_PRECOMPILE);
        bytes32 cloneColdkey = _subnetColdkey(NETUID1);
        mock.setStake(hotkey4, cloneColdkey, NETUID1, mock.getStake(hotkey4, cloneColdkey, NETUID1) + firstPileGain);
        mock.setStake(hotkey5, cloneColdkey, NETUID1, mock.getStake(hotkey5, cloneColdkey, NETUID1) + secondPileGain);
    }

    function _attestOnlyTheFirstSuccessor() private {
        _simulateSquatter(hotkey2);
        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
    }

    function _attestBothSuccessors() private {
        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey5, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
    }

    function _assertEachSlotUnderItsOwnValidator() private view {
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[0].attested, hotkey4, "the first slot is attested under validator 1's successor");
        assertEq(slots[0].stakedUnder, hotkey4, "validator 1's slot sits under validator 1's hotkey");
        assertEq(slots[1].attested, hotkey5, "the second slot is attested under validator 2's successor");
        assertEq(slots[1].stakedUnder, hotkey5, "validator 2's slot sits under validator 2's hotkey");
    }

    function test_CrossedSlots_ASetAttestingBothSuccessors_PutsEachSlotUnderItsOwnValidator() public {
        _moveTheEqualWeightSlots(20_000_000, 10_000_000);
        vault.rebalance(NETUID1);
        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, hotkey5, "a priced call records the cross");
        assertEq(vault.recordedSlots(TOKEN1)[1].stakedUnder, hotkey4, "on both crossed slots");

        _attestBothSuccessors();
        vault.rebalance(NETUID1);

        _assertEachSlotUnderItsOwnValidator();
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA + 30_000_000, "no alpha left the backing");
        assertTrue(lens.isBackingIntact(TOKEN1), "and the record accounts for it");
    }

    function test_CrossedSlots_ASetAttestingOneSuccessor_KeepsTheTaoExitAndResumesOnceBothAreAttested() public {
        uint256 shares = _moveTheEqualWeightSlots(20_000_000, 10_000_000);
        _attestOnlyTheFirstSuccessor();
        uint256 balanceBefore = alice.balance;

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 4, 0);

        assertEq(alice.balance - balanceBefore, 375_374_999e9, "the TAO exit sold 7.507499999 alpha at 0.05 TAO/alpha");

        _attestBothSuccessors();
        vault.rebalance(NETUID1);

        _assertEachSlotUnderItsOwnValidator();
        assertEq(lens.totalStake(TOKEN1), 22_522_500_001, "30.03 alpha less the TAO exit");
        assertTrue(lens.isBackingIntact(TOKEN1), "and the record accounts for it");
    }

    function test_ASweptSlot_NeverTakesAnotherSlotsSuccessor() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey3), _weights(2000, 6000, 2000));
        _depositAndWrap(alice, NETUID1, 40 * ALPHA);
        _sweepDuringCrash(NETUID1, hotkey1);
        _simulatePerSubnetSwap(NETUID1, hotkey2, hotkey5);

        VaultReads.Backing memory backing = lens.resolvedBacking(TOKEN1);

        assertTrue(backing.short[0], "the swept slot stays short");
        assertEq(backing.hotkeys[1], hotkey5, "the swapped slot follows its own edge");
        assertFalse(backing.short[1], "and is covered there");
        assertEq(backing.total, 32 * ALPHA, "40 alpha less the 8 alpha swept");
        vm.expectRevert(abi.encodeWithSelector(BackingShortfall.selector, NETUID1, hotkey1, 8 * ALPHA));
        vault.rebalance(NETUID1);
    }

    function test_ARecordedHotkeyTheSearchFrees_CanHoldAnotherSlot() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey3), _weights(6000, 2000, 2000));
        _depositAndWrap(alice, NETUID1, 40 * ALPHA);
        _cutTheEdge(hotkey1, hotkey4);
        _simulateFollowedSwap(NETUID1, hotkey2, hotkey1);

        VaultReads.Backing memory backing = lens.resolvedBacking(TOKEN1);

        assertEq(backing.hotkeys[0], hotkey4, "the 24 alpha slot is found on the list");
        assertEq(backing.hotkeys[1], hotkey1, "the 8 alpha slot takes the hotkey the first slot left");
        assertEq(backing.total, 40 * ALPHA, "every pile is counted once");
        assertTrue(lens.isBackingIntact(TOKEN1), "with nothing short");
        vault.rebalance(NETUID1);
        assertEq(vault.recordedSlots(TOKEN1)[1].stakedUnder, hotkey1, "a priced call records the freed hotkey");
    }

    function test_AHotkeyAnotherSlotHolds_NeverCoversASlot() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey3), _weights(2000, 6000, 2000));
        _depositAndWrap(alice, NETUID1, 40 * ALPHA);
        _sweepDuringCrash(NETUID1, hotkey1);

        assertTrue(lens.resolvedBacking(TOKEN1).short[0], "hotkey2's 24 alpha belongs to its own slot");
        vm.expectRevert(abi.encodeWithSelector(BackingShortfall.selector, NETUID1, hotkey1, 8 * ALPHA));
        vault.rebalance(NETUID1);
    }

    function test_UntrackedParkingStake_NeverCoversASlot() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        uint256 swept = _sweepDuringCrash(NETUID1, hotkey1);
        _strangerReturns(NETUID1, vault.parkingHotkey(), swept);

        assertTrue(lens.resolvedBacking(TOKEN1).short[0], "parking is never a slot's hotkey");
        vm.expectRevert(abi.encodeWithSelector(BackingShortfall.selector, NETUID1, hotkey1, FIRST_SLOT));
        vault.rebalance(NETUID1);
    }

    function test_SplitPile_StaysShortUntilCollectedFromEachHotkey() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        uint256 swept = _sweepDuringCrash(NETUID1, hotkey1);
        _strangerReturns(NETUID1, hotkey4, swept / 2);
        _strangerReturns(NETUID1, hotkey5, swept - swept / 2);

        assertTrue(lens.resolvedBacking(TOKEN1).short[0], "no single listed pile covers the slot");
        vault.syncBacking(TOKEN1);
        vault.recoverStray(TOKEN1, hotkey4);
        vault.recoverStray(TOKEN1, hotkey5);
        vault.syncBacking(TOKEN1);
        assertEq(_parkedStake(NETUID1), 30 * ALPHA, "both halves are parked from the hotkeys the watcher supplied");
        assertTrue(lens.isBackingIntact(TOKEN1), "and the position accounts for itself");
    }

    function test_Successor_WinsOverASmallerListedPile() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulatePerSubnetSwap(NETUID1, hotkey1, hotkey4);
        _strangerReturns(NETUID1, hotkey5, FIRST_SLOT - BACKING_SLACK_RAO);

        assertEq(lens.resolvedBacking(TOKEN1).hotkeys[0], hotkey4, "the successor edge is followed before the list");
        vault.rebalance(NETUID1);
        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, hotkey4, "a priced call records the successor");
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "and the listed pile is not counted");
    }

    function testFuzz_CutEdge_ResolvesAtAnyListPosition(uint256 entriesBefore, uint256 entriesAfter, uint256 amount)
        public
    {
        entriesBefore = bound(entriesBefore, 3, STAKING_LIST_CAP - 4);
        entriesAfter = bound(entriesAfter, 0, STAKING_LIST_CAP - 3 - entriesBefore);
        amount = bound(amount, ALPHA, 1_000 * ALPHA);
        _depositAndWrap(alice, NETUID1, amount);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        _fillListTo(coldkey, entriesBefore);
        _cutTheEdge(hotkey1, hotkey4);
        _fillListTo(coldkey, entriesBefore + 1 + entriesAfter);

        assertTrue(lens.isBackingIntact(TOKEN1), "found wherever the list holds it");
        assertEq(lens.totalStake(TOKEN1), amount, "the whole deposit still counts");
        vault.syncBacking(TOKEN1);
        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, hotkey4, "one sync records the found hotkey");
    }

    function _listedPileShortBy(uint256 missing) private {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _sweepDuringCrash(NETUID1, hotkey1);
        _strangerReturns(NETUID1, hotkey4, FIRST_SLOT - missing);
    }

    function test_ListedPileShortByTheSlack_CoversTheSlot() public {
        _listedPileShortBy(BACKING_SLACK_RAO);

        assertTrue(lens.isBackingIntact(TOKEN1), "1,000 RAO short is accounting dust");
        vault.syncBacking(TOKEN1);
        VaultReads.Slot memory slot = vault.recordedSlots(TOKEN1)[0];
        assertEq(slot.stakedUnder, hotkey4, "the sync records the listed pile");
        assertEq(slot.tracked, 10_001_999_000, "at the 10.002 alpha less 1,000 RAO it holds");
    }

    function test_RevertWhen_AListedPileIsOneRaoPastTheSlack() public {
        _listedPileShortBy(BACKING_SLACK_RAO + 1);

        vm.expectRevert(abi.encodeWithSelector(BackingShortfall.selector, NETUID1, hotkey1, FIRST_SLOT));
        vault.rebalance(NETUID1);
    }

    function testFuzz_ListedPile_CoversWithinTheSlack(uint256 missing) public {
        missing = bound(missing, 0, 2 * BACKING_SLACK_RAO);
        _listedPileShortBy(missing);

        assertEq(lens.isBackingIntact(TOKEN1), missing <= BACKING_SLACK_RAO, "a listed pile covers within 1,000 RAO");
    }

    function test_SelfSuccessorResponse_LeavesBackingAndValidatorsUnchanged() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32[] memory attested = _hotkeys(hotkey1, hotkey2, hotkey3);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey1, NETUID1, hotkey1);

        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "the quote counts the whole position");
        assertTrue(lens.isBackingIntact(TOKEN1), "and reads it as sound");
        vault.rebalance(NETUID1);

        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "the rebalance moved nothing out");
        assertEq(lens.lastSeenHotkeys(TOKEN1), attested, "every slot stays under its attested hotkey");
        assertEq(_vaultStakeAcross(attested, NETUID1), 30 * ALPHA, "which hold the whole position");
        assertTrue(lens.isBackingIntact(TOKEN1), "and the record is still sound");
    }

    function test_SelfSuccessorWithMissingBacking_LeavesTheShortfallUnresolved() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _sweepDuringCrash(NETUID1, hotkey1);
        _strangerReturns(NETUID1, hotkey1, FIRST_SLOT - 2 * BACKING_SLACK_RAO);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey1, NETUID1, hotkey1);

        vm.expectCall(STAKING_PRECOMPILE, abi.encodeCall(IStaking.getHotkeySuccessor, (hotkey1, uint16(NETUID1))));
        assertFalse(lens.isBackingIntact(TOKEN1), "a hotkey that succeeds itself supplies no missing alpha");
        vm.expectRevert(abi.encodeWithSelector(BackingShortfall.selector, NETUID1, hotkey1, FIRST_SLOT));
        vault.rebalance(NETUID1);
    }

    function test_TwoHopTrail_ResolvesOnTheStakingList() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 tip = _buildSwapTrail(NETUID1, hotkey1, 2);

        assertTrue(lens.isBackingIntact(TOKEN1), "the tip of a trail the vault will not walk is on the list");
        assertEq(lens.resolvedBacking(TOKEN1).hotkeys[0], tip, "the slot answers under the tip");
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "the moved pile still counts");
        assertEq(lens.sharePrice(TOKEN1), 1e9, "30 alpha behind 3e19 shares is 1e9 RAO per 1e18 share units");
        (uint256 quotedAlpha,) = lens.previewUnwrap(TOKEN1, shares / 2);
        assertEq(quotedAlpha, 15 * ALPHA, "half the shares quote half of 30 alpha");
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice), 0);
        assertEq(
            _userStakeAcrossHotkeys(alice, NETUID1) + _getStakeForColdkey(tip, _toSubstrate(alice), NETUID1),
            15 * ALPHA,
            "the exit pays the quote"
        );
    }

    function test_ShortfallStanding_LeavesTransfersAndTaoClaimsLive() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _donateToClone(vault.subnetClone(TOKEN1), 4 * TAO);
        vault.rebalance(NETUID1);
        _sweepDuringCrash(NETUID1, hotkey1);
        vault.syncBacking(TOKEN1);

        vm.prank(alice);
        vault.safeTransferFrom(alice, bob, TOKEN1, shares / 2, "");
        assertEq(vault.balanceOf(bob, TOKEN1), 1.5e19, "shares move while the window runs");

        assertEq(
            _claimQuotedAmount(alice, TOKEN1),
            3_999_999_999_000_000_000,
            "4 TAO over 3e19 shares, floored on the index and to whole RAO"
        );
    }

    function test_GrowthElsewhere_DoesNotCoverALoss() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _sweepDuringCrash(NETUID1, hotkey1);
        _strangerReturns(NETUID1, hotkey2, FIRST_SLOT + 5 * ALPHA);

        assertEq(_getVaultStake(hotkey2, NETUID1), 25_001_000_000, "its own 9.999 alpha, the lost 10.002 and 5 more");
        assertFalse(lens.isBackingIntact(TOKEN1), "a richer neighbour explains nothing");
        vm.expectRevert(abi.encodeWithSelector(BackingShortfall.selector, NETUID1, hotkey1, FIRST_SLOT));
        vault.rebalance(NETUID1);
    }

    function test_ConvergentSwaps_FailClosedUntilParked() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        _simulateOffVaultSwap(NETUID1, hotkey2, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey1, NETUID1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey2, NETUID1, hotkey4);

        assertFalse(lens.isBackingIntact(TOKEN1), "the quote sees the collision");
        vm.expectRevert(abi.encodeWithSelector(BackingShortfall.selector, NETUID1, hotkey2, OTHER_SLOT));
        vault.rebalance(NETUID1);

        vault.syncBacking(TOKEN1);

        assertTrue(lens.isBackingIntact(TOKEN1), "the merged balance is counted once on the parking hotkey");
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "and nothing was lost in the collision");
        assertEq(_parkedStake(NETUID1), 30 * ALPHA, "the sync parked all of it with no source from a watcher");
    }

    function test_SuccessorHoldingHalfTheSlot_FailsClosed() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _sweepDuringCrash(NETUID1, hotkey1);
        _simulatePerSubnetSwap(NETUID1, hotkey1, hotkey4);
        _strangerReturns(NETUID1, hotkey4, 5_001_000_000);

        assertFalse(lens.isBackingIntact(TOKEN1), "half the alpha is not the alpha");
        vm.expectRevert(abi.encodeWithSelector(BackingShortfall.selector, NETUID1, hotkey1, FIRST_SLOT));
        vault.rebalance(NETUID1);
    }

    function test_SuccessorWithAStrayLeftOnTheSwappedHotkey_StaysOperable() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulatePerSubnetSwap(NETUID1, hotkey1, hotkey4);
        _strangerReturns(NETUID1, hotkey1, CRUMB);

        assertTrue(lens.isBackingIntact(TOKEN1), "stray stake cannot block the recorded successor");
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "the stray is not counted twice");
        vault.rebalance(NETUID1);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 0);
        assertEq(
            _getStakeForColdkey(hotkey4, _toSubstrate(alice), NETUID1),
            7_500_000_000,
            "a quarter of 30 alpha, paid from the successor"
        );
    }

    function test_SwapOntoAHotkeyAnotherSlotLeft_StaysOperable() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulateFollowedSwap(NETUID1, hotkey2, hotkey5);
        vault.rebalance(NETUID1);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey2);

        vault.rebalance(NETUID1);

        assertTrue(lens.isBackingIntact(TOKEN1), "no balance answers for two slots");
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "the whole position is counted once");
        vm.prank(alice);
        vault.unwrap(TOKEN1, 7.5e18, _toSubstrate(alice), 0);
        assertEq(
            _getStakeForColdkey(hotkey2, _toSubstrate(alice), NETUID1),
            7_500_000_000,
            "a quarter of 30 alpha, paid from the richest slot"
        );
    }

    function _sellTheFirstSlotAfterItsAttestedHotkeyIsReused() private {
        _positionFollowingASwap(hotkey4);
        _simulateFollowedSwap(NETUID1, hotkey2, hotkey1);

        vm.prank(alice);
        // The first slot's 10.002 alpha at the first deposit's 1e9 shares per RAO.
        vault.unwrapForTao(TOKEN1, FIRST_SLOT * 1e9, 0);
    }

    function test_TaoExitEmptyingASwappedSlot_LeavesNoBalanceAnsweringTwice() public {
        _sellTheFirstSlotAfterItsAttestedHotkeyIsReused();

        assertEq(lens.locatedStake(TOKEN1), OTHER_TWO_SLOTS, "the position counts what it holds, once");
        _assertSlotsOnDistinctHotkeys(TOKEN1);
    }

    function test_SettleAfterAnEmptyingExit_KeepsSlotsOnDistinctHotkeys() public {
        _sellTheFirstSlotAfterItsAttestedHotkeyIsReused();

        vault.rebalance(NETUID1);

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[0].stakedUnder, hotkey4, "the emptied slot kept its resolved hotkey");
        assertEq(slots[1].stakedUnder, hotkey1, "beside the slot whose alpha its attested hotkey carries");
        assertEq(slots[2].stakedUnder, hotkey3, "and the untouched third slot");
        assertEq(_getVaultStake(hotkey4, NETUID1), REFILLED_FIRST_SLOT, "3334 bps of the remaining 19.998 alpha");
        assertEq(lens.totalStake(TOKEN1), OTHER_TWO_SLOTS, "and the total counts each balance once");
    }

    function _positionWithAnEmptiedSlotOnAnotherHotkey() private {
        _positionFollowingASwap(hotkey4);
        _simulatePerSubnetSwap(NETUID1, hotkey2, hotkey1);
        _drainTheFirstSlot(alice, NETUID1);
    }

    function test_RevertWhen_RebalancingASetAttestingTheHotkeyAnEmptiedSlotStaysOn() public {
        _positionWithAnEmptiedSlotOnAnotherHotkey();

        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey4, hotkey2), _weights(3334, 3333, 3333));

        vm.expectRevert(IAlphaVaultAbi.SwappedHotkeyStillAttested.selector);
        vault.rebalance(NETUID1);
    }

    function test_RevertWhen_RebalancingWithAnEmptiedSlotOnARetiredHotkey() public {
        _positionWithAnEmptiedSlotOnAnotherHotkey();

        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey4, true);

        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey1));
        vault.rebalance(NETUID1);
    }

    /// @dev No edge distinguishes a dust sweep from an erased swap trail; neither permits immediate repricing.
    function testFuzz_RevertWhen_EmptiedWithoutAnEdge_AtAnyPriceOrSize(uint256 deposit, uint256 priceRao) public {
        // From the 0.04 alpha deposit floor at 0.05 TAO/alpha.
        deposit = bound(deposit, ALPHA_FLOOR, 100_000 * ALPHA);
        _registerSubnet(SINGLE_VALIDATOR_NETUID, hotkey1);
        _depositAndWrap(alice, SINGLE_VALIDATOR_NETUID, deposit);
        uint256 tokenId = vault.currentTokenId(SINGLE_VALIDATOR_NETUID);
        _sweepDuringCrash(SINGLE_VALIDATOR_NETUID, hotkey1);
        _setAlphaPrice(SINGLE_VALIDATOR_NETUID, _wholeRaoPrice(priceRao));

        assertFalse(lens.isBackingIntact(tokenId), "nothing on chain accounts for the emptying");
        vm.expectRevert(abi.encodeWithSelector(BackingShortfall.selector, SINGLE_VALIDATOR_NETUID, hotkey1, deposit));
        vault.rebalance(SINGLE_VALIDATOR_NETUID);
    }

    function test_SweptPosition_ReopensAfterTheWindow() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _sweepEverySlot();

        assertFalse(lens.isBackingIntact(TOKEN1), "an emptied position cannot account for itself");
        _runOutRecoveryWindow(TOKEN1);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
        assertEq(vault.totalSupply(TOKEN1), 0, "the shares retire against what is left");

        _reattestValidators(NETUID1);
        _depositAndWrap(bob, NETUID1, 30 * ALPHA);
        assertEq(vault.balanceOf(bob, TOKEN1), 3e19, "the token recapitalizes at 1e9 shares per RAO");
    }

    function test_RegistryUpdate_NeitherClearsALossNorAddsBacking() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _sweepDuringCrash(NETUID1, hotkey1);
        vault.syncBacking(TOKEN1);

        _strangerReturns(NETUID1, hotkey4, 9 * ALPHA);
        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );

        assertFalse(lens.isBackingIntact(TOKEN1), "the rotation settled nothing");
        assertEq(lens.locatedStake(TOKEN1), OTHER_TWO_SLOTS, "and added no backing of its own");
        vm.expectRevert(ShortfallOnFile.selector);
        vault.rebalance(NETUID1);
    }
}

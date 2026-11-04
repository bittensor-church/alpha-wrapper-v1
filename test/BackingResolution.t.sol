// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";
import { AttestedHotkeyRetired, BackingShortfall, ShortfallOnFile } from "src/VaultErrors.sol";
import { IAlphaVaultAbi } from "src/interfaces/IAlphaVaultAbi.sol";
import { CHAIN_MIN_TRANSFER, MockStaking } from "./mocks/MockStaking.sol";
import { IStaking, MAX_STAKING_HOTKEYS, STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { BackingUnchanged, NothingToRecover } from "src/VaultErrors.sol";

contract BackingResolutionTest is AlphaVaultTestBase {
    /// @dev 30 alpha at 3334 / 3333 / 3333 bps: hotkey1 holds 10.002 alpha.
    uint256 private constant FIRST_SLOT = 10_002_000_000;

    function _cutTheEdge(bytes32 fromHotkey, bytes32 toHotkey) private {
        _simulateOffVaultSwap(NETUID1, fromHotkey, toHotkey);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(fromHotkey, true);
    }

    function test_CutEdge_ResolvesOnTheStakingList() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _cutTheEdge(hotkey1, hotkey4);

        assertTrue(lens.isBackingIntact(TOKEN1), "the list names where the alpha went");
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA);
        assertEq(lens.resolvedBacking(TOKEN1).hotkeys[0], hotkey4, "the slot answers under the found hotkey");
        vault.syncBacking(TOKEN1);
        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, hotkey4, "one sync records it");
        assertEq(lens.writeOffDeadline(TOKEN1), 0, "and no clock runs");
        vm.expectRevert(BackingUnchanged.selector);
        vault.syncBacking(TOKEN1);
        vm.expectRevert(NothingToRecover.selector);
        vault.recoverStray(TOKEN1, hotkey4);
    }

    function test_EdgeRepointedAtAnEmptyHotkey_ResolvesOnTheStakingList() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        _simulateSquatter(hotkey1);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey1, NETUID1, hotkey5);

        assertTrue(lens.isBackingIntact(TOKEN1), "an edge to an empty hotkey is not followed");
        assertEq(lens.resolvedBacking(TOKEN1).hotkeys[0], hotkey4);
        vault.rebalance(NETUID1);
        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, hotkey4);
    }

    function test_CutEdge_AllRailsKeepWorking() public {
        uint256 aliceShares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _cutTheEdge(hotkey1, hotkey4);

        uint256 quotedShares = lens.previewWrap(TOKEN1, 30 * ALPHA);
        uint256 bobShares = _depositAndWrap(bob, NETUID1, 30 * ALPHA);
        assertEq(bobShares, quotedShares, "previewWrap matches the wrap chosen under the swapped hotkey");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "nothing lands on the vacated hotkey");

        (uint256 quotedAlpha,) = lens.previewUnwrap(TOKEN1, bobShares / 2);
        vm.prank(bob);
        vault.unwrap(TOKEN1, bobShares / 2, _toSubstrate(bob), 0);
        assertEq(_userStakeAcrossHotkeys(bob, NETUID1), quotedAlpha, "the alpha exit paid the quote");
        (uint256 soldAlpha,) = lens.previewUnwrap(TOKEN1, bobShares / 4);
        vm.prank(bob);
        vault.unwrapForTao(TOKEN1, bobShares / 4, 0);
        assertGt(bob.balance, 0, "the TAO exit paid");
        vault.rebalance(NETUID1);

        assertEq(lens.totalStake(TOKEN1), 60 * ALPHA - quotedAlpha - soldAlpha, "60 alpha less both exits");
        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, hotkey4, "the slot keeps answering under the found hotkey");
        assertTrue(lens.isBackingIntact(TOKEN1), "record sound throughout");
        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares, _toSubstrate(alice), 0);
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
        assertEq(backing.hotkeys[2], hotkey3);
        assertEq(backing.total, 40 * ALPHA);
        assertTrue(lens.isBackingIntact(TOKEN1));
    }

    function test_ASweptSlot_NeverTakesAnotherSlotsSuccessor() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey3), _weights(2000, 6000, 2000));
        _depositAndWrap(alice, NETUID1, 40 * ALPHA);
        _sweepDuringCrash(NETUID1, hotkey1);
        _simulatePerSubnetSwap(NETUID1, hotkey2, hotkey5);

        VaultReads.Backing memory backing = lens.resolvedBacking(TOKEN1);

        assertTrue(backing.short[0], "the swept slot stays short");
        assertEq(backing.hotkeys[1], hotkey5, "the swapped slot follows its own edge");
        assertFalse(backing.short[1]);
        assertEq(backing.total, 32 * ALPHA);
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
        assertEq(backing.total, 40 * ALPHA);
        assertTrue(lens.isBackingIntact(TOKEN1));
        vault.rebalance(NETUID1);
        assertEq(vault.recordedSlots(TOKEN1)[1].stakedUnder, hotkey1);
    }

    function test_AHotkeyAnotherSlotHolds_NeverCoversASlot() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey3), _weights(2000, 6000, 2000));
        _depositAndWrap(alice, NETUID1, 40 * ALPHA);
        _sweepDuringCrash(NETUID1, hotkey1);

        assertTrue(lens.resolvedBacking(TOKEN1).short[0], "hotkey2's 24 alpha belongs to its own slot");
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.rebalance(NETUID1);
    }

    function test_UntrackedParkingStake_NeverCoversASlot() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        MockStaking(STAKING_PRECOMPILE).setStake(vault.parkingHotkey(), _subnetColdkey(NETUID1), NETUID1, FIRST_SLOT);
        _sweepDuringCrash(NETUID1, hotkey1);

        assertTrue(lens.resolvedBacking(TOKEN1).short[0], "parking is never a slot's hotkey");
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.rebalance(NETUID1);
    }

    function test_SplitPile_StaysShortUntilCollectedByName() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        uint256 swept = _sweepDuringCrash(NETUID1, hotkey1);
        _strangerReturns(NETUID1, hotkey4, swept / 2);
        _strangerReturns(NETUID1, hotkey5, swept - swept / 2);

        assertTrue(lens.resolvedBacking(TOKEN1).short[0], "no single listed pile covers the slot");
        vault.syncBacking(TOKEN1);
        vault.recoverStray(TOKEN1, hotkey4);
        vault.recoverStray(TOKEN1, hotkey5);
        vault.syncBacking(TOKEN1);
        assertEq(_parkedStake(NETUID1), 30 * ALPHA, "both halves are parked by name");
        assertTrue(lens.isBackingIntact(TOKEN1));
    }

    function test_Successor_WinsOverASmallerListedPile() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulatePerSubnetSwap(NETUID1, hotkey1, hotkey4);
        _strangerReturns(NETUID1, hotkey5, FIRST_SLOT - BACKING_SLACK_RAO);

        assertEq(lens.resolvedBacking(TOKEN1).hotkeys[0], hotkey4, "the successor edge is followed before the list");
    }

    function testFuzz_CutEdge_ResolvesAtAnyListPosition(uint256 entriesBefore, uint256 entriesAfter, uint256 amount)
        public
    {
        entriesBefore = bound(entriesBefore, 3, MAX_STAKING_HOTKEYS - 4);
        entriesAfter = bound(entriesAfter, 0, MAX_STAKING_HOTKEYS - 3 - entriesBefore);
        amount = bound(amount, ALPHA, 1_000 * ALPHA);
        _depositAndWrap(alice, NETUID1, amount);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        _fillListTo(coldkey, entriesBefore);
        _cutTheEdge(hotkey1, hotkey4);
        _fillListTo(coldkey, entriesBefore + 1 + entriesAfter);

        assertTrue(lens.isBackingIntact(TOKEN1), "found wherever the list holds it");
        assertEq(lens.totalStake(TOKEN1), amount);
        vault.syncBacking(TOKEN1);
        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, hotkey4);
    }

    function testFuzz_CutEdge_CoversWithinTheSlack(uint256 missing) public {
        missing = bound(missing, 0, 2 * BACKING_SLACK_RAO);
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _cutTheEdge(hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, _subnetColdkey(NETUID1), NETUID1, FIRST_SLOT - missing);

        assertEq(lens.isBackingIntact(TOKEN1), missing <= BACKING_SLACK_RAO, "a listed pile covers within the slack");
    }

    function test_SelfSuccessorResponse_LeavesBackingAndValidatorsUnchanged() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32[] memory keysBefore = lens.lastSeenHotkeys(TOKEN1);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey1, NETUID1, hotkey1);

        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA);
        assertTrue(lens.isBackingIntact(TOKEN1));
        vault.rebalance(NETUID1);

        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA);
        assertEq(lens.lastSeenHotkeys(TOKEN1), keysBefore);
        assertEq(_vaultStakeAcross(keysBefore, NETUID1), 30 * ALPHA);
        assertTrue(lens.isBackingIntact(TOKEN1));
    }

    function test_SelfSuccessorWithMissingBacking_LeavesTheShortfallUnresolved() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        uint256 tracked = 10_002_000_000;
        uint256 missing = 2 * BACKING_SLACK_RAO;
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(NETUID1), NETUID1, tracked - missing);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey1, NETUID1, hotkey1);

        // A shortfall forces a successor lookup; naming itself cannot supply missing alpha.
        vm.expectCall(STAKING_PRECOMPILE, abi.encodeCall(IStaking.getHotkeySuccessor, (hotkey1, uint16(NETUID1))));
        assertFalse(lens.isBackingIntact(TOKEN1));
        vm.expectRevert(abi.encodeWithSelector(BackingShortfall.selector, NETUID1, hotkey1, tracked));
        vault.rebalance(NETUID1);
    }

    function test_TwoHopTrail_ResolvesOnTheStakingList() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 tip = _buildSwapTrail(NETUID1, hotkey1, 2);

        assertTrue(lens.isBackingIntact(TOKEN1), "the tip of a trail the vault will not walk is on the list");
        assertEq(lens.resolvedBacking(TOKEN1).hotkeys[0], tip);
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA);
        assertGt(lens.sharePrice(TOKEN1), 0);
        (uint256 quotedAlpha,) = lens.previewUnwrap(TOKEN1, shares / 2);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice), 0);
        assertEq(
            _userStakeAcrossHotkeys(alice, NETUID1) + _getStakeForColdkey(tip, _toSubstrate(alice), NETUID1),
            quotedAlpha
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
        assertEq(vault.balanceOf(bob, TOKEN1), shares / 2, "shares move while the window runs");

        assertEq(
            _claimQuotedAmount(alice, TOKEN1),
            3_999_999_999_000_000_000,
            "4 TAO over 3e19 shares, floored on the index and to whole RAO"
        );
    }

    function test_GrowthElsewhere_DoesNotCoverALoss() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _sweepDuringCrash(NETUID1, hotkey1);

        // hotkey2's own 9.999 alpha, the lost 10.002 alpha and 5 alpha more.
        uint256 richer = 9_999_000_000 + 10_002_000_000 + 5 * ALPHA;
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, _subnetColdkey(NETUID1), NETUID1, richer);

        assertFalse(lens.isBackingIntact(TOKEN1), "a richer neighbour explains nothing");
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.rebalance(NETUID1);
    }

    function test_ConvergentSwaps_FailClosedUntilParked() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, coldkey, NETUID1, 10_002_000_000 + 9_999_000_000);
        _simulateSameOwner(hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey1, NETUID1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey2, NETUID1, hotkey4);

        assertFalse(lens.isBackingIntact(TOKEN1), "the quote sees the collision");
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.rebalance(NETUID1);

        // Everything is on recorded keys, so the collision parks without a watcher-supplied source.
        vault.syncBacking(TOKEN1);

        assertTrue(lens.isBackingIntact(TOKEN1), "the merged balance is counted once on the parking hotkey");
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "and nothing was lost in the collision");
        assertEq(_parkedStake(NETUID1), 30 * ALPHA, "all of it rests on the parking hotkey");
    }

    /// @dev Synthetic partial migration exercises the coverage guard; ordinary swaps move whole entries.
    function test_PartialSuccessor_FailsClosed() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, coldkey, NETUID1, 5_001_000_000);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey1, NETUID1, hotkey4);

        assertFalse(lens.isBackingIntact(TOKEN1), "half the alpha is not the alpha");
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.rebalance(NETUID1);
    }

    function test_SuccessorWithAResidualLeftBehind_StaysOperable() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, CHAIN_MIN_TRANSFER);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, coldkey, NETUID1, 10_002_000_000);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey1, NETUID1, hotkey4);
        _simulateSameOwner(hotkey1, hotkey4);

        assertTrue(lens.isBackingIntact(TOKEN1), "stray stake cannot block the recorded successor");
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "the residual is not counted twice");
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
        uint256 quarter = vault.balanceOf(alice, TOKEN1) / 4;
        vm.prank(alice);
        vault.unwrap(TOKEN1, quarter, _toSubstrate(alice), 0);
        assertEq(
            _getStakeForColdkey(hotkey2, _toSubstrate(alice), NETUID1),
            7_500_000_000,
            "a quarter of 30 alpha, paid from the richest slot"
        );
    }

    /// @dev The second slot's alpha moves onto the first slot's old name, then the TAO exit empties the
    ///      first slot's resolved key.
    function _sellTheFirstSlotAfterItsAttestedHotkeyIsReused() private {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);
        _simulateFollowedSwap(NETUID1, hotkey2, hotkey1);

        vm.prank(alice);
        // The first slot's 10.002 alpha at the first deposit's 1e9 shares per RAO.
        vault.unwrapForTao(TOKEN1, 10_002_000_000 * 1e9, 0);
    }

    /// @dev Falling back to a logical name occupied by another slot would count one balance twice.
    function test_TaoExitEmptyingASwappedSlot_LeavesNoBalanceAnsweringTwice() public {
        _sellTheFirstSlotAfterItsAttestedHotkeyIsReused();

        assertEq(lens.locatedStake(TOKEN1), 19_998_000_000, "the position counts what it holds, once");
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        for (uint256 i; i < slots.length; ++i) {
            for (uint256 j = i + 1; j < slots.length; ++j) {
                assertTrue(slots[i].stakedUnder != slots[j].stakedUnder, "no two slots answer for one key");
            }
        }
    }

    function test_SettleAfterAnEmptyingExit_KeepsSlotsOnDistinctHotkeys() public {
        _sellTheFirstSlotAfterItsAttestedHotkeyIsReused();

        vault.rebalance(NETUID1);

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[0].stakedUnder, hotkey4, "the emptied slot kept its resolved key");
        assertEq(slots[1].stakedUnder, hotkey1, "beside the slot whose alpha its name carries");
        assertEq(slots[2].stakedUnder, hotkey3, "and the untouched third slot");
        assertEq(_getVaultStake(hotkey4, NETUID1), 6_667_333_200, "3334 bps of the remaining 19.998 alpha");
        assertEq(lens.totalStake(TOKEN1), 19_998_000_000, "and the total counts each balance once");
    }

    function _positionWithAnEmptiedSlotOnAnotherHotkey() private {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);
        _simulatePerSubnetSwap(NETUID1, hotkey2, hotkey1);
        _drainTheFirstSlot(alice, NETUID1);
    }

    function test_SetAttestingTheHotkeyAnEmptiedSlotStaysOn_Refuses() public {
        _positionWithAnEmptiedSlotOnAnotherHotkey();

        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey4, hotkey2), _weights(3334, 3333, 3333));

        vm.expectRevert(IAlphaVaultAbi.SwappedHotkeyStillAttested.selector);
        vault.rebalance(NETUID1);
    }

    function test_EmptiedSlotWhoseHotkeyIsRetired_RefusesTheRebalance() public {
        _positionWithAnEmptiedSlotOnAnotherHotkey();

        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey4, true);

        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey1));
        vault.rebalance(NETUID1);
    }

    /// @dev No edge distinguishes a dust sweep from an erased swap trail; neither permits immediate repricing.
    function testFuzz_RevertWhen_EmptiedWithoutAnEdge_AtAnyPriceOrSize(uint256 deposit, uint256 priceRao) public {
        // From the 0.04 alpha deposit floor at 0.05 TAO/alpha; prices 0.001 to 0.2 TAO/alpha in whole RAO.
        deposit = bound(deposit, ALPHA_FLOOR, 100_000 * ALPHA);
        uint256 netuid = 5;
        _registerSubnet(netuid, hotkey1);
        _depositAndWrap(alice, netuid, deposit);
        uint256 tokenId = vault.currentTokenId(netuid);

        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(netuid), netuid, 0);
        _setAlphaPrice(netuid, _wholeRaoPrice(priceRao));

        assertFalse(lens.isBackingIntact(tokenId), "nothing on chain accounts for the emptying");
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.rebalance(netuid);
    }

    function test_SweptPosition_ReopensAfterTheWindow() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey3, coldkey, NETUID1, 0);

        assertFalse(lens.isBackingIntact(TOKEN1), "an emptied position cannot account for itself");
        _runOutRecoveryWindow(TOKEN1);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
        assertEq(vault.totalSupply(TOKEN1), 0, "the shares retire against what is left");

        _reattestCurrentSet(NETUID1);
        _depositAndWrap(bob, NETUID1, 30 * ALPHA);
        assertEq(vault.balanceOf(bob, TOKEN1), 3e19, "the token recapitalizes at 1e9 shares per RAO");
    }

    function test_RegistryUpdate_NeitherClearsALossNorAddsBacking() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _sweepDuringCrash(NETUID1, hotkey1);
        vault.syncBacking(TOKEN1);

        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, _subnetColdkey(NETUID1), NETUID1, 9 * ALPHA);
        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );

        assertFalse(lens.isBackingIntact(TOKEN1), "the rotation settled nothing");
        assertEq(lens.locatedStake(TOKEN1), 19_998_000_000, "and added no backing of its own");
        vm.expectRevert(ShortfallOnFile.selector);
        vault.rebalance(NETUID1);
    }
}

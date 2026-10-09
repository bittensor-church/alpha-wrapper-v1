// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";
import { AttestedHotkeyRetired, BackingShortfall, ShortfallOnFile } from "src/VaultErrors.sol";
import { IAlphaVaultAbi } from "src/interfaces/IAlphaVaultAbi.sol";
import { CHAIN_MIN_TRANSFER, MockStaking } from "./mocks/MockStaking.sol";
import { IStaking, STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

contract BackingResolutionTest is AlphaVaultTestBase {
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

    function test_TwoHopSwap_FailsClosedOnEveryPath() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _depositAndWrap(bob, NETUID1, 30 * ALPHA);
        _buildSwapTrail(NETUID1, hotkey1, 2);

        assertFalse(lens.isBackingIntact(TOKEN1), "a trail the vault will not walk is not accounted for");

        vm.expectPartialRevert(BackingShortfall.selector);
        lens.totalStake(TOKEN1);
        vm.expectPartialRevert(BackingShortfall.selector);
        lens.sharePrice(TOKEN1);
        vm.expectPartialRevert(BackingShortfall.selector);
        lens.previewWrap(TOKEN1, ALPHA);
        vm.expectPartialRevert(BackingShortfall.selector);
        lens.previewUnwrap(TOKEN1, shares / 2);

        vm.expectPartialRevert(BackingShortfall.selector);
        vault.rebalance(NETUID1);
        _simulateAlphaDeposit(bob, NETUID1, ALPHA);
        vm.prank(bob);
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.wrap(NETUID1, hotkey1, 0);
        vm.prank(alice);
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice), 0);
        vm.prank(bob);
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.unwrapForTao(TOKEN1, shares / 4, 0);
    }

    function test_ShortfallStanding_LeavesTransfersAndTaoClaimsLive() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _donateToClone(vault.subnetClone(TOKEN1), 4 * TAO);
        vault.rebalance(NETUID1);
        _buildSwapTrail(NETUID1, hotkey1, 2);
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
        _buildSwapTrail(NETUID1, hotkey1, 2);

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

    function test_SwapOntoAKeyAnotherSlotLeft_StaysOperable() public {
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
    function _sellTheFirstSlotAfterItsNameIsReused() private {
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
        _sellTheFirstSlotAfterItsNameIsReused();

        assertEq(lens.locatedStake(TOKEN1), 19_998_000_000, "the position counts what it holds, once");
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        for (uint256 i; i < slots.length; ++i) {
            for (uint256 j = i + 1; j < slots.length; ++j) {
                assertTrue(slots[i].active != slots[j].active, "no two slots answer for one key");
            }
        }
    }

    function test_SettleAfterAnEmptyingExit_KeepsSlotsOnDistinctKeys() public {
        _sellTheFirstSlotAfterItsNameIsReused();

        vault.rebalance(NETUID1);

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[0].active, hotkey4, "the emptied slot kept its resolved key");
        assertEq(slots[1].active, hotkey1, "beside the slot whose alpha its name carries");
        assertEq(_getVaultStake(hotkey4, NETUID1), 6_667_333_200, "3334 bps of the remaining 19.998 alpha");
        assertEq(lens.totalStake(TOKEN1), 19_998_000_000, "and the total counts each balance once");
    }

    function _positionWithAnEmptiedSlotOnAnotherKey() private {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);
        _simulatePerSubnetSwap(NETUID1, hotkey2, hotkey1);
        _drainTheFirstSlot(alice, NETUID1);
    }

    function test_SetNamingTheKeyAnEmptiedSlotStaysOn_Refuses() public {
        _positionWithAnEmptiedSlotOnAnotherKey();

        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey4, hotkey2), _weights(3334, 3333, 3333));

        vm.expectRevert(IAlphaVaultAbi.SwappedHotkeyStillAttested.selector);
        vault.rebalance(NETUID1);
    }

    function test_EmptiedSlotWhoseKeyIsRetired_RefusesTheRebalance() public {
        _positionWithAnEmptiedSlotOnAnotherKey();

        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey4, true);

        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey1));
        vault.rebalance(NETUID1);
    }

    /// @dev No edge distinguishes a dust sweep from an erased swap trail; neither permits immediate repricing.
    function testFuzz_EdgeFreeEmptying_FailsClosedAtAnyPriceOrSize(uint256 deposit, uint256 priceRao) public {
        // From the 0.04 alpha deposit floor at 0.05 TAO/alpha; prices 0.001 to 0.2 TAO/alpha in whole RAO.
        deposit = bound(deposit, 4e7, 100_000 * ALPHA);
        uint256 netuid = 5;
        _registerSubnet(netuid, hotkey1);
        _depositAndWrap(alice, netuid, deposit);
        uint256 tokenId = vault.currentTokenId(netuid);

        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(netuid), netuid, 0);
        _setAlphaPrice(netuid, bound(priceRao, 1e6, 2e8) * 1e9);

        assertFalse(lens.isBackingIntact(tokenId), "nothing on chain accounts for the emptying");
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.rebalance(netuid);
    }

    function test_SwapWithNoEdge_FailsClosed() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);

        assertFalse(lens.isBackingIntact(TOKEN1), "an unrecorded move is not accounted for");
        vm.expectPartialRevert(BackingShortfall.selector);
        vault.rebalance(NETUID1);
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
        _buildSwapTrail(NETUID1, hotkey1, 2);
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

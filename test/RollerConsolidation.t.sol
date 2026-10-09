// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { VaultMath } from "src/libraries/VaultMath.sol";
import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { IAlphaVaultAbi } from "src/interfaces/IAlphaVaultAbi.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

contract RollerConsolidationTest is AlphaVaultTestBase {
    /// @dev The largest pile worth less than the 2e6-RAO minimum stake even at 0.05 TAO/alpha plus the
    ///      price read's 1e9 quantum: 0.04 alpha minus one RAO.
    uint256 private constant DUST = 39_999_999;

    /// @dev At a price the EVM reads as zero (5e-10 TAO/alpha) the chain moves only piles of 200,000 alpha
    ///      or more, so positions there are sized in millions of alpha.
    uint256 private constant LARGE_POSITION = 1_000_000 * ALPHA;

    function _seedDustOnlyVault() private returns (uint256 tokenId) {
        _registerSubnet(99, hotkey4);
        _simulateAlphaDepositHotkey(alice, 99, 10 * ALPHA, hotkey4);
        _wrapHotkey(alice, 99, hotkey4);
        tokenId = vault.currentTokenId(99);
        _plantVaultStake(hotkey4, 99, DUST);
        _setValidators(99, _hotkeys(hotkey1), _weights(VaultMath.BPS_BASE));
    }

    function test_Rebalance_ConsolidatesMultipleRotatedOutSlots() public {
        _depositAndWrap(alice, NETUID1, 300 * ALPHA);

        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey4), _weights(5000, 5000));
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey2, NETUID1), 0, "first rotated-out slot consolidated");
        assertEq(_getVaultStake(hotkey3, NETUID1), 0, "second rotated-out slot consolidated");
        assertEq(_getVaultStake(hotkey1, NETUID1), 150 * ALPHA);
        assertEq(_getVaultStake(hotkey4, NETUID1), 150 * ALPHA);
        bytes32[] memory seen = _lastSeen(TOKEN1);
        assertEq(seen.length, 2, "remembered set refreshed to the 2-validator current set");
        assertEq(seen[0], hotkey1);
        assertEq(seen[1], hotkey4);
    }

    /// @dev Flushing before consolidation lets the fresh deposit carry otherwise-unmovable dust.
    function test_Wrap_ConsolidatesRotatedOutStakeUsingFreshDeposit() public {
        uint256 tokenId = _seedDustOnlyVault();

        _simulateAlphaDepositHotkey(bob, 99, 5 * ALPHA, hotkey1);
        _wrapHotkey(bob, 99, hotkey1);

        // 5e9 * (1e19 + 1e9) / (39,999,999 + 1): the dust already backs alice's 1e19 shares.
        assertEq(vault.balanceOf(bob, tokenId), 1_250_000_000_125_000_000_000, "priced against the dust");
        assertEq(_getVaultStake(hotkey4, 99), 0, "rotated-out dust consolidated by the roll");
        assertEq(lens.totalStake(tokenId), 5 * ALPHA + DUST, "rotated-out stake folded into the current-set backing");
        bytes32[] memory seen = _lastSeen(tokenId);
        assertEq(seen[0], hotkey1, "remembered set refreshed to the current set");
    }

    /// @dev Revisiting the richest slot after its pile has left would reuse a stale balance.
    function test_Rebalance_ConsolidatesWhenRicherRotatedOutSlotSitsAtLaterIndex() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(3000, 7000));
        _depositAndWrap(alice, NETUID1, 100 * ALPHA);

        _setValidators(NETUID1, _hotkeys(hotkey4), _weights(VaultMath.BPS_BASE));
        vm.recordLogs();
        vault.rebalance(NETUID1);

        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 0, "pure consolidation emits nothing");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "earlier rotated-out slot consolidated");
        assertEq(_getVaultStake(hotkey2, NETUID1), 0, "richest rotated-out slot consolidated");
        assertEq(_getVaultStake(hotkey4, NETUID1), 100 * ALPHA, "whole pile landed on the current set");
        assertEq(lens.totalStake(TOKEN1), 100 * ALPHA, "total conserved");
    }

    function test_Rebalance_RollsPileThroughFundedRotatedOutSlot() public {
        _depositAndWrap(alice, NETUID1, 300 * ALPHA);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));

        vm.recordLogs();
        vault.rebalance(NETUID1);

        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 1, "roll hops are silent; only the alignment logs");

        assertEq(_getVaultStake(hotkey3, NETUID1), 0, "rotated-out slot consolidated by the roll");
        assertEq(_getVaultStake(hotkey1, NETUID1), 150 * ALPHA);
        assertEq(_getVaultStake(hotkey2, NETUID1), 150 * ALPHA);
        assertEq(lens.totalStake(TOKEN1), 300 * ALPHA, "total conserved");
    }

    /// @dev Short-credited moves require live balance reads; arithmetic sums over-ask the next hop.
    function test_Rebalance_FoldsDustAfterShortCreditedDrain() public {
        _setRegBlock(99, 300);
        _setValidators(99, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        _simulateAlphaDepositHotkey(alice, 99, 300 * ALPHA, hotkey1);
        _wrapHotkey(alice, 99, hotkey1);
        uint256 tokenId = vault.currentTokenId(99);

        _plantVaultStake(hotkey1, 99, 300 * ALPHA);
        _plantVaultStake(hotkey2, 99, DUST);
        _setValidators(99, _hotkeys(hotkey4), _weights(VaultMath.BPS_BASE));
        MockStaking(STAKING_PRECOMPILE).setMoveStakeRoundingLoss(1);

        vault.rebalance(99);

        assertEq(_getVaultStake(hotkey1, 99), 0, "drained validator emptied");
        assertEq(_getVaultStake(hotkey2, 99), 0, "dust folded off the second dropped validator");
        assertEq(_getVaultStake(hotkey4, 99), 300 * ALPHA + DUST - 2, "each of the two hops credits one RAO short");
        assertEq(lens.totalStake(tokenId), 300 * ALPHA + DUST - 2, "backing all sits on the current set");
        assertEq(_lastSeen(tokenId).length, 1, "nothing left to remember");
    }

    function test_Unwrap_SucceedsWhenPriceReadsZero() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, LARGE_POSITION);
        _setAlphaPriceReadsZero(NETUID1);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        assertEq(
            _userStakeAcrossHotkeys(alice, NETUID1), LARGE_POSITION, "zero oracle read falls through to the chain floor"
        );
    }

    function test_RevertWhen_ConsolidatingDustOnlyVault() public {
        _seedDustOnlyVault();

        vm.expectRevert(IAlphaVaultAbi.ConsolidationBelowFloor.selector);
        vault.rebalance(99);
    }

    function test_RevertWhen_UnwrappingDustOnlyVault() public {
        uint256 tokenId = _seedDustOnlyVault();

        uint256 shares = vault.balanceOf(alice, tokenId);
        vm.prank(alice);
        vm.expectRevert(IAlphaVaultAbi.ConsolidationBelowFloor.selector);
        vault.unwrap(tokenId, shares, _toSubstrate(alice), 0);
    }

    function test_UnwrapForTao_ExitsDustOnlyVault() public {
        uint256 tokenId = _seedDustOnlyVault();

        uint256 shares = vault.balanceOf(alice, tokenId);
        vm.prank(alice);
        vault.unwrapForTao(tokenId, shares, 0);

        // 39,999,999 RAO of alpha at 0.05 TAO, rounded down to the RAO.
        assertEq(alice.balance, 1_999_999 * VaultMath.TAO_NATIVE_QUANTUM, "full dust value recovered as TAO");
        assertEq(lens.totalStake(tokenId), 0, "nothing left behind");
    }

    function test_RevertWhen_ConsolidatingDustOnlyVaultAtZeroPrice() public {
        _seedDustOnlyVault();
        _setAlphaPriceReadsZero(99);

        _expectChainRefusal();
        vault.rebalance(99);
    }

    function test_Unwrap_GathersAcrossValidatorsForSingleDelivery() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 300 * ALPHA);
        _plantVaultStakes(NETUID1, 100 * ALPHA, 100 * ALPHA, 100 * ALPHA);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares * 60 / 100, _toSubstrate(alice), 0);

        // 1.8e20 * (3e11 + 1) / (3e20 + 1e9): more than any one 100-alpha slot holds.
        uint256 delivered = 180 * ALPHA;
        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), delivered, "delivery is exact");
        uint256 receivedOnGatherTarget = MockStaking(STAKING_PRECOMPILE).getStake(hotkey2, _toSubstrate(alice), NETUID1);
        assertEq(receivedOnGatherTarget, delivered, "the whole delivery arrives in one transfer");
        assertEq(lens.totalStake(TOKEN1), 120 * ALPHA, "only the delivered alpha left the vault");
    }

    function test_UnwrapEventReportsCappedAlphaPayoutAfterGatherRounding() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 300 * ALPHA);
        _plantVaultStakes(NETUID1, 100 * ALPHA, 100 * ALPHA, 100 * ALPHA);
        MockStaking(STAKING_PRECOMPILE).setMoveStakeRoundingLoss(1);

        uint256 expectedAlphaOut = 300 * ALPHA - 2;
        vm.expectEmit(true, true, false, true, address(vault));
        emit Unwrapped(alice, TOKEN1, shares, expectedAlphaOut);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        assertEq(_userStakeAcrossHotkeys(_toSubstrate(alice), NETUID1), expectedAlphaOut);
    }

    function test_RevertWhen_RollerMoveFails() public {
        _depositAndWrap(alice, NETUID1, 300 * ALPHA);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey4), _weights(3334, 3333, 3333));
        MockStaking(STAKING_PRECOMPILE).setMoveStakeReverts(true);

        _expectChainRefusal();
        vault.rebalance(NETUID1);
    }

    function test_Wrap_AcceptsDepositWhenPriceReadsZero() public {
        _setAlphaPriceReadsZero(NETUID1);
        uint256 shares = _depositAndWrap(alice, NETUID1, LARGE_POSITION);

        assertEq(shares, LARGE_POSITION * 1e9, "a first deposit mints 1e9 shares per RAO");
        assertEq(lens.totalStake(TOKEN1), LARGE_POSITION, "full deposit backs the shares");
    }

    function test_UnwrapForTao_TailWaitsWhenPriceReadsZero() public {
        _depositAndWrap(alice, NETUID1, 2 * LARGE_POSITION);
        _plantVaultStakes(NETUID1, LARGE_POSITION, 0, LARGE_POSITION);
        _setAlphaPriceReadsZero(NETUID1);

        // Supply 2e24 on 2e15 RAO makes each 1e9 shares worth one RAO: the burn takes 1e15 + 1e6 RAO.
        uint256 burn = (LARGE_POSITION + 1e6) * 1e9;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, burn, 0);

        // The full 1M-alpha slot sells at 5e-10 TAO/alpha; the 1e6-RAO partial tail cannot be priced.
        assertEq(alice.balance, 500_000 * VaultMath.TAO_NATIVE_QUANTUM, "only the full-drain slot sold");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "full drain sold");
        assertEq(_getVaultStake(hotkey3, NETUID1), LARGE_POSITION, "partial remainder left in the pool at price 0");
        // Refund: 1e6 * (1e24 - 1e15 + 1e9) / (1e15 - 1e6 + 1) = 1e15 shares, worth the waiting tail.
        assertEq(vault.balanceOf(alice, TOKEN1), 1e24, "the waiting tail came back as shares");
    }

    function test_UnwrapForTao_FullSlotExitWhenPriceReadsZero() public {
        _setAlphaPriceReadsZero(NETUID1);
        uint256 shares = _depositAndWrap(alice, NETUID1, LARGE_POSITION);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(alice.balance, 500_000 * VaultMath.TAO_NATIVE_QUANTUM, "1M alpha at 5e-10 TAO/alpha");
        assertEq(lens.totalStake(TOKEN1), 0);
    }
}

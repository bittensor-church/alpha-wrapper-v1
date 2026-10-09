// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import {
    InsufficientShares,
    NothingToUnwrap,
    SlippageExceeded,
    SlotMaskOutOfRange,
    WithdrawTooSmall,
    ZeroAmount
} from "src/VaultErrors.sol";
import { MockAlpha } from "./mocks/MockAlpha.sol";
import { CHAIN_MIN_STAKE } from "./mocks/MockStaking.sol";
import { ALPHA_PRECOMPILE } from "src/interfaces/IAlpha.sol";
import {
    QuoteProbeReceiver,
    RefundRejectingReceiver,
    ReentrantReceiver,
    RevertingReceiver
} from "./helpers/TaoRailReceivers.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Unless a test says otherwise, every layout sums to the deposits, so `k * 1e9` shares back `k`
///      RAO and a burn of `assets * 1e9` shares is worth exactly `assets`. Sales pay 0.05 TAO per alpha.
contract UnwrapForTaoTest is AlphaVaultTestBase {
    function _depositForAlice(uint256 amount) internal returns (uint256 shares) {
        shares = _depositAndWrap(alice, NETUID1, amount);
    }

    function _positionValue(address holder) internal view returns (uint256 alpha) {
        (alpha,) = lens.previewUnwrap(TOKEN1, vault.balanceOf(holder, TOKEN1));
    }

    /// @dev A 0.02-alpha slot ahead of the rest of `backing`. The returned burn asks for 0.03 alpha: the
    ///      slot drains whole and the 0.01-alpha tail is below the sale floor.
    function _plantSubFloorTail(uint256 backing) internal returns (uint256 burn) {
        _plantVaultStakes(NETUID1, 20_000_000, 0, backing - 20_000_000);
        return 3e16;
    }

    function _unwrapForTaoCall(uint256 shares) internal returns (bool ok, bytes memory ret) {
        vm.prank(alice);
        (ok, ret) =
            address(vault).call(abi.encodeWithSignature("unwrapForTao(uint256,uint256,uint256)", TOKEN1, shares, 0));
    }

    function test_UnwrapForTao_IgnoresDisabledTransfers() public {
        uint256 shares = _depositForAlice(100 * ALPHA);
        _plantVaultStakes(NETUID1, 100 * ALPHA, 0, 0);
        _setTransfersEnabled(NETUID1, false);

        vault.rebalance(NETUID1);
        assertEq(_getVaultStake(hotkey2, NETUID1), 33_330_000_000, "alignment still moves stake without transfers");
        uint256 before = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 2, 0);
        assertEq(alice.balance - before, 2.5e18, "and the TAO exit still pays for 50 alpha");
    }

    // --- Excluding slots the pool would refuse ------------------------------------------------

    /// @dev A refused quote or sale burns every unit of gas it is given; an excluded slot gets neither.
    function test_UnwrapForTao_LeavesExcludedSlotsUntouched() public {
        uint256 shares = _depositForAlice(100 * ALPHA);
        _plantVaultStakes(NETUID1, 60 * ALPHA, 10 * ALPHA, 30 * ALPHA);
        _setRemoveStakeRevertsFor(hotkey2, true);

        uint256 before = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, 70e18, 0, 1 << 1);

        assertEq(alice.balance - before, 3.5e18, "70 alpha sells from the other slots");
        assertEq(_getVaultStake(hotkey2, NETUID1), 10 * ALPHA, "the excluded slot is never touched");
        assertEq(vault.balanceOf(alice, TOKEN1), shares - 70e18, "with nothing to refund");
    }

    function test_UnwrapForTao_FullExitRefundsAnExcludedSlotAsShares() public {
        uint256 shares = _depositForAlice(100 * ALPHA);
        _plantVaultStakes(NETUID1, 60 * ALPHA, 0, 40 * ALPHA);

        uint256 before = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0, 1 << 2);

        assertEq(alice.balance - before, 3 * TAO, "the allowed 60 alpha sells");
        assertEq(_getVaultStake(hotkey3, NETUID1), 40 * ALPHA, "the excluded slot stays");
        assertEq(vault.balanceOf(alice, TOKEN1), 40e18, "and comes back at the empty-vault rate");
    }

    function test_UnwrapForTao_PartialRefundKeepsCoHoldersWhole() public {
        uint256 aliceShares = _depositForAlice(60 * ALPHA);
        _depositAndWrap(bob, NETUID1, 40 * ALPHA);
        _plantVaultStakes(NETUID1, 60 * ALPHA, 0, 40 * ALPHA);
        _donateToClone(vault.subnetClone(TOKEN1), 4 * TAO);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, aliceShares, 0, 1 << 0);

        assertEq(_positionValue(bob), 40 * ALPHA, "the co-holder's value is unchanged");
        assertEq(lens.claimableTaoOf(bob, TOKEN1), 1.6e18, "and so is the co-holder's 40% of the donation");
        assertEq(vault.balanceOf(alice, TOKEN1), 20e18, "the unsold 20 alpha came back as shares");
    }

    function test_RevertWhen_EveryFundedSlotIsExcluded() public {
        uint256 shares = _depositForAlice(100 * ALPHA);
        _plantVaultStakes(NETUID1, 60 * ALPHA, 0, 40 * ALPHA);

        vm.prank(alice);
        vm.expectRevert(WithdrawTooSmall.selector);
        vault.unwrapForTao(TOKEN1, shares / 2, 0, (1 << 0) | (1 << 2));
    }

    function test_RevertWhen_TheMaskNamesASlotTheRecordLacks() public {
        uint256 shares = _depositForAlice(100 * ALPHA);

        vm.prank(alice);
        vm.expectRevert(SlotMaskOutOfRange.selector);
        vault.unwrapForTao(TOKEN1, shares / 2, 0, 1 << 3);
    }

    function test_UnwrapForTao_ZeroMaskMatchesThePlainCall() public {
        uint256 shares = _depositForAlice(100 * ALPHA);
        _plantVaultStakes(NETUID1, 60 * ALPHA, 10 * ALPHA, 30 * ALPHA);
        uint256 before = alice.balance;
        uint256 state = vm.snapshotState();
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 2, 0);
        uint256 plainPayout = alice.balance - before;
        uint256 plainShares = vault.balanceOf(alice, TOKEN1);
        vm.revertToState(state);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 2, 0, 0);

        assertEq(alice.balance - before, plainPayout, "same payout");
        assertEq(vault.balanceOf(alice, TOKEN1), plainShares, "same shares");
    }

    function test_UnwrapForTao_MaskFollowsTheSlotToItsSuccessor() public {
        uint256 shares = _depositForAlice(90 * ALPHA);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        uint256 taoBefore = alice.balance;

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 2, 0, 1 << 0);

        assertEq(_getVaultStake(hotkey4, NETUID1), 30_006_000_000, "the key the slot resolved to is untouched");
        assertEq(_getVaultStake(hotkey2, NETUID1), 0, "the second slot drained");
        assertEq(_getVaultStake(hotkey3, NETUID1), 14_994_000_000, "the third covered the rest of the 45 alpha");
        assertEq(alice.balance - taoBefore, 2.25e18, "the whole sale came from the other slots");
    }

    function test_UnwrapForTao_MaskFollowsTheRecordOrderAtExecution() public {
        uint256 shares = _depositForAlice(90 * ALPHA);
        _setValidators(
            NETUID1, _hotkeys(hotkey2, hotkey1, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
        vault.rebalance(NETUID1);
        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey2, "the record now leads with hotkey2");

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 4, 0, 1 << 0);

        assertEq(_getVaultStake(hotkey2, NETUID1), 29_997_000_000, "bit 0 excludes whichever slot comes first now");
    }

    function testFuzz_UnwrapForTao_SellsOnlyTheAllowedSlots(uint256 mask, uint256 burnBps) public {
        uint256 shares = _depositForAlice(100 * ALPHA);
        _plantVaultStakes(NETUID1, 50 * ALPHA, 30 * ALPHA, 20 * ALPHA);
        mask = bound(mask, 0, 6);
        uint256 burn = shares * bound(burnBps, 1000, 9000) / BPS_BASE;
        bytes32[3] memory keys = [hotkey1, hotkey2, hotkey3];
        uint256[3] memory before = [50 * ALPHA, 30 * ALPHA, 20 * ALPHA];
        uint256 taoBefore = alice.balance;

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, burn, 0, mask);

        uint256 sold;
        for (uint256 i; i < 3; ++i) {
            uint256 balance = _getVaultStake(keys[i], NETUID1);
            if ((mask >> i) & 1 == 1) assertEq(balance, before[i], "an excluded slot moved");
            sold += before[i] - balance;
        }
        // Full drains and capped partials are multiples of 20 RAO, so only the last chunk rounds.
        assertEq(alice.balance - taoBefore, sold / 20 * 1e9, "the payout is 0.05 TAO per alpha sold");
        assertGe(vault.balanceOf(alice, TOKEN1), shares - burn, "unsold entitlement came back as shares");
    }

    function test_BurnAllShares_PaysFullAlphaAsTao() public {
        uint256 shares = _depositForAlice(100 * ALPHA);
        uint256 aliceBalanceBefore = alice.balance;

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(vault.balanceOf(alice, TOKEN1), 0);
        assertEq(alice.balance - aliceBalanceBefore, 5 * TAO);
        assertEq(lens.totalStake(TOKEN1), 0);
    }

    // Exact backing prices a full-supply burn, so the whole position drains under the full-unstake exemption.
    function test_FullBurnAfterEmissionGrowth_DrainsSubFloorDust() public {
        uint256 supply = _depositForAlice(ALPHA);
        _plantVaultStakes(NETUID1, 1.2e9, 0, 0);
        _setAlphaPrice(NETUID1, 0.001e18);
        uint256 aliceBalanceBefore = alice.balance;

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, supply, 1);

        assertEq(vault.balanceOf(alice, TOKEN1), 0);
        assertEq(lens.totalStake(TOKEN1), 0);
        assertEq(alice.balance - aliceBalanceBefore, 1.2e15, "1.2 alpha at 0.001 TAO per alpha, below the floor");
    }

    function testFuzz_FullBurn_DrainsWholePosition(uint256 growth, uint256 priceRao) public {
        growth = bound(growth, 0, 1000 * ALPHA);
        uint256 priceE18 = _wholeRaoPrice(priceRao);
        uint256 supply = _depositForAlice(ALPHA);
        uint256 total = _plantVaultStakes(NETUID1, ALPHA + growth, 0, 0);
        _setAlphaPrice(NETUID1, priceE18);
        uint256 aliceBalanceBefore = alice.balance;

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, supply, 1);

        assertEq(vault.balanceOf(alice, TOKEN1), 0);
        assertEq(lens.totalStake(TOKEN1), 0);
        assertEq(alice.balance - aliceBalanceBefore, total * priceE18 / 1e18 * 1e9, "one sale of the whole slot");
    }

    // This linear-price mock checks alpha accounting, not real-pool price impact on remaining holders.
    function testFuzz_UnwrapForTao_LeavesOnlyThresholdPinnedDust(
        uint256 deposit,
        uint256 a,
        uint256 b,
        uint256 shareBps,
        uint256 priceRao
    ) public {
        deposit = bound(deposit, 1, 100_000) * ALPHA;
        a = bound(a, 0, deposit);
        b = bound(b, 0, deposit - a);
        shareBps = bound(shareBps, 1, BPS_BASE);
        uint256 priceE18 = _wholeRaoPrice(priceRao);
        uint256 supply = _depositForAlice(deposit);
        _plantVaultStakes(NETUID1, a, b, deposit - a - b);
        _setAlphaPrice(NETUID1, priceE18);
        uint256 shares = supply * shareBps / BPS_BASE;
        uint256 requested = shares / 1e9;
        // Leftovers sit below the dust threshold or the floor, plus a few RAO of price rounding.
        uint256 unsellableTailBound = DUST_THRESHOLD + CHAIN_MIN_STAKE + 5;
        uint256 balanceBefore = alice.balance;

        (bool ok, bytes memory ret) = _unwrapForTaoCall(shares);

        if (!ok) {
            assertEq(bytes4(ret), WithdrawTooSmall.selector, "only the nothing-sold revert may fire");
            assertLt(
                requested * priceE18 / 1e18,
                unsellableTailBound,
                "nothing sold only when the whole request is an unsellable tail"
            );
            return;
        }
        uint256 sold = deposit - lens.totalStake(TOKEN1);
        uint256 paid = alice.balance - balanceBefore;
        // At most one sale per slot, each rounding down to whole RAO.
        assertApproxEqAbs(paid, sold * priceE18 / 1e9, 3e9, "payout is the sold value at the price");
        assertLe(paid, requested * priceE18 / 1e9, "payout never exceeds the request's value");
        assertLt((requested - sold) * priceE18 / 1e18, unsellableTailBound, "any shortfall is threshold-pinned dust");
    }

    function test_PartialBurn_PaysProportionalTaoAcrossMultipleHotkeys() public {
        uint256 shares = _depositForAlice(100 * ALPHA);
        _plantVaultStakes(NETUID1, 60 * ALPHA, 40 * ALPHA, 0);
        uint256 balanceBefore = alice.balance;

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 2, 0);

        assertEq(alice.balance - balanceBefore, 2.5e18, "40 alpha drained plus 10 alpha partial");
    }

    function test_DrainsAlphaUnderHotkeyRotatedOutOfCurrentValidatorSet() public {
        uint256 shares = _depositForAlice(100 * ALPHA);
        _setValidators(NETUID1, _hotkeys(hotkey4), _weights(BPS_BASE));

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, 5 * TAO);
    }

    function test_UnwrapForTao_PaysWhatThePoolRealizes() public {
        uint256 shares = _depositForAlice(100 * ALPHA);
        _setRemoveStakeRate(1, 25);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, 4 * TAO, "100 alpha realized at 0.04 TAO per alpha");
    }

    function test_MinTaoOutEqualToRealizedAmount_DoesNotRevert() public {
        uint256 shares = _depositForAlice(100 * ALPHA);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 5 * TAO);

        assertEq(alice.balance - balanceBefore, 5 * TAO);
    }

    function test_RevertWhen_SharesIsZero() public {
        _depositForAlice(100 * ALPHA);
        vm.prank(alice);
        vm.expectRevert(ZeroAmount.selector);
        vault.unwrapForTao(TOKEN1, 0, 0);
    }

    function test_RevertWhen_SharesExceedCallerBalance() public {
        uint256 shares = _depositForAlice(100 * ALPHA);
        vm.prank(alice);
        vm.expectRevert(InsufficientShares.selector);
        vault.unwrapForTao(TOKEN1, shares + 1, 0);
    }

    function test_RevertWhen_SubnetDissolved() public {
        uint256 shares = _depositForAlice(100 * ALPHA);
        _simulateNewNetworkRegistered(TOKEN1, 5 * TAO);

        vm.prank(alice);
        vm.expectRevert(NothingToUnwrap.selector);
        vault.unwrapForTao(TOKEN1, shares, 0);
    }

    function test_RevertWhen_ProRataAssetsRoundsToZero() public {
        _depositForAlice(ALPHA);

        vm.prank(alice);
        vm.expectRevert(ZeroAmount.selector);
        vault.unwrapForTao(TOKEN1, 1, 0);
    }

    function test_RevertWhen_RealizedTaoBelowMinTaoOut() public {
        uint256 shares = _depositForAlice(100 * ALPHA);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, 5 * TAO));
        vault.unwrapForTao(TOKEN1, shares, 5 * TAO + 1);
    }

    function test_RevertWhen_AllSellsFail() public {
        uint256 shares = _depositForAlice(100 * ALPHA);
        _setRemoveStakeReverts(true);

        vm.prank(alice);
        _expectChainRefusal();
        vault.unwrapForTao(TOKEN1, shares, 0);
    }

    function test_RevertWhen_OneFullSliceSellFails() public {
        uint256 shares = _depositForAlice(100 * ALPHA);
        _setRemoveStakeRevertsFor(hotkey2, true);

        vm.prank(alice);
        _expectChainRefusal();
        vault.unwrapForTao(TOKEN1, shares, 0);
    }

    function test_RevertWhen_AboveFloorPartialSellFails() public {
        uint256 shares = _depositForAlice(100 * ALPHA);
        _plantVaultStakes(NETUID1, 60 * ALPHA, 40 * ALPHA, 0);
        _setRemoveStakeRevertsFor(hotkey1, true);

        // The second slot drains; the 10-alpha remainder is a partial sale from the refusing first slot.
        vm.prank(alice);
        _expectChainRefusal();
        vault.unwrapForTao(TOKEN1, shares / 2, 0);
    }

    function test_DonationToClonePriorToCall_DoesNotInflateTaoOut() public {
        uint256 shares = _depositForAlice(100 * ALPHA);
        address clone = vault.subnetClone(TOKEN1);
        _donateToClone(clone, 1 * TAO);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, 5 * TAO);
        assertEq(clone.balance, 1 * TAO);
    }

    function test_RevertWhen_CallerReceiverRevertsOnReceive() public {
        RevertingReceiver receiver = new RevertingReceiver();
        uint256 shares = _depositAndWrap(address(receiver), NETUID1, 100 * ALPHA);

        vm.prank(address(receiver));
        vm.expectRevert(bytes("nope"));
        vault.unwrapForTao(TOKEN1, shares, 0);
    }

    function test_ReentrantUnwrapForTaoIsRejectedByGuard() public {
        ReentrantReceiver receiver = new ReentrantReceiver();
        uint256 shares = _depositAndWrap(address(receiver), NETUID1, 100 * ALPHA);
        receiver.arm(
            address(vault), abi.encodeWithSignature("unwrapForTao(uint256,uint256,uint256)", TOKEN1, shares, 0)
        );

        vm.prank(address(receiver));
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(receiver.reentryError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(vault.balanceOf(address(receiver), TOKEN1), 0);
    }

    function _exitThroughProbe(uint256 burnBps, uint256 excludedSlots)
        internal
        returns (QuoteProbeReceiver probe, uint256 kept)
    {
        probe = new QuoteProbeReceiver(vault, lens);
        uint256 probeShares = _depositAndWrap(address(probe), NETUID1, 90 * ALPHA);
        uint256 bobShares = _depositAndWrap(bob, NETUID1, 10 * ALPHA);
        _plantVaultStakes(NETUID1, 5 * ALPHA, 50 * ALPHA, 45 * ALPHA);
        _donateToClone(vault.subnetClone(TOKEN1), 4 * TAO);
        probe.watch(TOKEN1, bob, bobShares);
        uint256 burn = probeShares * burnBps / BPS_BASE;
        kept = probeShares - burn;

        vm.prank(address(probe));
        vault.unwrapForTao(TOKEN1, burn, 0, excludedSlots);
    }

    function _assertProbeSawSettledState(QuoteProbeReceiver probe, uint256 kept) internal view {
        (uint256 bobQuote,) = lens.previewUnwrap(TOKEN1, vault.balanceOf(bob, TOKEN1));
        uint256 bobClaim = lens.claimableTaoOf(bob, TOKEN1);
        uint256 headroom = vault.subnetClone(TOKEN1).balance - vault.taoLiability(TOKEN1);
        assertEq(probe.payoutQuote(), bobQuote, "the payout callback quotes the co-holder at the settled value");
        assertEq(probe.payoutClaim(), bobClaim, "and sees the settled TAO claim");
        assertEq(probe.payoutSupply(), vault.totalSupply(TOKEN1), "over the settled supply");
        assertEq(probe.payoutHeadroom(), headroom, "with the settled unreserved TAO");
        bool refunded = vault.balanceOf(address(probe), TOKEN1) > kept;
        assertEq(probe.refundSeen(), refunded, "the refund hook fires exactly when shares come back");
        if (refunded) {
            assertEq(probe.refundQuote(), bobQuote, "the refund hook quotes the co-holder at the settled value");
            assertEq(probe.refundClaim(), bobClaim, "and sees the settled TAO claim");
            assertEq(probe.refundHeadroom(), headroom, "with the settled unreserved TAO");
        }
    }

    function testFuzz_PayoutCallback_SeesSettledQuotes(uint256 burnBps, uint256 excludedSlots) public {
        burnBps = bound(burnBps, 1000, BPS_BASE);
        excludedSlots = bound(excludedSlots, 0, (1 << 3) - 2);

        (QuoteProbeReceiver probe, uint256 kept) = _exitThroughProbe(burnBps, excludedSlots);
        _assertProbeSawSettledState(probe, kept);
    }

    function test_TransferInsideRefundHook_KeepsProceedsOutOfTheClaimIndex() public {
        QuoteProbeReceiver probe = new QuoteProbeReceiver(vault, lens);
        _depositAndWrap(address(probe), NETUID1, 90 * ALPHA);
        _donateToClone(vault.subnetClone(TOKEN1), 4 * TAO);
        uint256 bobShares = _depositAndWrap(bob, NETUID1, 10 * ALPHA);
        _plantVaultStakes(NETUID1, 5 * ALPHA, 50 * ALPHA, 45 * ALPHA);
        uint256 indexBefore = vault.cumulativeTaoPerShare(TOKEN1);
        uint256 liabilityBefore = vault.taoLiability(TOKEN1);
        // The sole holder earned the 4 TAO donation less the index's floor rounding.
        uint256 probeClaim = lens.claimableTaoOf(address(probe), TOKEN1);
        assertEq(probeClaim, 3_999_999_999e9);
        probe.watch(TOKEN1, bob, bobShares);
        probe.forwardRefundsTo(alice);

        // A burn worth 80.001 alpha sells only the 5-alpha first slot and refunds the other 75.001 alpha.
        vm.prank(address(probe));
        vault.unwrapForTao(TOKEN1, 80.001e18, 0, (1 << 1) | (1 << 2));

        assertTrue(probe.refundSeen(), "the excluded slots came back as a refund");
        assertEq(vault.balanceOf(address(probe), TOKEN1), 0, "the hook forwarded every share");
        assertEq(vault.balanceOf(alice, TOKEN1), 85e18, "the 9.999e18 kept shares and the 75.001e18 refund");
        assertEq(vault.cumulativeTaoPerShare(TOKEN1), indexBefore, "the sale proceeds never entered the index");
        assertEq(vault.taoLiability(TOKEN1), liabilityBefore, "and the reserve was released in full");
        assertEq(lens.claimableTaoOf(address(probe), TOKEN1), probeClaim, "the historical claim stays with its owner");
        assertEq(lens.claimableTaoOf(alice, TOKEN1), 0, "the forwarded shares carry no claim");
        assertEq(lens.claimableTaoOf(bob, TOKEN1), 0, "and the co-holder earned nothing from the exit");
        assertEq(vault.subnetClone(TOKEN1).balance, 4 * TAO, "only the donation stays in the clone");
    }

    function test_MultipleUsers_ProRataConsistentAcrossSequentialUnwraps() public {
        uint256 aliceShares = _depositForAlice(100 * ALPHA);
        uint256 bobShares = _depositAndWrap(bob, NETUID1, 100 * ALPHA);

        uint256 aliceBalanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, aliceShares, 0);
        assertEq(alice.balance - aliceBalanceBefore, 5 * TAO);

        uint256 bobBalanceBefore = bob.balance;
        vm.prank(bob);
        vault.unwrapForTao(TOKEN1, bobShares, 0);
        assertEq(bob.balance - bobBalanceBefore, 5 * TAO);
    }

    function test_AlphaRailUnwrapRemainsWorkingAfterTaoUnwrapByDifferentHolder() public {
        uint256 aliceShares = _depositForAlice(100 * ALPHA);
        uint256 bobShares = _depositAndWrap(bob, NETUID1, 100 * ALPHA);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, aliceShares, 0);

        bytes32 bobDest = keccak256("bobDest");
        vm.prank(bob);
        vault.unwrap(TOKEN1, bobShares, bobDest, 0);

        assertEq(vault.balanceOf(bob, TOKEN1), 0);
        assertEq(_userStakeAcrossHotkeys(bobDest, NETUID1), 100 * ALPHA);
    }

    function test_UnwrapForTao_PaysOutAccruedEmissionsAboveOriginalDeposit() public {
        uint256 shares = _depositForAlice(100 * ALPHA);
        _plantVaultStakes(NETUID1, 60 * ALPHA, 40 * ALPHA, 10 * ALPHA);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, 5.5e18, "all 110 alpha at 0.05 TAO per alpha");
    }

    function test_UnwrapForTao_EmitsUnwrappedForTaoEvent() public {
        uint256 shares = _depositForAlice(100 * ALPHA);

        vm.expectEmit(true, true, false, true, address(vault));
        emit UnwrappedForTao(alice, TOKEN1, shares, 0, 100 * ALPHA, 5 * TAO);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);
    }

    function test_PartialBurn_LeavesUnneededHotkeysUntouched() public {
        _depositForAlice(100 * ALPHA);
        _plantVaultStakes(NETUID1, 60 * ALPHA, 40 * ALPHA, 0);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, 30e18, 0);

        assertEq(alice.balance - balanceBefore, 1.5e18);
        assertEq(_getVaultStake(hotkey2, NETUID1), 40 * ALPHA);
        assertEq(_getVaultStake(hotkey1, NETUID1), 30 * ALPHA);
    }

    function test_RebalanceWorksAfterPartialUnwrapForTao() public {
        uint256 shares = _depositForAlice(100 * ALPHA);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 2, 0);

        vault.rebalance(NETUID1);

        // 50 alpha by weight; the last 0.005-alpha correction is below the floor and stays put.
        assertEq(lens.totalStake(TOKEN1), 50 * ALPHA);
        assertEq(_getVaultStake(hotkey1, NETUID1), 16_665_000_000);
        assertEq(_getVaultStake(hotkey2, NETUID1), 16_670_000_000);
        assertEq(_getVaultStake(hotkey3, NETUID1), 16_665_000_000);
    }

    function test_SubFloorFullDrain_SoldViaFullUnstakeExemption() public {
        _depositForAlice(100 * ALPHA);
        _plantVaultStakes(NETUID1, 20_000_000, 99_980_000_000, 0);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, 1.02e18, 0);

        assertEq(alice.balance - balanceBefore, 5.1e16, "the 0.02-alpha drain plus a 1-alpha partial");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "sub-floor full drain sold via the exemption");
        assertEq(_getVaultStake(hotkey2, NETUID1), 98_980_000_000);
    }

    function test_TailOnExactValidatorBoundary_SoldAsFullDrain() public {
        _depositForAlice(100 * ALPHA);
        _plantVaultStakes(NETUID1, 60 * ALPHA, 40 * ALPHA, 0);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, 60e18, 3 * TAO);

        assertEq(alice.balance - balanceBefore, 3 * TAO);
        assertEq(_getVaultStake(hotkey1, NETUID1), 0);
        assertEq(_getVaultStake(hotkey2, NETUID1), 40 * ALPHA, "later validator untouched");
    }

    function test_SubFloorFinalSlice_RefundsSharesBackingTheUnsoldDust() public {
        _depositForAlice(100 * ALPHA);
        uint256 burn = _plantSubFloorTail(100 * ALPHA);
        uint256 balanceBefore = alice.balance;

        vm.expectEmit(true, true, false, true, address(vault));
        emit UnwrappedForTao(alice, TOKEN1, burn, 1e16, 20_000_000, 1e15);
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, burn, 0);

        assertEq(alice.balance - balanceBefore, 1e15, "delivered the exempt full drain, skipped the dust");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "full drain sold");
        assertEq(_getVaultStake(hotkey3, NETUID1), 99_980_000_000, "the sub-floor tail stays staked");
        assertEq(lens.totalStake(TOKEN1), 99_980_000_000, "only the delivered alpha left the vault");
        assertEq(vault.balanceOf(alice, TOKEN1), 99_980_000_000e9, "the 0.01-alpha tail came back as shares");
    }

    function test_UnsoldRemainder_LeavesOtherHolderWhole() public {
        _depositForAlice(100 * ALPHA);
        _depositAndWrap(bob, NETUID1, 100 * ALPHA);
        uint256 burn = _plantSubFloorTail(200 * ALPHA);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, burn, 0);

        assertEq(_positionValue(bob), 100 * ALPHA, "the unsold dust never reached the other holder");
        assertEq(vault.balanceOf(alice, TOKEN1), 99_980_000_000e9, "the caller kept every unsold RAO");
    }

    // Linear-price mock only: real TAO sales can lower the pool price for remaining holders.
    function testFuzz_UnsoldRemainder_TransfersNothingToOtherHolders(
        uint256 a,
        uint256 b,
        uint256 c,
        uint256 shareBps,
        uint256 priceRao,
        uint256 sellCap
    ) public {
        a = bound(a, 0, MAX_SUBNET_ALPHA / 3);
        b = bound(b, 0, MAX_SUBNET_ALPHA / 3);
        c = bound(c, 10 * ALPHA, MAX_SUBNET_ALPHA / 3);
        shareBps = bound(shareBps, 1, BPS_BASE);
        sellCap = bound(sellCap, 0, MAX_SUBNET_ALPHA / 3);
        uint256 aliceShares = _depositForAlice(30 * ALPHA);
        _depositAndWrap(bob, NETUID1, 30 * ALPHA);
        _plantVaultStakes(NETUID1, a, b, c);
        _setAlphaPrice(NETUID1, _wholeRaoPrice(priceRao));
        _setRemoveStakeCap(sellCap);
        uint256 bobValueBefore = _positionValue(bob);

        (bool ok, bytes memory ret) = _unwrapForTaoCall(aliceShares * shareBps / BPS_BASE);

        if (!ok) {
            assertEq(bytes4(ret), WithdrawTooSmall.selector, "only the nothing-sold revert may fire");
            return;
        }
        // Share and asset rounding moves the stayer's quote by at most a RAO each way.
        assertApproxEqAbs(_positionValue(bob), bobValueBefore, 2, "an exit never enriches the holders who stayed");
    }

    function test_UnsoldRemainderAfterDonation_LeavesClaimableTaoIntact() public {
        _depositForAlice(100 * ALPHA);
        _depositAndWrap(bob, NETUID1, 100 * ALPHA);
        address clone = vault.subnetClone(TOKEN1);
        _donateToClone(clone, 8 * TAO);
        uint256 burn = _plantSubFloorTail(200 * ALPHA);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, burn, 0);

        assertEq(lens.claimableTaoOf(alice, TOKEN1), 4 * TAO, "half the donation is still owed to the caller");
        assertEq(lens.claimableTaoOf(bob, TOKEN1), 4 * TAO, "and half to the other holder");
        assertEq(vault.taoLiability(TOKEN1), 8 * TAO, "the reserve covers both claims");
        assertEq(clone.balance, 8 * TAO, "and the clone still holds it");
    }

    function test_RevertWhen_RefundRejectedByCallerHook() public {
        RefundRejectingReceiver receiver = new RefundRejectingReceiver();
        _depositAndWrap(address(receiver), NETUID1, 100 * ALPHA);
        uint256 burn = _plantSubFloorTail(100 * ALPHA);
        receiver.rejectMints();

        vm.prank(address(receiver));
        vm.expectRevert(bytes("no mints"));
        vault.unwrapForTao(TOKEN1, burn, 0);
    }

    function test_SwapStoppedShortOnFullBurn_RefundsTheReturnedAlpha() public {
        uint256 shares = _depositForAlice(100 * ALPHA);
        _plantVaultStakes(NETUID1, 100 * ALPHA, 0, 0);
        _setRemoveStakeCap(60 * ALPHA);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, 3 * TAO, "paid only for the 60 alpha the chain swapped");
        assertEq(lens.totalStake(TOKEN1), 40 * ALPHA, "the chain kept the unswapped alpha staked");
        assertEq(vault.balanceOf(alice, TOKEN1), 40e18, "the caller still owns it, not the vault");
    }

    // At the empty-vault rate, appreciated unsold backing can mint more shares than the exit burned.
    function test_FullBurnShortFillAfterAppreciation_RefundsMoreThanTheBurn() public {
        uint256 shares = _depositForAlice(100 * ALPHA);
        _plantVaultStakes(NETUID1, 300 * ALPHA, 0, 0);
        _setRemoveStakeCap(60 * ALPHA);

        uint256 balanceBefore = alice.balance;
        vm.expectEmit(true, true, false, true, address(vault));
        emit UnwrappedForTao(alice, TOKEN1, shares, 240e18, 60 * ALPHA, 3 * TAO);
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, 3 * TAO, "paid for the alpha the chain swapped");
        assertEq(vault.balanceOf(alice, TOKEN1), 240e18, "the 240e18 refund outnumbers the 100e18 burn");
    }

    function testFuzz_FullBurnShortFill_RefundsWhateverStaysStaked(uint256 growth, uint256 fill) public {
        _depositForAlice(100 * ALPHA);
        uint256 total = bound(growth, 100 * ALPHA, 1000 * ALPHA);
        _plantVaultStakes(NETUID1, total, 0, 0);
        uint256 sold = bound(fill, ALPHA, total - ALPHA);
        _setRemoveStakeCap(sold);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(alice.balance - balanceBefore, sold / 20 * 1e9, "paid 0.05 TAO per alpha the chain swapped");
        uint256 refund = vault.balanceOf(alice, TOKEN1);
        assertEq(refund, (total - sold) * 1e9, "the unsold alpha is refunded at the empty-vault rate");
        assertEq(vault.totalSupply(TOKEN1), refund, "the refund is the whole supply");
    }

    function test_FullBurnWithChainRoundingDust_LeavesNoPosition() public {
        uint256 shares = _depositForAlice(100 * ALPHA);
        _plantVaultStakes(NETUID1, 100 * ALPHA, 0, 0);
        // Disable forced sweeping so chain-rounding residue remains staked.
        _setDustThreshold(0);
        _setRemoveStakeCap(100 * ALPHA - 1);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(lens.totalStake(TOKEN1), 1, "the chain kept a RAO back");
        assertEq(vault.balanceOf(alice, TOKEN1), 0, "sub-floor dust mints no position");
        assertEq(vault.totalSupply(TOKEN1), 0, "the position is fully retired");
    }

    function test_PartialBurnWithChainRoundingDust_RefundsTheRemainder() public {
        _depositForAlice(100 * ALPHA);
        _plantVaultStakes(NETUID1, 100 * ALPHA, 0, 0);
        _setRemoveStakeCap(50 * ALPHA - 1);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, 50e18, 0);

        // 1 * (5e19 + 1e9) / (5e10 + 1) shares for the RAO the chain kept.
        assertEq(vault.balanceOf(alice, TOKEN1), 50e18 + 1e9, "the RAO the chain kept came back");
    }

    function test_FullySoldRequest_BurnsEveryRequestedShare() public {
        _depositForAlice(100 * ALPHA);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, 50e18, 0);

        assertEq(vault.balanceOf(alice, TOKEN1), 50e18, "a fully sold request refunds nothing");
    }

    function test_RevertWhen_UnsoldRemainderBreaksMinTaoOut() public {
        _depositForAlice(100 * ALPHA);
        uint256 burn = _plantSubFloorTail(100 * ALPHA);

        // The 0.03-alpha request is worth 0.0015 TAO, but only the 0.02-alpha drain sells.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, 1e15));
        vault.unwrapForTao(TOKEN1, burn, 1.5e15);
    }

    function test_DustPosition_TopUpEnablesFullValueExit() public {
        uint256 shares = _depositForAlice(100 * ALPHA);
        vm.prank(alice);
        vault.safeTransferFrom(alice, bob, TOKEN1, shares - 1e16, "");

        // The 1-alpha top-up mints 1e18 shares beside the 0.01-alpha dust.
        _depositAndWrap(alice, NETUID1, ALPHA);
        uint256 balanceBefore = alice.balance;

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, 1.01e18, 5.05e16);

        assertEq(alice.balance - balanceBefore, 5.05e16, "the dust sells alongside the top-up");
        assertEq(vault.balanceOf(alice, TOKEN1), 0, "entire position exited");
    }

    function test_RevertWhen_PartialSellBelowSimFloor() public {
        _depositForAlice(100 * ALPHA);
        _setRemoveStakeRate(499, 10_000);

        // 0.04 alpha clears the floor at the 0.05 spot price, but the pool quotes 0.001996 TAO.
        vm.prank(alice);
        vm.expectRevert(WithdrawTooSmall.selector);
        vault.unwrapForTao(TOKEN1, 4e16, 0);
    }

    function test_PartialSell_ShrinksToLeaveSweepSafeLeftover() public {
        _depositForAlice(ALPHA);
        _plantVaultStakes(NETUID1, ALPHA, 0, 0);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, 9e17, 0);

        // The slot keeps ceil((2e7 + 1) * 1e18 / 5e16) = 400,000,020 RAO; 599,999,980 sell.
        assertEq(alice.balance - balanceBefore, 29_999_999e9, "paid only the sweep-safe chunk");
        assertEq(_getVaultStake(hotkey1, NETUID1), 400_000_020, "slot keeps the sweep-safe minimum");
        assertEq(lens.totalStake(TOKEN1), 400_000_020, "nothing was force-swept");
        assertEq(vault.balanceOf(alice, TOKEN1), 400_000_020e9, "the unsold 300,000,020 RAO came back as shares");
    }

    function test_RevertWhen_PartialSellWouldStrandSweepableDust() public {
        _depositForAlice(400_000_000);
        _plantVaultStakes(NETUID1, 400_000_000, 0, 0);

        // A 0.4-alpha slot cannot keep the 400,000,020-RAO sweep-safe leftover.
        vm.prank(alice);
        vm.expectRevert(WithdrawTooSmall.selector);
        vault.unwrapForTao(TOKEN1, 2e17, 0);
    }

    function testFuzz_PartialSell_NeverLeavesSweepableRemainder(uint256 balance, uint256 assets, uint256 priceRao)
        public
    {
        balance = bound(balance, 40_000_000, 100_000 * ALPHA);
        uint256 priceE18 = _wholeRaoPrice(priceRao);
        _depositForAlice(balance);
        _plantVaultStakes(NETUID1, balance, 0, 0);
        _setAlphaPrice(NETUID1, priceE18);
        assets = bound(assets, 1, balance - 1);
        uint256 balanceBefore = alice.balance;

        (bool ok, bytes memory reason) = _unwrapForTaoCall(assets * 1e9);

        if (!ok) {
            assertEq(bytes4(reason), WithdrawTooSmall.selector, "only an unsellable partial request may fail");
            return;
        }
        uint256 slotAfter = _getVaultStake(hotkey1, NETUID1);
        assertGe(slotAfter * priceE18 / 1e18, DUST_THRESHOLD, "the slot keeps a sweep-safe balance");
        assertLe(alice.balance - balanceBefore, assets * priceE18 / 1e9, "no value beyond the request");
    }

    function test_ExactFitLaterSlot_PreferredOverEarlierPartial() public {
        _depositForAlice(100 * ALPHA);
        _plantVaultStakes(NETUID1, 60 * ALPHA, 10 * ALPHA, 30 * ALPHA);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, 10e18, 0);

        assertEq(alice.balance - balanceBefore, 0.5e18, "full delivery from the exact-fit slot");
        assertEq(_getVaultStake(hotkey1, NETUID1), 60 * ALPHA, "earlier slot untouched");
        assertEq(_getVaultStake(hotkey2, NETUID1), 0, "exact-fit slot drained via the exemption");
    }

    function test_FullDrainThenPartialSale_UsesUpdatedBalances() public {
        _depositForAlice(100 * ALPHA);
        _plantVaultStakes(NETUID1, 10 * ALPHA, 50 * ALPHA, 40 * ALPHA);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, 30e18, 0);

        assertEq(alice.balance - balanceBefore, 1.5e18, "full drain plus partial sale pays the 30 alpha");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "first slot stays drained");
        assertEq(_getVaultStake(hotkey2, NETUID1), 30 * ALPHA, "only the outstanding entitlement is sold");
        assertEq(_getVaultStake(hotkey3, NETUID1), 40 * ALPHA);
    }

    function test_PartialSellBelowSpotFloor_NeverReachesSimSwap() public {
        _depositForAlice(100 * ALPHA);
        MockAlpha(ALPHA_PRECOMPILE).setSimSwapReverts(true);

        // 0.01 alpha is worth 0.0005 TAO.
        vm.prank(alice);
        vm.expectRevert(WithdrawTooSmall.selector);
        vault.unwrapForTao(TOKEN1, 1e16, 0);
    }

    function test_PartialSellWithPriceImpact_SkipsWhenLeftoverWouldSweepPostSale() public {
        _depositForAlice(ALPHA);
        _plantVaultStakes(NETUID1, ALPHA, 0, 0);
        // Marginal leftover quote: 4.4e7 - 2.5e7 = 1.9e7 RAO, below the 2e7 sweep threshold.
        MockAlpha(ALPHA_PRECOMPILE).setSimSwapQuote(uint64(ALPHA), 44_000_000);

        vm.prank(alice);
        vm.expectRevert(WithdrawTooSmall.selector);
        vault.unwrapForTao(TOKEN1, 5e17, 0);
    }

    receive() external payable { }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { VaultMath } from "src/libraries/VaultMath.sol";
import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { ClaimBelowNativePrecision, SupplyCapExceeded, ZeroAddress, ZeroAmount } from "src/VaultErrors.sol";
import { ClaimDuringTransferReceiver, RevertingReceiver, ReentrantReceiver } from "./helpers/TaoRailReceivers.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev A first deposit of 1,000 alpha mints 1e21 shares, so a gift of g wei moves the index by exactly g * 1e15.
contract ClaimableTaoTest is AlphaVaultTestBase {
    uint256 internal constant DEPOSIT = 1_000 * ALPHA;

    function _donateToTokenClone(uint256 tokenId, uint256 amount) internal {
        _donateToClone(vault.subnetClone(tokenId), amount);
    }

    function _claimAs(address user) internal {
        vm.prank(user);
        vault.claimTao(TOKEN1, payable(user));
    }

    function _touch(address user, uint256 tokenId) internal {
        vm.prank(user);
        vault.safeTransferFrom(user, user, tokenId, 0, "");
    }

    function _exitCompletely(address user, uint256 tokenId) internal {
        uint256 shares = vault.balanceOf(user, tokenId);
        vm.prank(user);
        vault.unwrap(tokenId, shares, _toSubstrate(user), 0);
    }

    /// @dev The chain sells every clone position into TAO; the record writes the alpha off.
    function _sweepAndWriteOff(uint256 proceeds) internal {
        _simulateTaoAwardedOnDissolution(TOKEN1, proceeds);
        _catchRecordUpFor(TOKEN1);
    }

    function test_DonationBeforeSecondWrap_AccruesOnlyToFirstHolder() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        _donateToTokenClone(TOKEN1, 5 * TAO);

        _depositAndWrap(bob, NETUID1, DEPOSIT);

        assertEq(lens.claimableTaoOf(bob, TOKEN1), 0);
        assertEq(lens.claimableTaoOf(alice, TOKEN1), 5 * TAO);
        assertEq(vault.taoLiability(TOKEN1), 5 * TAO);
    }

    function test_TransferAfterDonation_SenderKeepsEarnedEntitlement() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, DEPOSIT);
        _donateToTokenClone(TOKEN1, 3 * TAO);

        vm.prank(alice);
        vault.safeTransferFrom(alice, bob, TOKEN1, shares, "");

        assertEq(lens.claimableTaoOf(alice, TOKEN1), 3 * TAO);
        assertEq(lens.claimableTaoOf(bob, TOKEN1), 0);
    }

    function test_BatchWithDuplicateIds_SettlesEachIdOnce() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, DEPOSIT);
        _donateToTokenClone(TOKEN1, 4 * TAO);

        uint256[] memory ids = new uint256[](2);
        ids[0] = TOKEN1;
        ids[1] = TOKEN1;
        uint256[] memory values = new uint256[](2);
        values[0] = shares / 2;
        values[1] = shares / 2;
        vm.prank(alice);
        vault.safeBatchTransferFrom(alice, bob, ids, values, "");

        assertEq(lens.claimableTaoOf(alice, TOKEN1), 4 * TAO);
        assertEq(lens.claimableTaoOf(bob, TOKEN1), 0);

        _donateToTokenClone(TOKEN1, 4 * TAO);
        _touch(bob, TOKEN1);
        assertEq(lens.claimableTaoOf(bob, TOKEN1), 4 * TAO, "bob now holds every share");
    }

    function test_SelfTransfer_LeavesEntitlementUnchanged() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        _donateToTokenClone(TOKEN1, 2 * TAO);

        _touch(alice, TOKEN1);
        assertEq(lens.claimableTaoOf(alice, TOKEN1), 2 * TAO);

        _touch(alice, TOKEN1);
        assertEq(lens.claimableTaoOf(alice, TOKEN1), 2 * TAO);
    }

    function test_ClaimTao_PaysSettledEntitlement() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        _donateToTokenClone(TOKEN1, 5 * TAO);
        _touch(alice, TOKEN1);
        assertEq(vault.claimableTao(TOKEN1, alice), 5 * TAO, "the touch settles the gift");

        vm.expectEmit(true, true, false, true, address(vault));
        emit TaoClaimed(alice, TOKEN1, alice, 5 * TAO);
        _claimAs(alice);

        assertEq(alice.balance, 5 * TAO);
        assertEq(lens.claimableTaoOf(alice, TOKEN1), 0);
        assertEq(vault.claimableTao(TOKEN1, alice), 0);
        assertEq(vault.taoLiability(TOKEN1), 0);
    }

    function test_RevertWhen_ClaimingWithNoEntitlement() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        vm.expectRevert(ZeroAmount.selector);
        _claimAs(bob);
    }

    function test_RevertWhen_ClaimingSubQuantumEntitlement() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        _depositAndWrap(bob, NETUID1, DEPOSIT);
        // Half of one RAO is 5e8 wei, below what a native transfer can carry.
        _donateToTokenClone(TOKEN1, VaultMath.TAO_NATIVE_QUANTUM);

        assertEq(lens.claimableTaoOf(alice, TOKEN1), 0);
        vm.expectRevert(ClaimBelowNativePrecision.selector);
        _claimAs(alice);
    }

    function test_RevertWhen_ClaimingToZeroAddress() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        vm.expectRevert(ZeroAddress.selector);
        vm.prank(alice);
        vault.claimTao(TOKEN1, payable(address(0)));
    }

    function test_ClaimToAnotherRecipient_PaysThemAndDebitsOnlyTheHolder() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        _donateToTokenClone(TOKEN1, 5 * TAO);
        vm.deal(alice, 2 * TAO);
        vm.deal(bob, 3 * TAO);

        vm.prank(alice);
        vault.claimTao(TOKEN1, payable(bob));

        assertEq(alice.balance, 2 * TAO);
        assertEq(bob.balance, 8 * TAO);
        assertEq(lens.claimableTaoOf(alice, TOKEN1), 0);
        assertEq(lens.claimableTaoOf(bob, TOKEN1), 0, "recipient acquires no entitlement");
    }

    function test_RevertWhen_ClaimRecipientRejectsTao() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        _donateToTokenClone(TOKEN1, 5 * TAO);
        _touch(alice, TOKEN1);
        RevertingReceiver receiver = new RevertingReceiver();
        vm.expectRevert(bytes("nope"));
        vm.prank(alice);
        vault.claimTao(TOKEN1, payable(address(receiver)));
    }

    function test_ClaimReceiver_CannotReenterThePayout() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        _donateToTokenClone(TOKEN1, 5 * TAO);
        ReentrantReceiver receiver = new ReentrantReceiver();
        receiver.arm(address(vault), abi.encodeCall(vault.claimTao, (TOKEN1, payable(address(receiver)))));

        vm.prank(alice);
        vault.claimTao(TOKEN1, payable(address(receiver)));

        assertEq(receiver.reentryError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertFalse(receiver.reentrySucceeded());
        assertEq(address(receiver).balance, 5 * TAO);
    }

    function test_InterleavedBatchTransfer_KeepsEachTokensHistoricalDonations() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        _depositAndWrap(alice, NETUID2, DEPOSIT);
        _donateToTokenClone(TOKEN1, 3 * TAO);
        _donateToTokenClone(TOKEN2, 7 * TAO);
        uint256[] memory ids = new uint256[](3);
        ids[0] = TOKEN1;
        ids[1] = TOKEN2;
        ids[2] = TOKEN1;
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = vault.balanceOf(alice, TOKEN1) / 2;
        amounts[1] = vault.balanceOf(alice, TOKEN2);
        amounts[2] = amounts[0];
        vm.prank(alice);
        vault.setApprovalForAll(bob, true);
        vm.prank(bob);
        vault.safeBatchTransferFrom(alice, bob, ids, amounts, "");

        assertEq(_claimQuotedAmount(alice, TOKEN1), 3 * TAO);
        assertEq(_claimQuotedAmount(alice, TOKEN2), 7 * TAO);
        assertEq(lens.claimableTaoOf(bob, TOKEN1), 0);
        assertEq(lens.claimableTaoOf(bob, TOKEN2), 0);
    }

    function test_ClaimAfterFullExit_StillPays() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        _donateToTokenClone(TOKEN1, 5 * TAO);

        _exitCompletely(alice, TOKEN1);

        assertEq(_claimQuotedAmount(alice, TOKEN1), 5 * TAO);
    }

    function test_ReceiverClaimDuringSafeTransfer_GainsNothing() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, DEPOSIT);
        _donateToTokenClone(TOKEN1, 5 * TAO);
        ClaimDuringTransferReceiver receiver = new ClaimDuringTransferReceiver(vault);

        vm.prank(alice);
        vault.safeTransferFrom(alice, address(receiver), TOKEN1, shares, "");

        assertFalse(receiver.claimSucceeded());
        assertEq(address(receiver).balance, 0);
        assertEq(lens.claimableTaoOf(alice, TOKEN1), 5 * TAO);
    }

    function test_UnwrapForTaoAfterDonation_ExitPaysSaleProceedsOnly() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        uint256 shares = _depositAndWrap(bob, NETUID1, DEPOSIT);
        _donateToTokenClone(TOKEN1, 5 * TAO);

        vm.prank(bob);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(bob.balance, 50 * TAO, "1,000 alpha sold at 0.05 TAO");
        assertEq(lens.claimableTaoOf(alice, TOKEN1), 5 * TAO / 2);
        assertEq(lens.claimableTaoOf(bob, TOKEN1), 5 * TAO / 2);
        assertEq(vault.taoLiability(TOKEN1), 5 * TAO);
        assertEq(vault.subnetClone(TOKEN1).balance, 5 * TAO, "the clone keeps only the reserved gift");
    }

    function testFuzz_ClaimsAcrossHolders_ConserveArrivedTao(
        uint256 donationRao,
        uint256 aliceDeposit,
        uint256 bobDeposit
    ) public {
        donationRao = bound(donationRao, 0.01e9, 10_000e9);
        aliceDeposit = bound(aliceDeposit, ALPHA, 100_000 * ALPHA);
        bobDeposit = bound(bobDeposit, ALPHA, 100_000 * ALPHA);

        _depositAndWrap(alice, NETUID1, aliceDeposit);
        _depositAndWrap(bob, NETUID1, bobDeposit);
        uint256 donation = donationRao * VaultMath.TAO_NATIVE_QUANTUM;
        _donateToTokenClone(TOKEN1, donation);

        // Exercise both checkpointed entitlement and still-unindexed TAO.
        uint256 aliceShares = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vault.safeTransferFrom(alice, bob, TOKEN1, aliceShares / 2, "");
        uint256 secondDonation = (donationRao / 3 + 1) * VaultMath.TAO_NATIVE_QUANTUM;
        _donateToTokenClone(TOKEN1, secondDonation);

        uint256 arrived = donation + secondDonation;
        uint256 paid = _claimQuotedAmount(alice, TOKEN1) + _claimQuotedAmount(bob, TOKEN1);
        assertLe(paid, arrived);
        // At most one sub-RAO remainder per holder, plus index flooring.
        assertApproxEqAbs(paid, arrived, 2 * VaultMath.TAO_NATIVE_QUANTUM + 8);
        assertGe(vault.subnetClone(TOKEN1).balance, vault.taoLiability(TOKEN1));
    }

    function test_DissolutionRefund_NotIndexedToHolders() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        uint256 indexBefore = vault.cumulativeTaoPerShare(TOKEN1);

        _simulateDissolutionStarted(NETUID1);
        _donateToTokenClone(TOKEN1, 5 * TAO);
        _simulateTaoAwardedOnDissolution(TOKEN1, 20 * TAO);
        uint256 shares = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vault.safeTransferFrom(alice, bob, TOKEN1, shares / 2, "");

        assertEq(vault.cumulativeTaoPerShare(TOKEN1), indexBefore);
        assertEq(vault.taoLiability(TOKEN1), 0);

        _simulateDissolutionCompleted(NETUID1);
        _touch(bob, TOKEN1);

        assertEq(vault.cumulativeTaoPerShare(TOKEN1), indexBefore);
        assertEq(vault.taoLiability(TOKEN1), 0);
        assertEq(lens.claimableTaoOf(alice, TOKEN1), 0);
        assertEq(lens.claimableTaoOf(bob, TOKEN1), 0);
    }

    function test_DissolvedUnwrap_ExcludesReservedTao() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        _depositAndWrap(bob, NETUID1, DEPOSIT);
        _donateToTokenClone(TOKEN1, 6 * TAO);
        _touch(alice, TOKEN1);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(TOKEN1, 20 * TAO);
        _simulateDissolutionCompleted(NETUID1);

        uint256 aliceShares = vault.balanceOf(alice, TOKEN1);
        (, uint256 previewTao) = lens.previewUnwrap(TOKEN1, aliceShares);
        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares, bytes32(0), 0);

        assertEq(alice.balance, 10 * TAO, "half of the 20 TAO refund; the 6 TAO gift stays reserved");
        assertEq(previewTao, 10 * TAO);

        assertEq(_claimQuotedAmount(alice, TOKEN1), 3 * TAO, "half of the gift");
    }

    function test_ClaimDuringBlackout_PaysExistingEntitlement() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        _donateToTokenClone(TOKEN1, 5 * TAO);
        _touch(alice, TOKEN1);

        _simulateDissolutionStarted(NETUID1);

        assertEq(_claimQuotedAmount(alice, TOKEN1), 5 * TAO);
    }

    function test_UnwrapAfterFullSweep_RetiresSharesAndKeepsClaim() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, DEPOSIT);
        _sweepAndWriteOff(7 * TAO);

        (uint256 previewAlpha, uint256 previewTao) = lens.previewUnwrap(TOKEN1, shares);
        assertEq(previewAlpha, 0);
        assertEq(previewTao, 0);
        vm.expectEmit(true, true, false, true, address(vault));
        emit Unwrapped(alice, TOKEN1, shares, 0);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        assertEq(vault.totalSupply(TOKEN1), 0);
        assertEq(_claimQuotedAmount(alice, TOKEN1), 7 * TAO);
    }

    function test_WrapAfterFullSweep_IndexesLaterTaoForTheNewHolder() public {
        _depositAndWrap(alice, NETUID1, 10 * ALPHA);
        _sweepAndWriteOff(5 * TAO);

        uint256 bobShares = _depositAndWrap(bob, NETUID1, 10 * ALPHA);
        // 1e10 * (1e19 + 1e9) / (0 + 1): alice's 1e19 shares are backed by no alpha.
        assertEq(bobShares, 100_000_000_010_000_000_000_000_000_000);

        uint256 liabilityBefore = vault.taoLiability(TOKEN1);
        _donateToTokenClone(TOKEN1, 100 * VaultMath.TAO_NATIVE_QUANTUM);
        _touch(bob, TOKEN1);
        assertEq(vault.taoLiability(TOKEN1) - liabilityBefore, 100 * VaultMath.TAO_NATIVE_QUANTUM);

        // Bob's 1e29 + 1e19 of 1e29 + 2e19 shares earn 99,999,999,989 wei of the gift; claims pay whole RAO.
        assertEq(_claimQuotedAmount(bob, TOKEN1), 99 * VaultMath.TAO_NATIVE_QUANTUM);
    }

    function test_RevertWhen_RecapitalizationWouldBreachClaimIndexBound() public {
        _depositAndWrap(alice, NETUID1, ALPHA);
        for (uint256 i; i < 2; ++i) {
            _sweepAndWriteOff(TAO / 20);
            _depositAndWrap(alice, NETUID1, ALPHA);
        }
        _sweepAndWriteOff(TAO / 20);

        // Each recapitalization of written-off shares multiplies supply by about 1e9 (1e18, then 1e27 and
        // 1e36 + 3e27 + 3e18); one more alpha would mint 1e45 + 3e36 + 3e27 + 1e18 shares, past the 1e45 cap.
        _simulateAlphaDeposit(bob, NETUID1, ALPHA);
        vm.expectRevert(SupplyCapExceeded.selector);
        vm.prank(bob);
        vault.wrap(NETUID1, hotkey1, 0);
    }

    function test_TaoArrivingAtZeroSupply_AccruesToNextHolders() public {
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        _exitCompletely(alice, TOKEN1);
        assertEq(vault.totalSupply(TOKEN1), 0);

        _donateToTokenClone(TOKEN1, 5 * TAO);
        _depositAndWrap(bob, NETUID1, DEPOSIT);

        assertEq(lens.claimableTaoOf(alice, TOKEN1), 0);
        assertEq(_claimQuotedAmount(bob, TOKEN1), 5 * TAO);
        assertEq(vault.taoLiability(TOKEN1), 0);
    }

    function test_WrapEmissionsPartialExitAndClaim_PayExactNativeAmounts() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, DEPOSIT);
        _simulateEmissions(NETUID1, 10 * ALPHA);
        _donateToTokenClone(TOKEN1, TAO);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 2, 0);

        // Half the shares take 5e20 * (1,010e9 + 1) / (1e21 + 1e9) = 504,999,999,999 RAO of alpha, sold at
        // 0.05 TAO as a whole 343.4-alpha slot and a 161.599999999-alpha slice, each rounded down to the RAO.
        assertEq(alice.balance, 25_249_999_999 * VaultMath.TAO_NATIVE_QUANTUM, "sale proceeds");
        assertEq(lens.totalStake(TOKEN1), 505_000_000_001, "the kept half carries half the emissions");
        assertEq(_claimQuotedAmount(alice, TOKEN1), TAO, "she held every share when the TAO arrived");
    }
}

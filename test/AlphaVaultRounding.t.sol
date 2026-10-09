// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { VaultMath } from "src/libraries/VaultMath.sol";
import { ClaimBelowNativePrecision, NothingToUnwrap, ZeroAmount } from "src/VaultErrors.sol";
import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";

contract AlphaVaultRoundingTest is AlphaVaultTestBase {
    /// @dev At 0.05 TAO/alpha the deposit floor is 0.04 alpha. Virtual shares keep any deposit above it worth
    ///      at least one share, even against a whole subnet's alpha in emissions.
    function testFuzz_Wrap_MintsSharesForEveryDepositAboveTheFloor(uint256 emissions, uint256 deposit) public {
        emissions = bound(emissions, 0, MAX_SUBNET_ALPHA / 2);
        deposit = bound(deposit, ALPHA_FLOOR, MAX_SUBNET_ALPHA / 2);
        _depositAndWrap(alice, NETUID1, ALPHA);
        _simulateEmissions(NETUID1, emissions);

        assertGt(_depositAndWrap(bob, NETUID1, deposit), 0);
    }

    /// @dev At 0.2 TAO/alpha the deposit floor is 0.01 alpha. With one share left over 11M alpha of emissions,
    ///      0.01 alpha mints 1e7 * (1 + 1e9) / (11e15 + 2) = 0.9 shares, floored to none.
    function test_RevertWhen_DepositIsWorthLessThanOneShare() public {
        _setAlphaPrice(NETUID1, 0.2e18);
        _setValidators(NETUID1, _hotkeys(hotkey1), _weights(BPS_BASE));
        uint256 shares = _depositAndWrap(alice, NETUID1, 100 * ALPHA);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares - 1, _toSubstrate(alice), 0);
        _simulateEmissions(NETUID1, 11_000_000 * ALPHA);
        _simulateAlphaDeposit(bob, NETUID1, ALPHA / 100);

        vm.prank(bob);
        vm.expectRevert(ZeroAmount.selector);
        vault.wrap(NETUID1, hotkey1, 0);
    }

    function test_RevertWhen_UnwrappingSharesWorthLessThanOneRao() public {
        _depositAndWrap(alice, NETUID1, 1_000 * ALPHA);

        vm.prank(alice);
        vm.expectRevert(ZeroAmount.selector);
        vault.unwrap(TOKEN1, 1, _toSubstrate(alice), 0);
    }

    function test_Unwrap_HalfTheSharesDeliverHalfTheAlpha() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 1_000 * ALPHA);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice), 0);

        // 5e20 * (1e12 + 1) / (1e21 + 1e9)
        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), 500 * ALPHA);
    }

    /// @dev Whole-RAO pots leave the last holder the exact remainder, so nothing stays behind.
    function testFuzz_DissolvedUnwrap_PaysEachHolderTheirShareOfThePot(
        uint256 aliceDeposit,
        uint256 bobDeposit,
        uint256 potRao
    ) public {
        aliceDeposit = bound(aliceDeposit, ALPHA, 100_000 * ALPHA);
        bobDeposit = bound(bobDeposit, ALPHA, 100_000 * ALPHA);
        uint256 pot = bound(potRao, 0.01e9, 21_000_000e9) * VaultMath.TAO_NATIVE_QUANTUM;
        uint256 aliceShares = _depositAndWrap(alice, NETUID1, aliceDeposit);
        uint256 bobShares = _depositAndWrap(bob, NETUID1, bobDeposit);
        uint256 supply = aliceShares + bobShares;
        address clone = vault.subnetClone(TOKEN1);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(TOKEN1, pot);
        _simulateDissolutionCompleted(NETUID1);

        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares, bytes32(0), 0);
        vm.prank(bob);
        vault.unwrap(TOKEN1, bobShares, bytes32(0), 0);

        uint256 alicePaid = alice.balance;
        assertEq(alicePaid % VaultMath.TAO_NATIVE_QUANTUM, 0, "native delivery is in whole RAO");
        assertLe(alicePaid * supply, pot * aliceShares, "never above the pro-rata share");
        assertGt((alicePaid + VaultMath.TAO_NATIVE_QUANTUM) * supply, pot * aliceShares, "less than one RAO below it");
        assertEq(alicePaid + bob.balance, pot, "the last holder takes the rest");
        assertEq(clone.balance, 0);
    }

    function test_RevertWhen_DissolvedShareRoundsBelowOneRao() public {
        _depositAndWrap(alice, NETUID1, 99_999 * ALPHA);
        uint256 bobShares = _depositAndWrap(bob, NETUID1, ALPHA);
        _simulateDissolutionStarted(NETUID1);
        // Bob's 1/100,000 of one RAO is 1e4 wei.
        _simulateTaoAwardedOnDissolution(TOKEN1, VaultMath.TAO_NATIVE_QUANTUM);
        _simulateDissolutionCompleted(NETUID1);

        vm.prank(bob);
        vm.expectRevert(ClaimBelowNativePrecision.selector);
        vault.unwrap(TOKEN1, bobShares, bytes32(0), 0);
    }

    function testFuzz_PreviewUnwrap_MatchesDissolvedPayout(uint256 deposit, uint256 potRao, uint256 shares) public {
        deposit = bound(deposit, ALPHA, MAX_SUBNET_ALPHA);
        uint256 pot = bound(potRao, 1, 21_000_000e9) * VaultMath.TAO_NATIVE_QUANTUM;
        shares = bound(shares, 1, _depositAndWrap(alice, NETUID1, deposit));

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(TOKEN1, pot);
        _simulateDissolutionCompleted(NETUID1);

        (uint256 alphaQuote, uint256 taoQuote) = lens.previewUnwrap(TOKEN1, shares);
        assertEq(alphaQuote, 0);

        vm.prank(alice);
        if (taoQuote == 0) {
            vm.expectRevert(ClaimBelowNativePrecision.selector);
            vault.unwrap(TOKEN1, shares, bytes32(0), 0);
            return;
        }
        vault.unwrap(TOKEN1, shares, bytes32(0), 0);
        assertEq(alice.balance, taoQuote);
    }

    function test_RevertWhen_DissolvedCloneHoldsNoTao() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 100 * ALPHA);
        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(TOKEN1, 0);
        _simulateDissolutionCompleted(NETUID1);

        vm.prank(alice);
        vm.expectRevert(NothingToUnwrap.selector);
        vault.unwrap(TOKEN1, shares, bytes32(0), 0);
    }

    function test_DissolvedUnwrap_PaysTaoArrivingAfterDissolution() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 100 * ALPHA);
        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(TOKEN1, 0);
        _simulateDissolutionCompleted(NETUID1);

        _donateToClone(vault.subnetClone(TOKEN1), 7 * TAO);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, bytes32(0), 0);

        assertEq(alice.balance, 7 * TAO);
        assertEq(vault.balanceOf(alice, TOKEN1), 0);
    }
}

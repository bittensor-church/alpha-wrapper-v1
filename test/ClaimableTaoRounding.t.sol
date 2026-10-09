// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { ZeroAmount } from "src/VaultErrors.sol";

contract ClaimableTaoRoundingTest is AlphaVaultTestBase {
    function test_TinyTransfersAndNearFullExits_PreserveHistoricalClaims() public {
        address carol = makeAddr("carol");
        _depositAndWrap(alice, NETUID1, 1_000 * ALPHA);
        _depositAndWrap(bob, NETUID1, 1_000 * ALPHA);
        _depositAndWrap(carol, NETUID1, 1_000 * ALPHA);
        address clone = vault.subnetClone(TOKEN1);

        _donateToClone(clone, 30 * TAO);
        _transfer(carol, alice, 2827);
        _donateToClone(clone, 0.3e18);
        _sell(alice, vault.balanceOf(alice, TOKEN1) - 1);
        _donateToClone(clone, 96e9);
        _sell(carol, vault.balanceOf(carol, TOKEN1) - 2);
        // The sale leaves 0.40000002 alpha on the last slot to stay off the dust threshold, so this exit
        // also mints refund shares.
        _sell(bob, vault.balanceOf(bob, TOKEN1) - 2);
        _transfer(alice, carol, 1);
        _transfer(bob, carol, 1);

        // A third of 30.3 TAO plus half of the 96-RAO gift, whose share for alice's last share is below one wei.
        assertEq(_claimQuotedAmount(bob, TOKEN1), 10_100_000_048e9, "bob");
        assertEq(_claimQuotedAmount(carol, TOKEN1), 10_100_000_048e9, "carol");
        _donateToClone(clone, 4359e9);

        // The 2,827 shares alice took from carol earn 0.28 wei of the 0.3 TAO gift, lost to rounding.
        assertEq(_claimQuotedAmount(alice, TOKEN1), 10.1e18, "alice keeps her historical third");
        assertEq(clone.balance, 4359e9, "only the last gift remains");
        assertEq(vault.taoLiability(TOKEN1), 4359e9, "reserved for bob and carol");
    }

    function test_RevertWhen_SellingOneShareWorthLessThanOneRao() public {
        _depositAndWrap(alice, NETUID1, 1_000 * ALPHA);

        vm.expectRevert(ZeroAmount.selector);
        _sell(alice, 1);
    }

    function _transfer(address from, address to, uint256 shares) private {
        vm.prank(from);
        vault.safeTransferFrom(from, to, TOKEN1, shares, "");
    }

    function _sell(address holder, uint256 shares) private {
        vm.prank(holder);
        vault.unwrapForTao(TOKEN1, shares, 0);
    }
}

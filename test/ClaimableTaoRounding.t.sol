// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { ZeroAmount } from "src/VaultErrors.sol";

contract ClaimableTaoRoundingTest is AlphaVaultTestBase {
    uint256 private constant FIRST_GIFT = 30 * TAO;
    uint256 private constant SECOND_GIFT = 0.3e18;
    uint256 private constant THIRD_GIFT = 96e9;
    uint256 private constant LAST_GIFT = 4359e9;
    uint256 private constant SHARES_EARNING_LESS_THAN_A_WEI_OF_THE_SECOND_GIFT = 2827;

    function test_TinyTransfersAndNearFullExits_PreserveHistoricalClaims() public {
        address carol = makeAddr("carol");
        _depositAndWrap(alice, NETUID1, 1_000 * ALPHA);
        _depositAndWrap(bob, NETUID1, 1_000 * ALPHA);
        _depositAndWrap(carol, NETUID1, 1_000 * ALPHA);
        address clone = vault.subnetClone(TOKEN1);

        _donateToClone(clone, FIRST_GIFT);
        _transfer(carol, alice, SHARES_EARNING_LESS_THAN_A_WEI_OF_THE_SECOND_GIFT);
        _donateToClone(clone, SECOND_GIFT);
        _sell(alice, vault.balanceOf(alice, TOKEN1) - 1);
        _donateToClone(clone, THIRD_GIFT);
        _sell(carol, vault.balanceOf(carol, TOKEN1) - 2);
        // The sale leaves 0.40000002 alpha on the first slot to stay off the dust threshold, so this exit
        // also mints refund shares.
        _sell(bob, vault.balanceOf(bob, TOKEN1) - 2);
        _transfer(alice, carol, 1);
        _transfer(bob, carol, 1);

        uint256 thirdOfTheFirstTwoGiftsPlusHalfOfTheThird = (FIRST_GIFT + SECOND_GIFT) / 3 + THIRD_GIFT / 2;
        assertEq(thirdOfTheFirstTwoGiftsPlusHalfOfTheThird, 10_100_000_048e9);
        assertEq(_claimQuotedAmount(bob, TOKEN1), thirdOfTheFirstTwoGiftsPlusHalfOfTheThird, "bob");
        assertEq(_claimQuotedAmount(carol, TOKEN1), thirdOfTheFirstTwoGiftsPlusHalfOfTheThird, "carol");
        _donateToClone(clone, LAST_GIFT);

        assertEq(
            _claimQuotedAmount(alice, TOKEN1),
            (FIRST_GIFT + SECOND_GIFT) / 3,
            "alice keeps her historical third; the shares she took from carol earn under a wei"
        );
        assertEq(clone.balance, LAST_GIFT, "only the last gift remains");
        assertEq(vault.taoLiability(TOKEN1), LAST_GIFT, "reserved for bob and carol");
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

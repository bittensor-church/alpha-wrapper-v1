// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { VaultMath } from "src/libraries/VaultMath.sol";
import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";

contract VaultMathWideProductTest is AlphaVaultTestBase {
    /// @dev One share collecting 1 TAO lifts the index to 1e54, so settling a whale's ~5e23 shares
    ///      multiplies to ~5e77, past 2^256; only the wide product in `earnedAt` keeps it exact.
    function test_LargeDepositAfterOneShareCollectsAGift_SettlesExactly() public {
        uint256 aliceShares = _depositAndWrap(alice, NETUID1, 1_000 * ALPHA);
        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares - 1, _toSubstrate(alice), 0);
        assertEq(lens.totalStake(TOKEN1), 1, "one share left on one RAO");
        _donateToClone(vault.subnetClone(TOKEN1), TAO);

        uint256 bobShares = _depositAndWrap(bob, NETUID1, 1_000_000 * ALPHA);

        // 1e15 * (1 + 1e9) / (1 + 1)
        assertEq(bobShares, 500_000_000_500_000_000_000_000);
        assertEq(vault.cumulativeTaoPerShare(TOKEN1), 1e54, "1e18 wei * 1e36 / 1 share");
        assertEq(vault.taoIndexDebt(TOKEN1, bob), 500_000_000_500_000_000_000_000e18, "bob's shares times 1e54 / 1e36");
        assertEq(lens.claimableTaoOf(bob, TOKEN1), 0, "the gift predates bob");
        assertEq(_claimQuotedAmount(alice, TOKEN1), TAO, "the single share collects the whole gift");

        _donateToClone(vault.subnetClone(TOKEN1), TAO);
        // Bob holds all but one of 5.000000005e23 + 1 shares: 999,999,999,999,999,999 wei, paid in whole RAO.
        assertEq(_claimQuotedAmount(bob, TOKEN1), TAO - VaultMath.TAO_NATIVE_QUANTUM);
    }
}

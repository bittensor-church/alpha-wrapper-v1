// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { MAX_VALIDATORS } from "src/interfaces/IValidatorRegistry.sol";
import { VaultMath } from "src/libraries/VaultMath.sol";
import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { BackingShortfall } from "src/VaultErrors.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

contract AlphaVaultPublicPropertiesTest is AlphaVaultTestBase {
    function testFuzz_NearSupplyCap_QuotesExitsAndPreservesTheHoldersDonation(
        uint256 recapitalization,
        uint256 stakePerValidator,
        uint256 gift,
        uint256 exitBps
    ) public {
        recapitalization = bound(recapitalization, 900_000_000, 999_999_990);
        stakePerValidator = bound(stakePerValidator, 1e9, type(uint64).max);
        gift = bound(gift, 2e9, 1e30);
        exitBps = bound(exitBps, 2500, 7500);
        uint256 supply = _growSupplyToNearCap(recapitalization);

        bytes32[] memory hotkeys = _setValidatorCount(NETUID1, MAX_VALIDATORS);
        vault.rebalance(NETUID1);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        for (uint256 i; i < hotkeys.length; ++i) {
            MockStaking(STAKING_PRECOMPILE).setStake(hotkeys[i], coldkey, NETUID1, stakePerValidator);
        }
        uint256 backing = MAX_VALIDATORS * stakePerValidator;
        assertEq(lens.totalStake(TOKEN1), backing);
        address clone = vault.subnetClone(TOKEN1);
        _donateToClone(clone, gift);

        uint256 sharesToExit = supply * exitBps / VaultMath.BPS_BASE;
        (uint256 quote,) = lens.previewUnwrap(TOKEN1, sharesToExit);
        assertGt(quote, 0);
        assertLt(quote, backing);
        vm.prank(alice);
        vault.unwrap(TOKEN1, sharesToExit, _toSubstrate(alice), 0);
        uint256 delivered = _stakeAcross(hotkeys, _toSubstrate(alice), NETUID1);
        assertEq(delivered, quote);
        assertEq(delivered + _vaultStakeAcross(hotkeys, NETUID1), backing);
        assertGe(clone.balance, vault.taoLiability(TOKEN1));

        uint256 remaining = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vault.unwrap(TOKEN1, remaining, _toSubstrate(alice), 0);
        assertEq(vault.totalSupply(TOKEN1), 0);
        assertEq(_stakeAcross(hotkeys, _toSubstrate(alice), NETUID1), backing);
        assertGe(vault.taoLiability(TOKEN1), vault.claimableTao(TOKEN1, alice));
        uint256 paid = _claimQuotedAmount(alice, TOKEN1);
        assertLe(paid, gift);
        // At this supply, index truncation and native quantization each retain less than one RAO.
        assertLt(gift - paid, 2e9);
        assertEq(clone.balance + paid, gift);
        assertGe(clone.balance, vault.taoLiability(TOKEN1));
    }

    function testFuzz_SoleHolderClaim_PaysTheGiftWithinOneNativeQuantum(uint256 gift) public {
        gift = bound(gift, 2e9, 1e24);
        _depositAndWrap(alice, NETUID1, 30e9);
        _donateToClone(vault.subnetClone(TOKEN1), gift);

        uint256 before = alice.balance;
        vm.prank(alice);
        vault.claimTao(TOKEN1, payable(alice));
        uint256 paid = alice.balance - before;

        assertEq(paid % VaultMath.TAO_NATIVE_QUANTUM, 0, "native delivery is in whole RAO");
        assertLe(paid, gift, "the gift bounds the payout");
        assertLe(gift - paid, VaultMath.TAO_NATIVE_QUANTUM, "only index and native rounding can remain");
        assertEq(vault.subnetClone(TOKEN1).balance, gift - paid);
    }

    function testFuzz_MissingBacking_RejectsOnlyLossesAboveTheSlack(uint256 missing) public {
        missing = bound(missing, 0, 2 * BACKING_SLACK_RAO);
        _depositAndWrap(alice, NETUID1, 30e9);
        uint256 held = _getVaultStake(hotkey1, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(NETUID1), NETUID1, held - missing);

        assertEq(lens.isBackingIntact(TOKEN1), missing <= BACKING_SLACK_RAO);
        if (missing > BACKING_SLACK_RAO) {
            vm.expectRevert(abi.encodeWithSelector(BackingShortfall.selector, NETUID1, hotkey1, held));
        }
        vault.rebalance(NETUID1);
    }

    function testFuzz_DepositAndFullExit_LoseOnlyTheConfiguredTransferRounding(uint256 deposit, uint256 loss) public {
        deposit = bound(deposit, 1e9, type(uint64).max);
        loss = bound(loss, 0, 2);
        _setValidators(NETUID1, _hotkeys(hotkey1), _weights(VaultMath.BPS_BASE));
        MockStaking(STAKING_PRECOMPILE).setTransferStakeRoundingLoss(loss);
        uint256 shares = _depositAndWrap(alice, NETUID1, deposit);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), deposit - 2 * loss, "one loss at each transfer");
        assertEq(vault.totalSupply(TOKEN1), 0);
        assertEq(_getVaultStake(hotkey1, NETUID1), 0);
    }

    // Finalized losses followed by recapitalization grow supply through public calls.
    // Each individual deposit and precompile stake balance stays within uint64.
    function _growSupplyToNearCap(uint256 recapitalization) private returns (uint256 supply) {
        _setValidators(NETUID1, _hotkeys(hotkey1), _weights(VaultMath.BPS_BASE));
        _setDustThreshold(0);
        _depositAndWrap(alice, NETUID1, 1e9);
        for (uint256 i; i < 2; ++i) {
            _plantVaultStake(hotkey1, NETUID1, 0);
            _depositAndWrap(alice, NETUID1, 1e9);
        }
        _plantVaultStake(hotkey1, NETUID1, 0);
        supply = _depositAndWrap(alice, NETUID1, recapitalization);
        assertGe(supply, 9e44);
        assertLe(supply, 1e45);
    }

    function _dissolveWithPot(uint256 pot) private {
        _simulateTaoAwardedOnDissolution(TOKEN1, pot);
        _simulateDissolutionCompleted(NETUID1);
    }

    function testFuzz_NearSupplyCap_DissolvedExitPaysTheQuotedProRataShare(
        uint256 recapitalization,
        uint256 pot,
        uint256 exitBps
    ) public {
        recapitalization = bound(recapitalization, 900_000_000, 999_999_990);
        pot = bound(pot, 1e18, 21_000_000e18);
        exitBps = bound(exitBps, 1, VaultMath.BPS_BASE - 1);
        uint256 supply = _growSupplyToNearCap(recapitalization);
        _dissolveWithPot(pot);

        uint256 exitShares = supply * exitBps / VaultMath.BPS_BASE;
        uint256 entitlement = pot * exitShares / supply;
        uint256 expected = entitlement - entitlement % VaultMath.TAO_NATIVE_QUANTUM;
        assertGt(expected, 0, "the bounds guarantee a payable entitlement");

        (, uint256 quote) = lens.previewUnwrap(TOKEN1, exitShares);
        uint256 before = alice.balance;
        vm.prank(alice);
        vault.unwrap(TOKEN1, exitShares, bytes32(0), 0);
        uint256 paid = alice.balance - before;

        assertEq(paid, expected, "delivery is the pot's pro-rata share in whole RAO");
        assertEq(quote, expected, "the quote matches the independently computed share");
        assertEq(vault.subnetClone(TOKEN1).balance, pot - paid, "the residue stays for the remaining holders");
        assertEq(vault.totalSupply(TOKEN1), supply - exitShares);
    }

    function testFuzz_NearSupplyCap_DissolvedExitSurvivesAPotBeyondTaoSupply(uint256 recapitalization, uint256 pot)
        public
    {
        recapitalization = bound(recapitalization, 900_000_000, 999_999_990);
        pot = bound(pot, 1e33, 1e40);
        uint256 supply = _growSupplyToNearCap(recapitalization);
        _dissolveWithPot(pot);

        uint256 expected = pot - pot % VaultMath.TAO_NATIVE_QUANTUM;
        (, uint256 quote) = lens.previewUnwrap(TOKEN1, supply);

        uint256 before = alice.balance;
        vm.prank(alice);
        vault.unwrap(TOKEN1, supply, bytes32(0), 0);
        uint256 paid = alice.balance - before;

        assertEq(paid, expected, "the sole holder takes the whole pot");
        assertEq(quote, expected, "the quote matches the independently computed share");
        assertEq(vault.totalSupply(TOKEN1), 0);
    }
}

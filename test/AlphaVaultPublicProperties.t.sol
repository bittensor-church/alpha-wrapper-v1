// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { BackingScenarios } from "./helpers/BackingScenarios.sol";
import { BackingShortfall } from "src/VaultErrors.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

contract AlphaVaultPublicPropertiesTest is BackingScenarios {
    function testFuzz_NearSupplyCap_QuotesExitsAndPreservesTheHoldersDonation(
        uint256 recapitalization,
        uint256 stakePerValidator,
        uint256 gift,
        uint256 exitBps
    ) public {
        stakePerValidator = bound(stakePerValidator, ALPHA, MAX_SUBNET_ALPHA / VALIDATOR_CAP);
        gift = bound(gift, 2, 21_000_000e9) * 1e9;
        exitBps = bound(exitBps, 2_500, 7_500);
        uint256 supply = _growSupplyToNearCap(recapitalization);

        bytes32[] memory hotkeys = _setValidatorCount(NETUID1, VALIDATOR_CAP);
        vault.rebalance(NETUID1);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        for (uint256 i; i < hotkeys.length; ++i) {
            MockStaking(STAKING_PRECOMPILE).setStake(hotkeys[i], coldkey, NETUID1, stakePerValidator);
        }
        uint256 backing = VALIDATOR_CAP * stakePerValidator;
        assertEq(lens.totalStake(TOKEN1), backing);
        address clone = vault.subnetClone(TOKEN1);
        _donateToClone(clone, gift);

        uint256 sharesToExit = supply * exitBps / BPS_BASE;
        uint256 plainShare = sharesToExit * backing / supply;
        (uint256 quote,) = lens.previewUnwrap(TOKEN1, sharesToExit);
        vm.prank(alice);
        vault.unwrap(TOKEN1, sharesToExit, _toSubstrate(alice), 0);
        uint256 delivered = _stakeAcross(hotkeys, _toSubstrate(alice), NETUID1);
        assertGe(delivered, plainShare, "never below the plain pro-rata share");
        assertLe(delivered, plainShare + 1, "at most one RAO above it");
        assertEq(delivered, quote, "the exit delivers the quote");
        assertEq(delivered + _vaultStakeAcross(hotkeys, NETUID1), backing);
        assertGe(clone.balance, vault.taoLiability(TOKEN1));

        uint256 remaining = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vault.unwrap(TOKEN1, remaining, _toSubstrate(alice), 0);
        assertEq(vault.totalSupply(TOKEN1), 0);
        assertEq(_stakeAcross(hotkeys, _toSubstrate(alice), NETUID1), backing);
        assertGe(vault.taoLiability(TOKEN1), vault.claimableTao(TOKEN1, alice));
        uint256 paid = _claimQuotedAmount(alice, TOKEN1);
        assertEq(paid % 1e9, 0, "the claim pays whole RAO");
        assertLe(paid, gift);
        assertLe(gift - paid, 1e9, "index truncation withholds at most one RAO of the gift");
        assertEq(clone.balance + paid, gift);
        assertGe(clone.balance, vault.taoLiability(TOKEN1));
    }

    /// @dev 1,000 alpha mints 1e21 shares, so any whole-RAO gift indexes without remainder.
    function testFuzz_SoleHolderClaim_PaysTheWholeGift(uint256 gift) public {
        gift = bound(gift, 1, 21_000_000e9) * 1e9;
        _depositAndWrap(alice, NETUID1, 1_000 * ALPHA);
        _donateToClone(vault.subnetClone(TOKEN1), gift);

        vm.prank(alice);
        vault.claimTao(TOKEN1, payable(alice));

        assertEq(alice.balance, gift);
        assertEq(vault.subnetClone(TOKEN1).balance, 0);
    }

    function testFuzz_MissingBacking_RejectsOnlyLossesAboveTheSlack(uint256 missing) public {
        _loseFromTheFirstSlotThenRebalance(bound(missing, 0, 2 * BACKING_SLACK_RAO));
    }

    function test_MissingBacking_ToleratesALossOfExactlyTheSlack() public {
        _loseFromTheFirstSlotThenRebalance(BACKING_SLACK_RAO);
    }

    function test_RevertWhen_MissingBackingIsOneRaoAboveTheSlack() public {
        _loseFromTheFirstSlotThenRebalance(BACKING_SLACK_RAO + 1);
    }

    function _loseFromTheFirstSlotThenRebalance(uint256 missing) private {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        assertEq(_getVaultStake(hotkey1, NETUID1), FIRST_SLOT);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(NETUID1), NETUID1, FIRST_SLOT - missing);
        bool withinSlack = missing <= BACKING_SLACK_RAO;

        assertEq(lens.isBackingIntact(TOKEN1), withinSlack);
        if (!withinSlack) {
            vm.expectRevert(abi.encodeWithSelector(BackingShortfall.selector, NETUID1, hotkey1, FIRST_SLOT));
        }
        vault.rebalance(NETUID1);

        assertEq(
            vault.recordedSlots(TOKEN1)[0].tracked,
            withinSlack ? FIRST_SLOT - missing : FIRST_SLOT,
            "a tolerated loss is recorded, a refused one leaves the record alone"
        );
    }

    function testFuzz_DepositAndFullExit_LoseOnlyTheConfiguredTransferRounding(uint256 deposit, uint256 loss) public {
        deposit = bound(deposit, ALPHA, MAX_SUBNET_ALPHA);
        loss = bound(loss, 0, 2);
        _setValidators(NETUID1, _hotkeys(hotkey1), _weights(BPS_BASE));
        MockStaking(STAKING_PRECOMPILE).setTransferStakeRoundingLoss(loss);
        uint256 shares = _depositAndWrap(alice, NETUID1, deposit);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), deposit - 2 * loss, "one loss at each transfer");
        assertEq(vault.totalSupply(TOKEN1), 0);
        assertEq(_getVaultStake(hotkey1, NETUID1), 0);
    }

    // Each written-off position recapitalized with about one alpha multiplies supply by about 1e9.
    function _growSupplyToNearCap(uint256 recapitalization) private returns (uint256 supply) {
        recapitalization = bound(recapitalization, 900_000_000, 999_999_990);
        _setValidators(NETUID1, _hotkeys(hotkey1), _weights(BPS_BASE));
        _setDustThreshold(0);
        _depositAndWrap(alice, NETUID1, ALPHA);
        for (uint256 i; i < 2; ++i) {
            _plantVaultStake(hotkey1, NETUID1, 0);
            _depositAndWrap(alice, NETUID1, ALPHA);
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
        pot = bound(pot, 1e9, 21_000_000e9) * 1e9;
        exitBps = bound(exitBps, 1, 9_999);
        uint256 supply = _growSupplyToNearCap(recapitalization);
        _dissolveWithPot(pot);

        uint256 exitShares = supply * exitBps / BPS_BASE;
        (, uint256 quote) = lens.previewUnwrap(TOKEN1, exitShares);
        vm.prank(alice);
        vault.unwrap(TOKEN1, exitShares, bytes32(0), 0);
        uint256 paid = alice.balance;

        assertEq(paid % 1e9, 0, "delivery is in whole RAO");
        assertLe(paid * supply, pot * exitShares, "never above the pro-rata share");
        assertGt((paid + 1e9) * supply, pot * exitShares, "less than one RAO below it");
        assertEq(quote, paid, "the quote matches the delivery");
        assertEq(vault.subnetClone(TOKEN1).balance, pot - paid, "the residue stays for the remaining holders");
        assertEq(vault.totalSupply(TOKEN1), supply - exitShares);
    }
}

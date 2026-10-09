// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { VaultMath } from "src/libraries/VaultMath.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";
import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { AlphaVaultLens } from "src/AlphaVaultLens.sol";
import {
    AlphaTransfersDisabled,
    BackingShortfall,
    LockedBacking,
    Parked,
    SharePriceBelowPrecision,
    ShortfallOnFile,
    ZeroAddress
} from "src/VaultErrors.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

contract AlphaVaultLensTest is AlphaVaultTestBase {
    function test_RevertWhen_ConstructedWithoutAVault() public {
        vm.expectRevert(ZeroAddress.selector);
        new AlphaVaultLens(AlphaVault(address(0)));
    }

    function testFuzz_SharePrice_AgreesWithThePreviewOfOneShareUnit(uint256 deposit, uint256 emissions, uint256 shares)
        public
    {
        deposit = bound(deposit, ALPHA, MAX_SUBNET_ALPHA / 2);
        emissions = bound(emissions, 0, MAX_SUBNET_ALPHA / 2);
        shares = bound(shares, 1, _depositAndWrap(alice, NETUID1, deposit));
        _simulateEmissions(NETUID1, emissions);

        uint256 price = lens.sharePrice(TOKEN1);
        (uint256 unitAlpha,) = lens.previewUnwrap(TOKEN1, VaultMath.SHARE_PRICE_SCALE);
        assertEq(price, unitAlpha, "one share unit");
        (uint256 alpha,) = lens.previewUnwrap(TOKEN1, shares);
        assertLe(
            (shares * price) / VaultMath.SHARE_PRICE_SCALE,
            alpha,
            "a balance valued at the price never overstates its exit"
        );
    }

    function test_SharePrice_RefusesToQuoteBelowItsPrecision() public {
        _depositAndWrap(alice, NETUID1, 10 * ALPHA);
        bytes32[] memory recorded = _hotkeys(hotkey1, hotkey2, hotkey3);
        for (uint256 i; i < recorded.length; ++i) {
            _simulateOffVaultSwap(NETUID1, recorded[i], keccak256(abi.encode("stray", i)));
        }
        _runOutRecoveryWindow(TOKEN1);
        _reattestCurrentSet(NETUID1);
        uint256 bobShares = _depositAndWrap(bob, NETUID1, 10 * ALPHA);

        // (1e29 + 1e19) * (1e10 + 1) / (1e29 + 2e19 + 1e9): bob's shares hold the whole 1e10 RAO.
        (uint256 alpha,) = lens.previewUnwrap(TOKEN1, bobShares);
        assertEq(alpha, 10 * ALPHA, "the burn quote still prices the position");
        vm.expectRevert(SharePriceBelowPrecision.selector);
        lens.sharePrice(TOKEN1);
    }

    /// @dev Virtual offsets must not imply value when actual backing is zero.
    function testFuzz_SharePrice_QuotesZeroAfterACompleteWriteOff(uint256 deposit) public {
        deposit = bound(deposit, ALPHA, MAX_SUBNET_ALPHA);
        _depositAndWrap(alice, NETUID1, deposit);
        bytes32[] memory recorded = _hotkeys(hotkey1, hotkey2, hotkey3);
        for (uint256 i; i < recorded.length; ++i) {
            _simulateOffVaultSwap(NETUID1, recorded[i], keccak256(abi.encode("stray", i)));
        }
        _runOutRecoveryWindow(TOKEN1);

        assertEq(lens.totalStake(TOKEN1), 0, "the scenario needs the whole backing written off");
        assertEq(lens.sharePrice(TOKEN1), 0);
    }

    function test_PreviewUnwrap_QuotesZeroAfterTheLastHolderExits() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 100 * ALPHA);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
        assertEq(vault.totalSupply(TOKEN1), 0, "the exit must retire the whole supply");

        (uint256 alpha, uint256 tao) = lens.previewUnwrap(TOKEN1, 1);
        assertEq(alpha, 0, "alpha");
        assertEq(tao, 0, "tao");
    }

    function test_PreviewUnwrap_QuotesZeroWhenDissolvedTaoIsFullyReserved() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 100 * ALPHA);
        address clone = vault.subnetClone(TOKEN1);
        _donateToClone(clone, 5 * TAO);
        vm.prank(alice);
        vault.safeTransferFrom(alice, alice, TOKEN1, 0, "");
        assertEq(vault.taoLiability(TOKEN1), 5 * TAO, "the existing claim reserves all TAO");

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(TOKEN1, 0);
        _simulateDissolutionCompleted(NETUID1);

        assertEq(clone.balance, 5 * TAO, "the clone is funded but has no unreserved refund");
        (uint256 alpha, uint256 tao) = lens.previewUnwrap(TOKEN1, shares);
        assertEq(alpha, 0);
        assertEq(tao, 0, "reserved claims do not back dissolved redemptions");
        assertEq(lens.claimableTaoOf(alice, TOKEN1), 5 * TAO, "the separate claim survives");

        uint256 before = alice.balance;
        vm.prank(alice);
        vault.claimTao(TOKEN1, payable(alice));
        assertEq(alice.balance - before, 5 * TAO);
        assertEq(vault.balanceOf(alice, TOKEN1), shares, "claiming does not burn shares");
    }

    /// @dev NETUID2 is configured but has no clone.
    function test_ClaimableTaoOf_QuotesZeroBeforeTheCloneExists() public view {
        assertEq(vault.subnetClone(TOKEN2), address(0), "the scenario needs a position with no clone");
        assertEq(lens.claimableTaoOf(alice, TOKEN2), 0);
    }

    function test_ClaimableTaoOf_QuotesZeroWhenTaoArrivesWithNoHolders() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 100 * ALPHA);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
        _donateToClone(vault.subnetClone(TOKEN1), 5 * TAO);

        assertEq(lens.claimableTaoOf(alice, TOKEN1), 0);
    }

    function test_BatchClaimableTaoOf_MatchesTheSingleQuotePositionForPosition() public {
        _depositAndWrap(alice, NETUID1, 100 * ALPHA);
        _depositAndWrap(alice, NETUID2, 40 * ALPHA);
        _donateToClone(vault.subnetClone(TOKEN1), 3 * TAO);
        _donateToClone(vault.subnetClone(TOKEN2), TAO);

        uint256 unseeded = vault.currentTokenId(NETUID2) + 1;
        uint256[] memory ids = new uint256[](3);
        ids[0] = TOKEN1;
        ids[1] = TOKEN2;
        ids[2] = unseeded;

        uint256[] memory batch = lens.batchClaimableTaoOf(alice, ids);
        assertEq(batch.length, ids.length, "one amount per id");
        assertEq(batch[0], 3 * TAO, "the sole holder of the first position");
        assertEq(batch[1], TAO, "the sole holder of the second position");
        assertEq(batch[2], 0, "a position with no clone quotes nothing");
        for (uint256 i = 0; i < ids.length; i++) {
            assertEq(batch[i], lens.claimableTaoOf(alice, ids[i]), "batch diverged from the single quote");
        }
    }

    function test_BatchClaimableTaoOf_QuotesNothingForNoPositions() public view {
        assertEq(lens.batchClaimableTaoOf(alice, new uint256[](0)).length, 0);
    }

    function testFuzz_BatchClaimableTaoOf_IsOrderAndRepetitionIndependent(uint256 donation) public {
        donation = bound(donation, 1, 1_000_000e9) * VaultMath.TAO_NATIVE_QUANTUM;
        _depositAndWrap(alice, NETUID1, 100 * ALPHA);
        _depositAndWrap(alice, NETUID2, 40 * ALPHA);
        _donateToClone(vault.subnetClone(TOKEN1), donation);

        uint256[] memory ids = new uint256[](4);
        ids[0] = TOKEN2;
        ids[1] = TOKEN1;
        ids[2] = TOKEN1;
        ids[3] = TOKEN2;

        uint256[] memory batch = lens.batchClaimableTaoOf(alice, ids);
        assertEq(batch[1], batch[2], "the same id quoted twice must agree");
        assertEq(batch[0], batch[3], "the same id quoted twice must agree");
        assertEq(batch[1], lens.claimableTaoOf(alice, TOKEN1), "TOKEN1");
        assertEq(batch[0], lens.claimableTaoOf(alice, TOKEN2), "TOKEN2");
    }

    function test_ParkedToken_ReportsItsStateAndRefusesTheMintQuote() public {
        _depositAndWrap(alice, NETUID1, 300 * ALPHA);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        vault.syncBacking(TOKEN1);
        vault.recoverStray(TOKEN1, hotkey4);
        vault.syncBacking(TOKEN1);

        assertTrue(vault.awaitingAttestation(TOKEN1), "the position is parked");
        assertTrue(lens.isBackingIntact(TOKEN1), "parked backing is whole");
        assertEq(lens.writeOffDeadline(TOKEN1), 0, "and no clock runs on it");
        assertEq(lens.lastSeenHotkeys(TOKEN1)[0], vault.parkingHotkey(), "the record names the parking hotkey");
        assertEq(lens.sharePrice(TOKEN1), ALPHA, "1e18 shares still quote one alpha");
        vm.expectRevert(Parked.selector);
        lens.previewWrap(TOKEN1, ALPHA);

        _reattestCurrentSet(NETUID1);
        assertFalse(vault.awaitingAttestation(TOKEN1), "a newer attestation releases it");
        assertEq(lens.previewWrap(TOKEN1, ALPHA), 1e18, "and the mint quote answers again");
    }

    function test_DisabledTransfers_PreviewWrapStillPricesTheDeposit() public {
        _depositAndWrap(alice, NETUID1, 300 * ALPHA);
        _simulateEmissions(NETUID1, 6 * ALPHA);
        _simulateAlphaDeposit(bob, NETUID1, 6 * ALPHA);
        // 6e9 * (3e20 + 1e9) / (306e9 + 1)
        uint256 expectedShares = 5_882_352_941_176_855_055;
        _setTransfersEnabled(NETUID1, false);

        assertEq(lens.previewWrap(TOKEN1, 6 * ALPHA), expectedShares, "the switch does not change the quote");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(AlphaTransfersDisabled.selector, uint16(NETUID1)));
        vault.wrap(NETUID1, hotkey1, 0);

        _setTransfersEnabled(NETUID1, true);
        _wrap(bob, NETUID1);
        assertEq(vault.balanceOf(bob, TOKEN1), expectedShares, "the enabled wrap honors the quote");
    }

    function test_DisabledTransfers_PreviewUnwrapStillPricesThePosition() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 300 * ALPHA);
        _simulateEmissions(NETUID1, 6 * ALPHA);
        // 1.5e20 * (306e9 + 1) / (3e20 + 1e9)
        uint256 expectedAlpha = 152_999_999_999;
        _setTransfersEnabled(NETUID1, false);

        (uint256 alpha, uint256 tao) = lens.previewUnwrap(TOKEN1, shares / 2);
        assertEq(alpha, expectedAlpha, "the switch does not change the alpha quote");
        assertEq(tao, 0, "a live position quotes alpha");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AlphaTransfersDisabled.selector, uint16(NETUID1)));
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice), 0);

        _setTransfersEnabled(NETUID1, true);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice), expectedAlpha);
        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), expectedAlpha, "the enabled exit honors the quote");
        assertEq(vault.balanceOf(alice, TOKEN1), shares - shares / 2, "the enabled exit burns the quoted shares");
    }

    function test_DisabledTransfers_PreviewsStillRejectMissingBackingAndRecovery() public {
        _depositAndWrap(alice, NETUID1, 300 * ALPHA);
        _setTransfersEnabled(NETUID1, false);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);

        vm.expectPartialRevert(BackingShortfall.selector);
        lens.previewWrap(TOKEN1, ALPHA);
        vm.expectPartialRevert(BackingShortfall.selector);
        lens.previewUnwrap(TOKEN1, 1e18);

        vault.syncBacking(TOKEN1);
        vm.expectRevert(ShortfallOnFile.selector);
        lens.previewWrap(TOKEN1, ALPHA);
        vm.expectRevert(ShortfallOnFile.selector);
        lens.previewUnwrap(TOKEN1, 1e18);
    }

    function test_DisabledTransfers_PreviewsStillRejectLockedBacking() public {
        _depositAndWrap(alice, NETUID1, 300 * ALPHA);
        _setTransfersEnabled(NETUID1, false);
        MockStaking(STAKING_PRECOMPILE).setLockedAlpha(_subnetColdkey(NETUID1), NETUID1, hotkey1, ALPHA);

        vm.expectRevert(LockedBacking.selector);
        lens.previewWrap(TOKEN1, ALPHA);
        vm.expectRevert(LockedBacking.selector);
        lens.previewUnwrap(TOKEN1, 1e18);
    }

    function test_DeclaredShortfall_ReadsAsNotIntactUntilSynced() public {
        _depositAndWrap(alice, NETUID1, 300 * ALPHA);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        assertEq(lens.writeOffDeadline(TOKEN1), VaultReads.UNDECLARED_SHORTFALL, "short and not yet declared");
        vault.syncBacking(TOKEN1);
        _simulateOffVaultSwap(NETUID1, hotkey4, hotkey1);

        assertFalse(lens.isBackingIntact(TOKEN1), "the alpha is back but the shortfall is still on file");
        assertEq(lens.writeOffDeadline(TOKEN1), block.timestamp + RECOVERY_WINDOW, "with its clock still running");
        vm.expectRevert(ShortfallOnFile.selector);
        lens.sharePrice(TOKEN1);
        vm.expectRevert(ShortfallOnFile.selector);
        lens.previewUnwrap(TOKEN1, 1e18);

        vault.syncBacking(TOKEN1);
        assertTrue(lens.isBackingIntact(TOKEN1), "syncing takes it off file");
        assertEq(lens.writeOffDeadline(TOKEN1), 0, "and stops the clock");
    }

    function test_DissolvedToken_ReadsWithoutARecordToAnswerTo() public {
        _depositAndWrap(alice, NETUID1, 300 * ALPHA);
        _reregisterSubnet(NETUID1);

        assertEq(lens.locatedStake(TOKEN1), 300 * ALPHA, "the reading counts what the record names");
        assertTrue(lens.isBackingIntact(TOKEN1), "with nothing to be short against");
        assertEq(lens.writeOffDeadline(TOKEN1), 0, "and nothing holding it shut");
    }

    function test_ResolvedBacking_NamesEachRecordedKeyAndItsBalance() public {
        _depositAndWrap(alice, NETUID1, 300 * ALPHA);

        VaultReads.Backing memory backing = lens.resolvedBacking(TOKEN1);

        bytes32[] memory recorded = _hotkeys(hotkey1, hotkey2, hotkey3);
        uint256[3] memory weightedStakes = [uint256(100.02e9), 99.99e9, 99.99e9];
        assertEq(backing.keys.length, recorded.length, "one entry per recorded slot");
        for (uint256 i; i < recorded.length; ++i) {
            assertEq(backing.keys[i], recorded[i], "an untouched slot sells from its recorded key");
            assertEq(backing.balances[i], weightedStakes[i], "the slot's 3334 or 3333 bps of 300 alpha");
            assertFalse(backing.short[i], "nothing is short");
        }
        assertEq(backing.total, 300 * ALPHA, "the total covers the whole position");
    }

    function test_ResolvedBacking_FollowsASwappedSlotToItsSuccessor() public {
        _depositAndWrap(alice, NETUID1, 300 * ALPHA);
        _simulatePerSubnetSwap(NETUID1, hotkey1, hotkey4);

        VaultReads.Backing memory backing = lens.resolvedBacking(TOKEN1);

        assertEq(backing.keys[0], hotkey4, "the exit sells the renamed slot from its successor");
        assertEq(backing.balances[0], 100.02e9, "the successor carries the slot");
        assertFalse(backing.short[0], "a followed slot is not short");
        assertEq(backing.total, 300 * ALPHA, "and the position is still whole");
    }

    /// @dev One balance must never answer for two slots, so only the first slot may claim the successor.
    function test_ResolvedBacking_MarksTheFollowerOfASharedSuccessorShort() public {
        _depositAndWrap(alice, NETUID1, 300 * ALPHA);
        _simulatePerSubnetSwap(NETUID1, hotkey1, hotkey4);
        _simulatePerSubnetSwap(NETUID1, hotkey2, hotkey4);

        VaultReads.Backing memory backing = lens.resolvedBacking(TOKEN1);

        assertEq(backing.keys[0], hotkey4, "the first slot takes the shared successor");
        assertEq(backing.balances[0], 200.01e9, "with both renamed slots' alpha");
        assertFalse(backing.short[0], "which leaves it covered");
        assertEq(backing.keys[1], hotkey2, "the second slot stays on its emptied key");
        assertEq(backing.balances[1], 0, "with nothing on it");
        assertTrue(backing.short[1], "and is reported short");
        assertEq(backing.total, 300 * ALPHA, "located alpha");
    }

    function test_ResolvedBacking_AnswersEmptyWithoutAClone() public view {
        assertEq(vault.subnetClone(TOKEN2), address(0), "the scenario needs a position with no clone");

        VaultReads.Backing memory backing = lens.resolvedBacking(TOKEN2);

        assertEq(backing.keys.length, 0, "keys");
        assertEq(backing.balances.length, 0, "balances");
        assertEq(backing.short.length, 0, "short flags");
        assertEq(backing.total, 0, "total");
    }

    function test_DissolvingSubnet_ReadsTheDrainAsNoLoss() public {
        _depositAndWrap(alice, NETUID1, 300 * ALPHA);
        _simulateDissolutionStarted(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(NETUID1), NETUID1, 0);

        assertTrue(lens.isBackingIntact(TOKEN1), "the drain is not a shortfall");
        assertEq(lens.writeOffDeadline(TOKEN1), 0, "and starts no clock");
        assertEq(lens.totalStake(TOKEN1), 199.98e9, "the total is what the drain left on hotkey2 and hotkey3");
        assertEq(lens.locatedStake(TOKEN1), 199.98e9);
    }
}

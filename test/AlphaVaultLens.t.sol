// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { VaultReads } from "src/libraries/VaultReads.sol";
import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { AlphaVaultLens } from "src/AlphaVaultLens.sol";
import {
    AlphaTransfersDisabled,
    BackingShortfall,
    LockedBacking,
    NoSharesOutstanding,
    Parked,
    SharePriceBelowPrecision,
    ShortfallOnFile,
    SubnetDissolved,
    SubnetInDissolutionBlackoutPeriod,
    ZeroAddress
} from "src/VaultErrors.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

contract AlphaVaultLensTest is AlphaVaultTestBase {
    uint256 private constant TOKEN_WITHOUT_A_CLONE = 3;
    uint256 private constant TOKEN_OF_AN_UNREGISTERED_SUBNET = 42 + 100 * 65_536;

    function test_RevertWhen_ConstructedWithoutAVault() public {
        vm.expectRevert(ZeroAddress.selector);
        new AlphaVaultLens(AlphaVault(address(0)));
    }

    function testFuzz_SharePrice_AgreesWithThePreviewOfOneShareUnit(uint256 deposit, uint256 emissions, uint256 shares)
        public
    {
        deposit = bound(deposit, ALPHA, MAX_SUBNET_ALPHA / 2);
        emissions = bound(emissions, 0, MAX_SUBNET_ALPHA / 2);
        uint256 supply = _depositAndWrap(alice, NETUID1, deposit);
        shares = bound(shares, 1, supply);
        _simulateEmissions(NETUID1, emissions);
        uint256 backing = deposit + emissions;

        uint256 price = lens.sharePrice(TOKEN1);
        _assertPlainShareLessOneRaoPerAlpha(price, 1e18 * backing / supply);
        (uint256 unitAlpha,) = lens.previewUnwrap(TOKEN1, 1e18);
        assertEq(price, unitAlpha, "one share unit");
        (uint256 alpha,) = lens.previewUnwrap(TOKEN1, shares);
        _assertPlainShareLessOneRaoPerAlpha(alpha, shares * backing / supply);
        assertLe((shares * price) / 1e18, alpha, "a balance valued at the price never overstates its exit");
    }

    function _assertPlainShareLessOneRaoPerAlpha(uint256 quote, uint256 plainShare) private pure {
        assertLe(quote, plainShare, "never above the plain pro-rata share");
        assertGe(quote + plainShare / 1e9 + 1, plainShare, "at most one RAO per alpha below it, plus one");
    }

    function test_SharePrice_RefusesToQuoteBelowItsPrecision() public {
        _depositAndWrap(alice, NETUID1, 10 * ALPHA);
        bytes32[] memory recorded = _hotkeys(hotkey1, hotkey2, hotkey3);
        for (uint256 i; i < recorded.length; ++i) {
            _sweepDuringCrash(NETUID1, recorded[i]);
        }
        _runOutRecoveryWindow(TOKEN1);
        _reattestValidators(NETUID1);
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
            _sweepDuringCrash(NETUID1, recorded[i]);
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

        uint256[] memory ids = new uint256[](3);
        ids[0] = TOKEN1;
        ids[1] = TOKEN2;
        ids[2] = TOKEN_WITHOUT_A_CLONE;

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
        donation = bound(donation, 1, 1_000_000e9) * 1e9;
        _depositAndWrap(alice, NETUID1, 100 * ALPHA);
        _depositAndWrap(alice, NETUID2, 40 * ALPHA);
        _donateToClone(vault.subnetClone(TOKEN1), donation);

        uint256[] memory ids = new uint256[](4);
        ids[0] = TOKEN2;
        ids[1] = TOKEN1;
        ids[2] = TOKEN1;
        ids[3] = TOKEN2;

        uint256[] memory batch = lens.batchClaimableTaoOf(alice, ids);
        assertEq(batch[1], donation, "the sole holder of TOKEN1 is quoted the whole donation");
        assertEq(batch[0], 0, "TOKEN2 received nothing");
        assertEq(batch[1], batch[2], "the same id quoted twice must agree");
        assertEq(batch[0], batch[3], "the same id quoted twice must agree");
        assertEq(batch[1], lens.claimableTaoOf(alice, TOKEN1), "TOKEN1");
        assertEq(batch[0], lens.claimableTaoOf(alice, TOKEN2), "TOKEN2");
    }

    function test_ParkedToken_ReportsItsStateAndRefusesTheMintQuote() public {
        _depositAndWrap(alice, NETUID1, 300 * ALPHA);
        uint256 swept = _sweepDuringCrash(NETUID1, hotkey1);
        vault.syncBacking(TOKEN1);
        _strangerReturns(NETUID1, hotkey4, swept);
        vault.recoverStray(TOKEN1, hotkey4);
        vault.syncBacking(TOKEN1);

        assertTrue(vault.awaitingAttestation(TOKEN1), "the position is parked");
        assertTrue(lens.isBackingIntact(TOKEN1), "parked backing is whole");
        assertEq(lens.writeOffDeadline(TOKEN1), 0, "and no clock runs on it");
        assertEq(lens.lastSeenHotkeys(TOKEN1)[0], PARKING_HOTKEY, "the record names the parking hotkey");
        assertEq(lens.sharePrice(TOKEN1), ALPHA, "1e18 shares still quote one alpha");
        vm.expectRevert(Parked.selector);
        lens.previewWrap(TOKEN1, ALPHA);

        _reattestValidators(NETUID1);
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
        _sweepDuringCrash(NETUID1, hotkey1);

        bytes memory firstSlotShort =
            abi.encodeWithSelector(BackingShortfall.selector, uint16(NETUID1), hotkey1, 100.02e9);
        vm.expectRevert(firstSlotShort);
        lens.previewWrap(TOKEN1, ALPHA);
        vm.expectRevert(firstSlotShort);
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
        uint256 swept = _sweepDuringCrash(NETUID1, hotkey1);
        assertEq(lens.writeOffDeadline(TOKEN1), type(uint256).max, "short and not yet declared");
        vault.syncBacking(TOKEN1);
        _strangerReturns(NETUID1, hotkey1, swept);

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

    function test_ResolvedBacking_NamesEachRecordedHotkeyAndItsBalance() public {
        _depositAndWrap(alice, NETUID1, 300 * ALPHA);

        VaultReads.Backing memory backing = lens.resolvedBacking(TOKEN1);

        bytes32[] memory recorded = _hotkeys(hotkey1, hotkey2, hotkey3);
        uint256[3] memory weightedStakes = [uint256(100.02e9), 99.99e9, 99.99e9];
        assertEq(backing.hotkeys.length, recorded.length, "one entry per recorded slot");
        for (uint256 i; i < recorded.length; ++i) {
            assertEq(backing.hotkeys[i], recorded[i], "an untouched slot sells from its recorded key");
            assertEq(backing.balances[i], weightedStakes[i], "the slot's 3334 or 3333 bps of 300 alpha");
            assertFalse(backing.short[i], "nothing is short");
        }
        assertEq(backing.total, 300 * ALPHA, "the total covers the whole position");
    }

    function test_ResolvedBacking_FollowsASwappedSlotToItsSuccessor() public {
        _depositAndWrap(alice, NETUID1, 300 * ALPHA);
        _simulatePerSubnetSwap(NETUID1, hotkey1, hotkey4);

        VaultReads.Backing memory backing = lens.resolvedBacking(TOKEN1);

        assertEq(backing.hotkeys[0], hotkey4, "the exit sells the renamed slot from its successor");
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

        assertEq(backing.hotkeys[0], hotkey4, "the first slot takes the shared successor");
        assertEq(backing.balances[0], 200.01e9, "with both renamed slots' alpha");
        assertFalse(backing.short[0], "which leaves it covered");
        assertEq(backing.hotkeys[1], hotkey2, "the second slot stays on its emptied key");
        assertEq(backing.balances[1], 0, "with nothing on it");
        assertTrue(backing.short[1], "and is reported short");
        assertEq(backing.total, 300 * ALPHA, "located alpha");
    }

    function test_ResolvedBacking_AnswersEmptyWithoutAClone() public view {
        assertEq(vault.subnetClone(TOKEN2), address(0), "the scenario needs a position with no clone");

        VaultReads.Backing memory backing = lens.resolvedBacking(TOKEN2);

        assertEq(backing.hotkeys.length, 0, "keys");
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

    function testFuzz_MissingStake_IsZeroWhileEmissionsAccrue(uint256 deposit, uint256 emissions) public {
        deposit = bound(deposit, ALPHA, MAX_SUBNET_ALPHA / 2);
        emissions = bound(emissions, 1, MAX_SUBNET_ALPHA / 2);
        _depositAndWrap(alice, NETUID1, deposit);
        _simulateEmissions(NETUID1, emissions);

        assertEq(lens.missingStake(TOKEN1), 0, "emissions leave more alpha located than tracked");
        _simulateDissolutionStarted(NETUID1);
        assertEq(lens.missingStake(TOKEN1), 0, "and a dissolving position tracks nothing");
    }

    function test_StakingListEntries_IsZeroWithoutAClone() public view {
        assertEq(lens.stakingListEntries(TOKEN1), 0);
    }

    function test_StakingListEntries_CountsTheFundedValidatorsAndAHotkeyListedThroughAnotherSubnet() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        assertEq(lens.stakingListEntries(TOKEN1), 3, "one entry per funded validator");

        _strangerReturns(NETUID1, hotkey4, ALPHA);
        assertEq(lens.stakingListEntries(TOKEN1), 4, "the returned pile's hotkey is listed too");
    }

    function test_StakingListEntries_FollowsAReplacedClone() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _fillListTo(_subnetColdkey(NETUID1), STAKING_LIST_CAP - 1);
        assertEq(lens.stakingListEntries(TOKEN1), 255, "one short of the chain's 256-entry cap");
        vault.replaceClone(TOKEN1, keccak256("successor-uid"));

        assertEq(lens.stakingListEntries(TOKEN1), 3, "the successor lists only the funded validators");
    }

    function testFuzz_PreviewWrap_QuotesABillionSharesPerRaoOnAnEmptyVault(uint256 assets) public view {
        assets = bound(assets, 0, MAX_SUBNET_ALPHA);
        assertEq(lens.previewWrap(TOKEN1, assets), assets * 1e9, "an empty vault mints 1e9 shares per RAO");
    }

    function test_PreviewUnwrap_QuotesTheWholeDepositForAllShares() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 10 * ALPHA);

        (uint256 alpha, uint256 tao) = lens.previewUnwrap(TOKEN1, shares);
        assertEq(alpha, 10 * ALPHA);
        assertEq(tao, 0);
    }

    function test_SharePrice_RisesOnlyOnTheSubnetThatEarnedEmissions() public {
        _depositAndWrap(alice, NETUID1, 10 * ALPHA);
        uint256 shares2 = _depositAndWrap(alice, NETUID2, 5 * ALPHA);

        _simulateEmissions(NETUID1, 10 * ALPHA);

        // 1e18 * (2e10 + 1) / (1e19 + 1e9), floored.
        assertEq(lens.sharePrice(TOKEN1), 1_999_999_999, "netuid 1 doubles with its emissions");
        assertEq(lens.sharePrice(TOKEN2), 1e9, "netuid 2 stays at the initial price");

        (uint256 preview2,) = lens.previewUnwrap(TOKEN2, shares2);
        assertEq(preview2, 5 * ALPHA);
    }

    function test_RevertWhen_SharePriceForUnregisteredSubnet() public {
        vm.expectRevert(SubnetDissolved.selector);
        lens.sharePrice(TOKEN_OF_AN_UNREGISTERED_SUBNET);
    }

    function test_RevertWhen_SharePriceHasNoSharesOutstanding() public {
        _prepareMailbox(alice, NETUID1);
        assertEq(vault.totalSupply(TOKEN1), 0);
        vm.expectRevert(NoSharesOutstanding.selector);
        lens.sharePrice(TOKEN1);
    }

    function test_RevertWhen_SharePriceOnReplacedGenerationDuringSuccessorBlackout() public {
        _depositAndWrap(alice, NETUID1, 100 * ALPHA);
        _simulateNewNetworkRegistered(TOKEN1, 5 * TAO);
        _simulateDissolutionStarted(NETUID1);

        vm.expectRevert(SubnetDissolved.selector);
        lens.sharePrice(TOKEN1);
    }

    function test_PreviewUnwrap_QuotesTheDissolutionRefund() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 100 * ALPHA);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(TOKEN1, 5 * TAO);
        _simulateDissolutionCompleted(NETUID1);

        (uint256 alpha, uint256 tao) = lens.previewUnwrap(TOKEN1, shares);
        assertEq(alpha, 0);
        assertEq(tao, 5 * TAO);
    }

    function test_PreviewUnwrap_QuotesReplacedGenerationDuringSuccessorBlackout() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 100 * ALPHA);
        _simulateNewNetworkRegistered(TOKEN1, 5 * TAO);
        _simulateDissolutionStarted(NETUID1);

        (uint256 alpha, uint256 tao) = lens.previewUnwrap(TOKEN1, shares);
        assertEq(alpha, 0);
        assertEq(tao, 5 * TAO);
    }

    function test_PreviewUnwrap_QuotesZeroForATokenWithoutAClone() public view {
        (uint256 alpha, uint256 tao) = lens.previewUnwrap(TOKEN_WITHOUT_A_CLONE, 1e18);
        assertEq(alpha, 0);
        assertEq(tao, 0);
    }

    function test_PreviewUnwrap_QuotesZeroForZeroShares() public view {
        (uint256 alpha, uint256 tao) = lens.previewUnwrap(TOKEN1, 0);
        assertEq(alpha, 0);
        assertEq(tao, 0);
    }

    function test_PreviewUnwrap_AccountsForRotatedOutStake() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);

        _plantVaultStakes(NETUID1, 0, 0, 30 * ALPHA);

        _setValidators(
            NETUID1, _hotkeys(hotkey1, hotkey2, hotkey4), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );

        (uint256 previewAlpha,) = lens.previewUnwrap(TOKEN1, shares);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        uint256 actualAlpha = _userStakeAcrossHotkeys(alice, NETUID1);
        assertEq(actualAlpha, 30 * ALPHA, "unwrap reclaims rotated-out stake and pays the full deposit");
        assertEq(previewAlpha, actualAlpha, "preview must match what unwrap actually pays");
    }

    function test_PreviewUnwrap_MatchesTheExitAfterAFullRegistryRotation() public {
        _setValidators(NETUID1, _hotkeys(hotkey4), _weights(BPS_BASE));
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);

        _setValidators(
            NETUID1, _hotkeys(hotkey1, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );

        (uint256 previewAlpha,) = lens.previewUnwrap(TOKEN1, shares);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        uint256 actualAlpha = _userStakeAcrossHotkeys(alice, NETUID1);
        assertEq(actualAlpha, 30 * ALPHA, "unwrap reclaims stake from the rotated-out validator");
        assertEq(previewAlpha, actualAlpha, "preview matches what unwrap pays after registry rotation");
    }

    function test_PreviewUnwrap_IncludesEmissionsBeforeAnyVaultCall() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);

        _simulateEmissions(NETUID1, 6 * ALPHA);

        (uint256 previewAlpha,) = lens.previewUnwrap(TOKEN1, shares);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        uint256 actualAlpha = _userStakeAcrossHotkeys(alice, NETUID1);
        // 3e19 * (3.6e10 + 1) / (3e19 + 1e9), floored.
        assertEq(actualAlpha, 36 * ALPHA - 1, "unwrap pays deposit + accrued emissions");
        assertEq(previewAlpha, actualAlpha, "preview reflects fresh on-chain balances incl. emissions");
    }

    function test_PreviewUnwrap_QuotesZeroOnceTheBackingIsGone() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);

        _plantVaultStakes(NETUID1, 0, 0, 0);

        (uint256 alpha, uint256 tao) = lens.previewUnwrap(TOKEN1, shares);

        assertEq(alpha, 0);
        assertEq(tao, 0);
    }

    function test_RevertWhen_SharePriceForReRegisteredSubnetOldTokenId() public {
        _depositAndWrap(alice, NETUID1, 100 * ALPHA);

        _simulateNewNetworkRegistered(TOKEN1, 5 * TAO);

        vm.expectRevert(SubnetDissolved.selector);
        lens.sharePrice(TOKEN1);
    }

    function test_RevertWhen_SharePriceOfADissolvedTokenEvenAfterAForceSend() public {
        _depositAndWrap(alice, NETUID1, 100 * ALPHA);
        address clone = vault.subnetClone(TOKEN1);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(TOKEN1, 5 * TAO);
        _simulateDissolutionCompleted(NETUID1);

        vm.expectRevert(SubnetDissolved.selector);
        lens.sharePrice(TOKEN1);

        _donateToClone(clone, 100 * TAO);
        vm.expectRevert(SubnetDissolved.selector);
        lens.sharePrice(TOKEN1);
    }

    function test_RevertWhen_PreviewWrapForDissolvedTokenId() public {
        _depositAndWrap(alice, NETUID1, 100 * ALPHA);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(TOKEN1, 5 * TAO);
        _simulateDissolutionCompleted(NETUID1);

        vm.expectRevert(SubnetDissolved.selector);
        lens.previewWrap(TOKEN1, 10 * ALPHA);
    }

    function test_RevertWhen_PreviewWrapForReRegisteredSubnetOldTokenId() public {
        _depositAndWrap(alice, NETUID1, 100 * ALPHA);

        _simulateNewNetworkRegistered(TOKEN1, 5 * TAO);

        vm.expectRevert(SubnetDissolved.selector);
        lens.previewWrap(TOKEN1, 10 * ALPHA);
    }

    function test_RevertWhen_PreviewUnwrapBlackoutOfCurrentRegistration() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 10 * ALPHA);

        _simulateDissolutionStarted(NETUID1);

        vm.expectRevert(SubnetInDissolutionBlackoutPeriod.selector);
        lens.previewUnwrap(TOKEN1, shares);
    }

    function test_RevertWhen_SharePriceBlackoutOfCurrentRegistration() public {
        _depositAndWrap(alice, NETUID1, 10 * ALPHA);

        _simulateDissolutionStarted(NETUID1);

        vm.expectRevert(SubnetInDissolutionBlackoutPeriod.selector);
        lens.sharePrice(TOKEN1);
    }

    function test_RevertWhen_PreviewWrapBlackoutOfCurrentRegistration() public {
        _depositAndWrap(alice, NETUID1, 10 * ALPHA);

        _simulateDissolutionStarted(NETUID1);

        vm.expectRevert(SubnetInDissolutionBlackoutPeriod.selector);
        lens.previewWrap(TOKEN1, 10 * ALPHA);
    }

    function test_PreviewUnwrap_QuotesNothingForADissolvedPositionWithoutARefund() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 10 * ALPHA);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(TOKEN1, 0);
        _simulateDissolutionCompleted(NETUID1);

        (uint256 alpha, uint256 tao) = lens.previewUnwrap(TOKEN1, shares);
        assertEq(alpha, 0, "no alpha remains after dissolution");
        assertEq(tao, 0, "no refund quotes zero");
    }

    function test_TotalStake_ReflectsEmissionsWithoutSync() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        assertEq(lens.sharePrice(TOKEN1), 1e9);

        _simulateEmissions(NETUID1, 5 * ALPHA);

        assertEq(lens.totalStake(TOKEN1), 35 * ALPHA, "totalStake includes the 5-alpha emission");
        assertEq(_totalVaultStakeAcrossHotkeys(NETUID1), 35 * ALPHA, "totalStake tracks live stake");
        // 1e18 * (3.5e10 + 1) / (3e19 + 1e9), floored.
        assertEq(lens.sharePrice(TOKEN1), 1_166_666_666, "sharePrice rises with emissions");
    }
}

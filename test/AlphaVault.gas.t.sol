// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { BackingShortfall } from "src/VaultErrors.sol";

// Mock-based measurements, not live-chain gas estimates; use e2e receipts for sizing.

/// forge-config: default.isolate = true
contract AlphaVaultGasTest is AlphaVaultTestBase {
    function test_gas_createMailbox_firstOnSubnet() public {
        vm.prank(alice);
        vault.createMailbox(NETUID1, keccak256("fixture-creation"));
        vm.snapshotGasLastCall("AlphaVault", "createMailbox: first on subnet");

        assertTrue(vault.subnetClone(TOKEN1) != address(0), "the first mailbox publishes the clone");
        assertTrue(vault.getDepositAddress(alice, NETUID1) != address(0), "and the mailbox");
    }

    function test_gas_createMailbox_sharedSubnet() public {
        _prepareMailbox(alice, NETUID1);
        address clone = vault.subnetClone(TOKEN1);
        vm.prank(bob);
        vault.createMailbox(NETUID1, keccak256("fixture-creation"));
        vm.snapshotGasLastCall("AlphaVault", "createMailbox: shared subnet");

        assertEq(vault.subnetClone(TOKEN1), clone, "the clone is shared");
        assertTrue(vault.getDepositAddress(bob, NETUID1) != address(0), "bob gets his own mailbox");
    }

    function test_gas_createMailbox_existing() public {
        address mailbox = _prepareMailbox(alice, NETUID1);
        vm.prank(alice);
        vault.createMailbox(NETUID1, keccak256("fixture-creation"));
        vm.snapshotGasLastCall("AlphaVault", "createMailbox: existing");

        assertEq(vault.getDepositAddress(alice, NETUID1), mailbox, "the existing mailbox is kept");
    }

    function test_gas_wrap_firstWrap() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        _wrap(alice, NETUID1);
        vm.snapshotGasLastCall("AlphaVault", "wrap: first");

        assertEq(vault.balanceOf(alice, TOKEN1), 1e19);
    }

    function test_gas_wrap_subsequentWrap() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        _wrap(alice, NETUID1);

        _simulateAlphaDeposit(bob, NETUID1, 5 * ALPHA);
        _wrap(bob, NETUID1);
        vm.snapshotGasLastCall("AlphaVault", "wrap: subsequent");

        assertEq(vault.balanceOf(bob, TOKEN1), 5e18);
    }

    function test_gas_unwrap_partial() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        _wrap(alice, NETUID1);
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice), 0);
        vm.snapshotGasLastCall("AlphaVault", "unwrap: partial");

        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), 5 * ALPHA);
    }

    function test_gas_unwrap_full() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        _wrap(alice, NETUID1);
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
        vm.snapshotGasLastCall("AlphaVault", "unwrap: full");

        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), 10 * ALPHA);
        assertEq(vault.totalSupply(TOKEN1), 0);
    }

    function test_gas_unwrapForTao_partialTailAboveFloor() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        _wrap(alice, NETUID1);
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 2, 0);
        vm.snapshotGasLastCall("AlphaVault", "unwrapForTao: partial tail above floor");

        assertEq(alice.balance, 0.25e18, "5 alpha sold at 0.05 TAO");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "the first slot drains whole");
        assertEq(_getVaultStake(hotkey2, NETUID1), 3.333e9 - 1.666e9, "the second sells the rest and keeps its tail");
    }

    function test_gas_unwrapForTao_subFloorTailRefunded() public {
        _simulateAlphaDeposit(alice, NETUID1, 100 * ALPHA);
        _wrap(alice, NETUID1);

        _plantVaultStakes(NETUID1, 60 * ALPHA, 0, 40 * ALPHA);

        // 60.01 alpha: a full drain plus a 0.01-alpha partial below the sale floor, refunded as shares.
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, 60_010_000_000e9, 0);
        vm.snapshotGasLastCall("AlphaVault", "unwrapForTao: sub-floor tail refunded");

        assertEq(alice.balance, 3e18, "60 alpha sold at 0.05 TAO");
        assertEq(vault.balanceOf(alice, TOKEN1), 40e18, "39.99e18 shares kept and 1e16 refunded for 0.01 alpha");
    }

    function test_gas_replaceClone_3Validators() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        _wrap(alice, NETUID1);
        _fillListTo(_subnetColdkey(NETUID1), STAKING_LIST_CAP - 1);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey4), _weights(3334, 3333, 3333));
        vault.replaceClone(TOKEN1, keccak256("fixture-replacement"));
        vm.snapshotGasLastCall("AlphaVault", "replaceClone: 3 validators");

        assertEq(lens.stakingListEntries(TOKEN1), 3, "the successor lists only the funded hotkeys");
        assertEq(lens.totalStake(TOKEN1), 10 * ALPHA, "and holds the whole position");
    }

    function test_gas_rebalance() public {
        _simulateAlphaDeposit(alice, NETUID1, 100 * ALPHA);
        _wrap(alice, NETUID1);

        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey3), _weights(5000, 3000, 2000));

        vault.rebalance(NETUID1);
        vm.snapshotGasLastCall("AlphaVault", "rebalance: after registry weight update");

        assertEq(_getVaultStake(hotkey1, NETUID1), 50 * ALPHA);
        assertEq(_getVaultStake(hotkey2, NETUID1), 30 * ALPHA);
        assertEq(_getVaultStake(hotkey3, NETUID1), 20 * ALPHA);
    }

    function test_gas_previewWrap() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        _wrap(alice, NETUID1);

        lens.previewWrap(TOKEN1, 5 * ALPHA);
        vm.snapshotGasLastCall("AlphaVaultLens", "previewWrap");

        assertEq(lens.previewWrap(TOKEN1, 5 * ALPHA), 5e18);
    }

    function test_gas_previewUnwrap() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        _wrap(alice, NETUID1);
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        lens.previewUnwrap(TOKEN1, shares / 2);
        vm.snapshotGasLastCall("AlphaVaultLens", "previewUnwrap");

        _assertQuotesHalfOfTenAlpha(shares);
    }

    function test_gas_claimableTaoOf() public {
        _seedClaimableTao();

        lens.claimableTaoOf(alice, TOKEN1);
        vm.snapshotGasLastCall("AlphaVaultLens", "claimableTaoOf");

        assertEq(lens.claimableTaoOf(alice, TOKEN1), 3 * TAO);
    }

    // Repeating one id measures the loop, not cold reads across independent positions.
    function test_gas_batchClaimableTaoOf_20RepeatedIds() public {
        _seedClaimableTao();
        uint256[] memory ids = new uint256[](20);
        for (uint256 i = 0; i < ids.length; i++) {
            ids[i] = TOKEN1;
        }

        lens.batchClaimableTaoOf(alice, ids);
        vm.snapshotGasLastCall("AlphaVaultLens", "batchClaimableTaoOf (20 repeated ids)");

        _assertEveryQuoteIsThreeTao(ids);
    }

    function test_gas_batchClaimableTaoOf_20DistinctPositions() public {
        uint256[] memory ids = new uint256[](20);
        for (uint256 i; i < ids.length; ++i) {
            uint256 netuid = 100 + i;
            _registerSubnet(netuid, hotkey1);
            _depositAndWrap(alice, netuid, 10 * ALPHA);
            ids[i] = vault.currentTokenId(netuid);
            _donateToClone(vault.subnetClone(ids[i]), 3 * TAO);
        }

        lens.batchClaimableTaoOf(alice, ids);
        vm.snapshotGasLastCall("AlphaVaultLens", "batchClaimableTaoOf (20 distinct positions)");

        _assertEveryQuoteIsThreeTao(ids);
    }

    function _seedClaimableTao() private {
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        _wrap(alice, NETUID1);
        _donateToClone(vault.subnetClone(TOKEN1), 3 * TAO);
    }

    function _assertEveryQuoteIsThreeTao(uint256[] memory ids) private view {
        uint256[] memory amounts = lens.batchClaimableTaoOf(alice, ids);
        assertEq(amounts.length, ids.length);
        for (uint256 i; i < amounts.length; ++i) {
            assertEq(amounts[i], 3 * TAO, "alice holds every share of each gifted position");
        }
    }

    function _assertQuotesHalfOfTenAlpha(uint256 shares) private view {
        (uint256 alpha, uint256 tao) = lens.previewUnwrap(TOKEN1, shares / 2);
        assertEq(alpha, 5 * ALPHA);
        assertEq(tao, 0);
    }

    function _stakeOfAliceAcrossTheAttestedSet() private view returns (uint256) {
        return _stakeAcross(_attestedHotkeys(NETUID1), _toSubstrate(alice), NETUID1);
    }

    function test_gas_wrap_firstWrap_10Validators() public {
        _setValidatorCount(NETUID1, VALIDATOR_CAP);
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        _wrap(alice, NETUID1);
        vm.snapshotGasLastCall("AlphaVault", "wrap: first (10 validators)");

        assertEq(vault.balanceOf(alice, TOKEN1), 1e19);
        assertEq(vault.recordedSlots(TOKEN1).length, 10, "one slot per validator");
    }

    function test_gas_wrap_subsequentWrap_10Validators() public {
        _setValidatorCount(NETUID1, VALIDATOR_CAP);
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        _wrap(alice, NETUID1);

        _simulateAlphaDeposit(bob, NETUID1, 5 * ALPHA);
        _wrap(bob, NETUID1);
        vm.snapshotGasLastCall("AlphaVault", "wrap: subsequent (10 validators)");

        assertEq(vault.balanceOf(bob, TOKEN1), 5e18);
    }

    function test_gas_unwrap_partial_10Validators() public {
        _setValidatorCount(NETUID1, VALIDATOR_CAP);
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        _wrap(alice, NETUID1);
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice), 0);
        vm.snapshotGasLastCall("AlphaVault", "unwrap: partial (10 validators)");

        assertEq(_stakeOfAliceAcrossTheAttestedSet(), 5 * ALPHA);
    }

    function test_gas_unwrap_full_10Validators() public {
        _setValidatorCount(NETUID1, VALIDATOR_CAP);
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        _wrap(alice, NETUID1);
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
        vm.snapshotGasLastCall("AlphaVault", "unwrap: full (10 validators)");

        assertEq(_stakeOfAliceAcrossTheAttestedSet(), 10 * ALPHA);
        assertEq(vault.totalSupply(TOKEN1), 0);
    }

    function test_gas_unwrapForTao_full_10Validators() public {
        _setValidatorCount(NETUID1, VALIDATOR_CAP);
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        _wrap(alice, NETUID1);
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);
        vm.snapshotGasLastCall("AlphaVault", "unwrapForTao: full (10 validators)");

        assertEq(alice.balance, 0.5e18, "10 alpha sold at 0.05 TAO");
        assertEq(vault.totalSupply(TOKEN1), 0);
    }

    // A registry rotation must not widen the TAO path, which reads only recorded keys.
    function test_gas_unwrapForTao_fullyRotated_10Validators() public {
        _setValidatorCount(NETUID1, VALIDATOR_CAP);
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        _wrap(alice, NETUID1);
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        _setValidators(NETUID1, _hotkeysFrom("rotated", VALIDATOR_CAP), _evenWeights(VALIDATOR_CAP));

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);
        vm.snapshotGasLastCall("AlphaVault", "unwrapForTao: full after a rotation (10 validators)");

        assertEq(alice.balance, 0.5e18, "the recorded hotkeys sell all 10 alpha at 0.05 TAO");
        assertEq(vault.totalSupply(TOKEN1), 0);
    }

    function test_gas_rebalance_fullyRotated_10Validators() public {
        _setValidatorCount(NETUID1, VALIDATOR_CAP);
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        _wrap(alice, NETUID1);

        bytes32[] memory rotated = _hotkeysFrom("rotated", VALIDATOR_CAP);
        _setValidators(NETUID1, rotated, _evenWeights(VALIDATOR_CAP));

        vault.rebalance(NETUID1);
        vm.snapshotGasLastCall("AlphaVault", "rebalance: fully rotated (10 validators)");

        assertEq(_vaultStakeAcross(rotated, NETUID1), 10 * ALPHA, "the whole position moved onto the new set");
        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, rotated[0]);
    }

    function test_gas_syncBacking_10Validators() public {
        _setValidatorCount(NETUID1, VALIDATOR_CAP);
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        _wrap(alice, NETUID1);
        _sweepDuringCrash(NETUID1, _attestedHotkeys(NETUID1)[0]);

        vault.syncBacking(TOKEN1);
        vm.snapshotGasLastCall("AlphaVault", "syncBacking: loss on file (10 validators)");

        (uint256 shortSince,) = vault.recovery(TOKEN1);
        assertEq(shortSince, block.timestamp, "the loss is on file");
    }

    function test_gas_rebalance_cutEdge() public {
        _depositAndWrap(alice, NETUID1, 10 * ALPHA);
        _cutTheEdge(hotkey1, hotkey4);

        vault.rebalance(NETUID1);
        vm.snapshotGasLastCall("AlphaVault", "rebalance: resolve a cut edge");

        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, hotkey4);
    }

    function test_gas_wrap_subsequentWrap_cutEdge() public {
        _depositAndWrap(alice, NETUID1, 10 * ALPHA);
        _cutTheEdge(hotkey1, hotkey4);

        _simulateAlphaDeposit(bob, NETUID1, 5 * ALPHA);
        _wrap(bob, NETUID1);
        vm.snapshotGasLastCall("AlphaVault", "wrap: subsequent, resolve a cut edge");

        assertEq(_getVaultStake(hotkey1, NETUID1), 0);
        assertEq(vault.balanceOf(bob, TOKEN1), 5e18);
    }

    function test_gas_unwrap_partial_cutEdge() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 10 * ALPHA);
        _cutTheEdge(hotkey1, hotkey4);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice), 0);
        vm.snapshotGasLastCall("AlphaVault", "unwrap: partial, resolve a cut edge");

        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), 5 * ALPHA);
        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, hotkey4);
    }

    function test_gas_syncBacking_recordCutEdge() public {
        _depositAndWrap(alice, NETUID1, 10 * ALPHA);
        _cutTheEdge(hotkey1, hotkey4);

        vault.syncBacking(TOKEN1);
        vm.snapshotGasLastCall("AlphaVault", "syncBacking: record a cut edge");

        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, hotkey4);
    }

    function test_gas_previewUnwrap_cutEdge() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 10 * ALPHA);
        _cutTheEdge(hotkey1, hotkey4);

        lens.previewUnwrap(TOKEN1, shares / 2);
        vm.snapshotGasLastCall("AlphaVaultLens", "previewUnwrap: resolve a cut edge");

        _assertQuotesHalfOfTenAlpha(shares);
    }

    function test_gas_rebalance_refusedSweptSlot_fullStakingList_10Validators() public {
        bytes32[] memory hotkeys = _setValidatorCount(NETUID1, VALIDATOR_CAP);
        _depositAndWrap(alice, NETUID1, 10 * ALPHA);
        _fillListTo(_subnetColdkey(NETUID1), STAKING_LIST_CAP - 2);
        _sweepDuringCrash(NETUID1, hotkeys[0]);

        uint256 before = gasleft();
        (bool ok, bytes memory reason) = address(vault).call(abi.encodeCall(vault.rebalance, (NETUID1)));
        vm.snapshotValue(
            "AlphaVault", "rebalance: refused on a swept slot, full staking list (10 validators)", before - gasleft()
        );

        assertFalse(ok, "the swept slot is short");
        assertEq(reason, abi.encodeWithSelector(BackingShortfall.selector, uint16(NETUID1), hotkeys[0], ALPHA));
    }

    function test_gas_rebalance_cutEdge_fullStakingList_10Validators() public {
        bytes32[] memory hotkeys = _setValidatorCount(NETUID1, VALIDATOR_CAP);
        _depositAndWrap(alice, NETUID1, 10 * ALPHA);
        _fillListTo(_subnetColdkey(NETUID1), STAKING_LIST_CAP - 2);
        _simulateOffVaultSwap(NETUID1, hotkeys[0], keccak256("edgeless destination"));

        vault.rebalance(NETUID1);
        vm.snapshotGasLastCall(
            "AlphaVault", "rebalance: resolve a cut edge through a full staking list (10 validators)"
        );

        assertEq(lens.totalStake(TOKEN1), 10 * ALPHA);
        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, keccak256("edgeless destination"));
    }

    function test_gas_recoverStray_10Validators() public {
        _setValidatorCount(NETUID1, VALIDATOR_CAP);
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        _wrap(alice, NETUID1);
        uint256 swept = _sweepDuringCrash(NETUID1, _attestedHotkeys(NETUID1)[0]);
        vault.syncBacking(TOKEN1);
        bytes32 tip = keccak256("returned elsewhere");
        _strangerReturns(NETUID1, tip, swept);

        vault.recoverStray(TOKEN1, tip);
        vm.snapshotGasLastCall("AlphaVault", "recoverStray: collect one source (10 validators)");

        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), 10 * ALPHA);
        assertEq(_parkedStake(NETUID1), 10 * ALPHA);
    }

    function test_gas_recoverStray_merged_10Validators() public {
        bytes32[] memory hotkeys = _setValidatorCount(NETUID1, VALIDATOR_CAP);
        _depositAndWrap(alice, NETUID1, 10 * ALPHA);
        bytes32 source = keccak256("merged-recovery");
        uint256 swept;
        for (uint256 i; i < hotkeys.length; ++i) {
            swept += _sweepDuringCrash(NETUID1, hotkeys[i]);
        }
        vault.syncBacking(TOKEN1);
        _strangerReturns(NETUID1, source, swept);

        vault.recoverStray(TOKEN1, source);
        vm.snapshotGasLastCall("AlphaVault", "recoverStray: collect merged source (10 validators)");

        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), 10 * ALPHA);
        assertEq(lens.writeOffDeadline(TOKEN1), 0);
        assertEq(_getVaultStake(source, NETUID1), 0);
    }

    function test_gas_rebalance_releaseParked_10Validators() public {
        _setValidatorCount(NETUID1, VALIDATOR_CAP);
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        _wrap(alice, NETUID1);
        uint256 swept = _sweepDuringCrash(NETUID1, _attestedHotkeys(NETUID1)[0]);
        vault.syncBacking(TOKEN1);
        bytes32 tip = keccak256("returned elsewhere");
        _strangerReturns(NETUID1, tip, swept);
        vault.recoverStray(TOKEN1, tip);
        vault.syncBacking(TOKEN1);
        _reattestValidators(NETUID1);

        vault.rebalance(NETUID1);
        vm.snapshotGasLastCall("AlphaVault", "rebalance: release parked position (10 validators)");

        assertFalse(vault.awaitingAttestation(TOKEN1));
        assertEq(_parkedStake(NETUID1), 0);
    }

    function test_gas_previewUnwrap_10Validators() public {
        _setValidatorCount(NETUID1, VALIDATOR_CAP);
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        _wrap(alice, NETUID1);
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        lens.previewUnwrap(TOKEN1, shares / 2);
        vm.snapshotGasLastCall("AlphaVaultLens", "previewUnwrap (10 validators)");

        _assertQuotesHalfOfTenAlpha(shares);
    }
}

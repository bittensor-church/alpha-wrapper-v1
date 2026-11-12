// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { DepositScenarios } from "./helpers/DepositScenarios.sol";

/// @dev Every entry point keeps working on a replaced clone, at realistic deposits, validator counts and prices.
contract CloneReplacementTest is DepositScenarios {
    bytes32 private constant UID = keccak256("replacement-uid");
    address private carol = makeAddr("carol");

    function _fillAndRotate(uint256 count) private returns (bytes32[] memory next) {
        _fillListTo(_subnetColdkey(NETUID1), STAKING_LIST_CAP - 1);
        next = _hotkeysFrom("next-set", count);
        _setValidators(NETUID1, next, _evenWeights(count));
    }

    function _fundedHotkeys(bytes32[] memory hotkeys) private view returns (uint256 funded) {
        for (uint256 i; i < hotkeys.length; ++i) {
            if (_getVaultStake(hotkeys[i], NETUID1) != 0) ++funded;
        }
    }

    function testFuzz_Replacement_KeepsEveryQuoteAndRecord(uint256 count, uint256 deposit, uint256 priceRao) public {
        count = bound(count, 1, VALIDATOR_CAP);
        deposit = bound(deposit, MIN_SPREADABLE, 1_000_000 * ALPHA);
        _setAlphaPrice(NETUID1, _wholeRaoPrice(priceRao));
        bytes32[] memory hks = _setValidatorCount(NETUID1, count);
        uint256 shares = _depositAndWrap(alice, NETUID1, deposit);
        _depositAndWrap(bob, NETUID1, deposit / 3);
        uint256 total = deposit + deposit / 3;
        bytes32[] memory next = _fillAndRotate(count);

        vault.replaceClone(TOKEN1, UID);

        (uint256 unwrapQuote,) = lens.previewUnwrap(TOKEN1, shares);
        assertEq(lens.totalStake(TOKEN1), total, "total stake");
        assertEq(lens.sharePrice(TOKEN1), 1e9, "share price");
        assertEq(lens.previewWrap(TOKEN1, ALPHA), 1e18, "wrap quote");
        assertEq(unwrapQuote, deposit, "unwrap quote");
        assertEq(lens.locatedStake(TOKEN1), total, "located backing");
        assertEq(lens.lastSeenHotkeys(TOKEN1), hks, "recorded hotkeys");
        assertTrue(lens.isBackingIntact(TOKEN1));
        assertEq(_stakeAcross(hks, _subnetColdkey(NETUID1), NETUID1), total, "the successor holds the whole position");
        assertEq(_stakingHotkeyCount(_subnetColdkey(NETUID1)), _fundedHotkeys(hks), "the successor lists its piles");

        vault.rebalance(NETUID1);
        assertEq(lens.totalStake(TOKEN1), total, "the rotation onto the new set loses nothing");
        assertEq(_vaultStakeAcross(next, NETUID1), total, "the whole position sits on the new set");
    }

    function testFuzz_Replacement_ThenExitsPayTheQuote(uint256 count, uint256 deposit, uint256 burnBps) public {
        count = bound(count, 1, VALIDATOR_CAP);
        deposit = bound(deposit, MIN_SPREADABLE, 1_000_000 * ALPHA);
        // Alice keeps at least 1% to exit afterwards, which clears the floor on any campaign deposit.
        burnBps = bound(burnBps, 100, BPS_BASE - 100);
        _setValidatorCount(NETUID1, count);
        uint256 aliceShares = _depositAndWrap(alice, NETUID1, deposit);
        uint256 bobShares = _depositAndWrap(bob, NETUID1, deposit);
        _fillAndRotate(count);
        vault.replaceClone(TOKEN1, UID);
        bytes32 aliceColdkey = _toSubstrate(alice);

        uint256 burn = aliceShares * burnBps / BPS_BASE;
        (uint256 quotedAlpha,) = lens.previewUnwrap(TOKEN1, burn);
        vm.prank(alice);
        vault.unwrap(TOKEN1, burn, aliceColdkey, burn / 1e9);
        assertEq(quotedAlpha, burn / 1e9, "1e9 shares back each RAO");
        assertEq(_stakeAcross(_attestedHotkeys(NETUID1), aliceColdkey, NETUID1), burn / 1e9, "the exit pays its quote");

        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares - burn, aliceColdkey, 0);
        assertEq(
            lens.totalStake(TOKEN1),
            deposit + (burn % 1e9 == 0 ? 0 : 1),
            "bob's backing is left, plus the RAO alice's sub-RAO burn remainder rounds away"
        );

        bytes32[] memory set = _attestedHotkeys(NETUID1);
        uint256 expectedTao;
        for (uint256 i; i < set.length; ++i) {
            expectedTao += _getVaultStake(set[i], NETUID1) / 20 * 1e9;
        }
        uint256 taoBefore = bob.balance;
        vm.prank(bob);
        vault.unwrapForTao(TOKEN1, bobShares, 0);
        assertEq(bob.balance - taoBefore, expectedTao, "each slot drains at 0.05 TAO per alpha");
        assertEq(vault.totalSupply(TOKEN1), 0, "the last holder's full burn leaves no shares");
        assertEq(lens.totalStake(TOKEN1), 0, "a full-supply sale drains every slot");
    }

    function testFuzz_Replacement_PaysEveryHoldersTaoClaim(uint256 donation, uint256 aliceWeight) public {
        donation = bound(donation, 1e9, 1_000 * TAO);
        aliceWeight = bound(aliceWeight, 1, 99);
        _depositAndWrap(alice, NETUID1, aliceWeight * ALPHA);
        _depositAndWrap(bob, NETUID1, (100 - aliceWeight) * ALPHA);
        address clone = vault.subnetClone(TOKEN1);
        _donateToClone(clone, donation);
        vm.prank(alice);
        vault.safeTransferFrom(alice, carol, TOKEN1, 1, "");
        uint256 aliceClaim = aliceWeight * donation / 100;
        aliceClaim -= aliceClaim % 1e9;
        uint256 bobClaim = (100 - aliceWeight) * donation / 100;
        bobClaim -= bobClaim % 1e9;
        _fillAndRotate(3);

        vault.replaceClone(TOKEN1, UID);

        assertEq(lens.claimableTaoOf(alice, TOKEN1), aliceClaim, "alice's share of the donation, in whole RAO");
        assertEq(lens.claimableTaoOf(bob, TOKEN1), bobClaim, "bob's share of the donation, in whole RAO");
        assertEq(lens.claimableTaoOf(carol, TOKEN1), 0, "shares received after the donation carry no claim");
        assertEq(vault.subnetClone(TOKEN1).balance, donation, "the donation moved whole");
        assertEq(clone.balance, 0, "the old clone keeps no TAO");
        if (aliceClaim != 0) assertEq(_claimQuotedAmount(alice, TOKEN1), aliceClaim);
        if (bobClaim != 0) assertEq(_claimQuotedAmount(bob, TOKEN1), bobClaim);
        uint256 unclaimed = donation - aliceClaim - bobClaim;
        assertEq(vault.taoLiability(TOKEN1), unclaimed, "the reserve keeps only the sub-RAO residue");
        assertEq(vault.subnetClone(TOKEN1).balance, unclaimed, "and the successor still holds it");
    }

    function test_Replacement_ThenRecoveryParksAndReleasesOnTheSuccessor() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _fillAndRotate(2);
        vault.replaceClone(TOKEN1, UID);
        vault.rebalance(NETUID1);
        bytes32[] memory set = _attestedHotkeys(NETUID1);

        uint256 swept = _sweepDuringCrash(NETUID1, set[0]);
        vault.syncBacking(TOKEN1);
        assertEq(lens.missingStake(TOKEN1), 15 * ALPHA, "the swept half is missing from the successor");
        _strangerReturns(NETUID1, hotkey5, swept);
        vault.recoverStray(TOKEN1, hotkey5);
        vault.syncBacking(TOKEN1);
        assertTrue(vault.awaitingAttestation(TOKEN1), "the position rests on parking");
        assertEq(_parkedStake(NETUID1), 30 * ALPHA);

        _setValidators(NETUID1, _hotkeys(hotkey5, set[1]), _weights(5000, 5000));
        vault.rebalance(NETUID1);

        assertFalse(vault.awaitingAttestation(TOKEN1));
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "the position is whole on the successor");
    }

    function test_Replacement_ThenDissolutionRefundsFromTheSuccessor() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _fillAndRotate(3);
        vault.replaceClone(TOKEN1, UID);
        address successor = vault.subnetClone(TOKEN1);

        _simulateTaoAwardedOnDissolution(TOKEN1, 7 * TAO);
        _simulateDissolutionCompleted(NETUID1);
        (, uint256 quotedTao) = lens.previewUnwrap(TOKEN1, shares);
        uint256 before = alice.balance;
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, bytes32(0), 0);

        assertEq(alice.balance - before, 7 * TAO, "the refund pays from the successor");
        assertEq(quotedTao, 7 * TAO);
        assertEq(successor.balance, 0);
    }

    function test_Replacement_ThenSecondUserDepositsAndEveryoneExits() public {
        uint256 aliceShares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _fillAndRotate(3);
        vault.replaceClone(TOKEN1, UID);

        uint256 bobShares = _depositAndWrap(bob, NETUID1, 45 * ALPHA);
        assertEq(bobShares, 45e18, "bob is priced on the moved backing");
        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares, _toSubstrate(alice), 0);
        vm.prank(bob);
        vault.unwrap(TOKEN1, bobShares, _toSubstrate(bob), 0);

        assertEq(vault.totalSupply(TOKEN1), 0);
        assertEq(lens.totalStake(TOKEN1), 0, "the successor is drained");
        assertEq(_stakingHotkeyCount(_subnetColdkey(NETUID1)), 0, "and lists nothing");
    }
}

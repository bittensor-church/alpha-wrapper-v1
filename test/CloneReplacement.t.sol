// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { MAX_STAKING_HOTKEYS, MAX_VALIDATORS } from "src/interfaces/IValidatorRegistry.sol";

/// @dev Every entry point keeps working on a replaced clone, at realistic deposits, validator counts and prices.
contract CloneReplacementTest is AlphaVaultTestBase {
    bytes32 private constant UID = keccak256("replacement-uid");
    address private carol = makeAddr("carol");

    /// @dev Ten alpha spread ten ways keeps every slot above the 0.04-alpha move floor at 0.05 TAO per alpha.
    uint256 private constant MIN_SPREADABLE = 10 * ALPHA;

    struct Quotes {
        uint256 totalStake;
        uint256 sharePrice;
        uint256 previewWrap;
        uint256 previewUnwrap;
        uint256 located;
        bytes32[] lastSeen;
    }

    function _quotes(uint256 tokenId, uint256 shares) private view returns (Quotes memory q) {
        q.totalStake = lens.totalStake(tokenId);
        q.sharePrice = lens.sharePrice(tokenId);
        q.previewWrap = lens.previewWrap(tokenId, ALPHA);
        (q.previewUnwrap,) = lens.previewUnwrap(tokenId, shares);
        q.located = lens.locatedStake(tokenId);
        q.lastSeen = lens.lastSeenHotkeys(tokenId);
    }

    /// @dev A list one entry short of the cap and a registry naming one validator the clone never used.
    function _fillAndRotate(uint256 count) private returns (bytes32[] memory next) {
        _fillListTo(_subnetColdkey(NETUID1), MAX_STAKING_HOTKEYS - 1);
        next = _hotkeysFrom("next-set", count);
        _setValidators(NETUID1, next, _evenWeights(count));
    }

    function testFuzz_Replacement_KeepsEveryQuoteAndRecord(uint256 count, uint256 deposit, uint256 priceRao) public {
        count = bound(count, 1, MAX_VALIDATORS);
        deposit = bound(deposit, MIN_SPREADABLE, 1_000_000 * ALPHA);
        _setAlphaPrice(NETUID1, _wholeRaoPrice(priceRao));
        _setValidatorCount(NETUID1, count);
        uint256 shares = _depositAndWrap(alice, NETUID1, deposit);
        _depositAndWrap(bob, NETUID1, deposit / 3);
        Quotes memory before = _quotes(TOKEN1, shares);
        bytes32[] memory next = _fillAndRotate(count);

        vault.replaceClone(TOKEN1, UID);

        Quotes memory replaced = _quotes(TOKEN1, shares);
        assertEq(replaced.totalStake, before.totalStake, "total stake");
        assertEq(replaced.sharePrice, before.sharePrice, "share price");
        assertEq(replaced.previewWrap, before.previewWrap, "wrap quote");
        assertEq(replaced.previewUnwrap, before.previewUnwrap, "unwrap quote");
        assertEq(replaced.located, before.located, "located backing");
        assertEq(replaced.lastSeen, before.lastSeen, "recorded keys");
        assertTrue(lens.isBackingIntact(TOKEN1));
        assertEq(_stakingHotkeyCount(_subnetColdkey(NETUID1)), _fundedSlots(), "the successor lists what it holds");

        vault.rebalance(NETUID1);
        assertEq(lens.totalStake(TOKEN1), before.totalStake, "the rotation onto the new set loses nothing");
        assertEq(_vaultStakeAcross(next, NETUID1), before.totalStake, "the whole position sits on the new set");
    }

    function testFuzz_Replacement_ThenExitsPayTheQuote(uint256 count, uint256 deposit, uint256 burnBps) public {
        count = bound(count, 1, MAX_VALIDATORS);
        deposit = bound(deposit, MIN_SPREADABLE, 1_000_000 * ALPHA);
        // Alice keeps at least 1% to exit afterwards, which clears the floor on any campaign deposit.
        burnBps = bound(burnBps, 100, BPS_BASE - 100);
        _setValidatorCount(NETUID1, count);
        uint256 aliceShares = _depositAndWrap(alice, NETUID1, deposit);
        uint256 bobShares = _depositAndWrap(bob, NETUID1, deposit);
        _fillAndRotate(count);
        vault.replaceClone(TOKEN1, UID);

        uint256 burn = aliceShares * burnBps / BPS_BASE;
        (uint256 quotedAlpha,) = lens.previewUnwrap(TOKEN1, burn);
        vm.prank(alice);
        vault.unwrap(TOKEN1, burn, _toSubstrate(alice), quotedAlpha);
        assertEq(_userStakeAcrossAttested(alice), quotedAlpha, "the alpha exit pays its quote from the successor");

        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares - burn, _toSubstrate(alice), 0);
        assertApproxEqAbs(lens.totalStake(TOKEN1), deposit, count + 2, "bob's backing is what is left");

        uint256 taoBefore = bob.balance;
        vm.prank(bob);
        vault.unwrapForTao(TOKEN1, bobShares, 0);
        assertGt(bob.balance - taoBefore, 0, "the TAO exit pays from the successor");
        assertEq(vault.totalSupply(TOKEN1), 0, "the last holder's full burn leaves no shares");
        assertLe(lens.totalStake(TOKEN1), ALPHA_FLOOR, "a full-supply sale leaves at most a sub-floor remainder");
    }

    function _fundedSlots() private view returns (uint256 funded) {
        uint256[] memory balances = lens.resolvedBacking(TOKEN1).balances;
        for (uint256 i; i < balances.length; ++i) {
            if (balances[i] != 0) ++funded;
        }
    }

    function _userStakeAcrossAttested(address user) private view returns (uint256 total) {
        bytes32[] memory set = _attestedHotkeys(NETUID1);
        bytes32[] memory previous = lens.lastSeenHotkeys(TOKEN1);
        total = _stakeAcross(set, _toSubstrate(user), NETUID1);
        for (uint256 i; i < previous.length; ++i) {
            if (!_containsKey(set, previous[i])) {
                total += _getStakeForColdkey(previous[i], _toSubstrate(user), NETUID1);
            }
        }
    }

    function _containsKey(bytes32[] memory set, bytes32 key) private pure returns (bool) {
        for (uint256 i; i < set.length; ++i) {
            if (set[i] == key) return true;
        }
        return false;
    }

    function testFuzz_Replacement_PaysEveryHoldersTaoClaim(uint256 donation, uint256 aliceWeight) public {
        donation = bound(donation, EXISTENTIAL_DEPOSIT, 1_000 * TAO);
        aliceWeight = bound(aliceWeight, 1, 99);
        _depositAndWrap(alice, NETUID1, aliceWeight * ALPHA);
        _depositAndWrap(bob, NETUID1, (100 - aliceWeight) * ALPHA);
        address clone = vault.subnetClone(TOKEN1);
        _donateToClone(clone, donation);
        vm.prank(alice);
        vault.safeTransferFrom(alice, carol, TOKEN1, 1, "");
        uint256 aliceClaim = lens.claimableTaoOf(alice, TOKEN1);
        uint256 bobClaim = lens.claimableTaoOf(bob, TOKEN1);
        _fillAndRotate(3);

        vault.replaceClone(TOKEN1, UID);

        assertEq(lens.claimableTaoOf(alice, TOKEN1), aliceClaim, "alice's claim survives");
        assertEq(lens.claimableTaoOf(bob, TOKEN1), bobClaim, "bob's claim survives");
        assertEq(vault.subnetClone(TOKEN1).balance, donation, "the donation moved whole");
        if (aliceClaim != 0) _claimQuotedAmount(alice, TOKEN1);
        if (bobClaim != 0) _claimQuotedAmount(bob, TOKEN1);
        assertLe(vault.taoLiability(TOKEN1), vault.subnetClone(TOKEN1).balance, "liabilities stay backed");
    }

    /// @dev The chain hides the existential deposit from a fresh account's balance; the mock does not, so the
    ///      hidden part is taken off the old clone's balance before the move.
    function test_Replacement_CapsTheLiabilityAtWhatTheSuccessorShows() public {
        _depositAndWrap(alice, NETUID1, 60 * ALPHA);
        _depositAndWrap(bob, NETUID1, 40 * ALPHA);
        address clone = vault.subnetClone(TOKEN1);
        _donateToClone(clone, TAO);
        vm.prank(alice);
        vault.safeTransferFrom(alice, carol, TOKEN1, 1, "");
        uint256 liability = vault.taoLiability(TOKEN1);
        assertEq(liability, TAO, "the donation is owed in full");
        vm.deal(clone, TAO - EXISTENTIAL_DEPOSIT);
        _fillAndRotate(3);

        vault.replaceClone(TOKEN1, UID);

        assertEq(vault.taoLiability(TOKEN1), TAO - EXISTENTIAL_DEPOSIT, "the liability drops to what shows");
        uint256 aliceClaim = lens.claimableTaoOf(alice, TOKEN1);
        uint256 bobClaim = lens.claimableTaoOf(bob, TOKEN1);
        assertEq(aliceClaim + bobClaim, TAO, "entitlements are kept in full");
        assertEq(_claimQuotedAmount(alice, TOKEN1), aliceClaim, "the first claim is whole");
        assertEq(_claimQuotedAmount(bob, TOKEN1), bobClaim - EXISTENTIAL_DEPOSIT, "the last claim gives the deposit up");
        assertEq(vault.subnetClone(TOKEN1).balance, 0, "and pays instead of reverting");
    }

    function test_Replacement_ThenRecoveryParksAndReleasesOnTheSuccessor() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _fillAndRotate(2);
        vault.replaceClone(TOKEN1, UID);
        vault.rebalance(NETUID1);
        bytes32[] memory set = _attestedHotkeys(NETUID1);

        _simulateOffVaultSwap(NETUID1, set[0], hotkey5);
        vault.syncBacking(TOKEN1);
        assertEq(lens.missingStake(TOKEN1), 15 * ALPHA, "the swapped half is missing from the successor");
        vault.recoverStray(TOKEN1, hotkey5);
        vault.syncBacking(TOKEN1);
        assertTrue(vault.awaitingAttestation(TOKEN1), "the position rests on parking");
        assertApproxEqAbs(_parkedStake(NETUID1), 30 * ALPHA, 2);

        _setValidators(NETUID1, _hotkeys(hotkey5, set[1]), _weights(5000, 5000));
        vault.rebalance(NETUID1);

        assertFalse(vault.awaitingAttestation(TOKEN1));
        assertApproxEqAbs(lens.totalStake(TOKEN1), 30 * ALPHA, 4, "the position is whole on the successor");
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
        assertEq(bobShares, aliceShares * 3 / 2, "bob is priced on the moved backing");
        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares, _toSubstrate(alice), 0);
        vm.prank(bob);
        vault.unwrap(TOKEN1, bobShares, _toSubstrate(bob), 0);

        assertEq(vault.totalSupply(TOKEN1), 0);
        assertLe(lens.totalStake(TOKEN1), 4, "the successor is drained to rounding");
        assertEq(_stakingHotkeyCount(_subnetColdkey(NETUID1)), 0, "and lists nothing");
    }
}

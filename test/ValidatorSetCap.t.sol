// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { MAX_VALIDATORS } from "src/interfaces/IValidatorRegistry.sol";
import { ValidatorSetTooLarge } from "src/VaultErrors.sol";

contract ValidatorSetCapTest is AlphaVaultTestBase {
    uint256 private constant DEPOSIT = 10 ether;
    uint256 private constant OVER_CAP = MAX_VALIDATORS + 1;

    function _publishSet(uint256 hotkeyCount, uint256 weightCount) private returns (bytes32[] memory hks) {
        hks = _hotkeysFrom("oversized", hotkeyCount);
        _recordHotkeyOwners(hks);
        registry.setRaw(NETUID1, hks, _evenWeights(weightCount));
    }

    function _publishOversizedSet() private returns (bytes32[] memory hks) {
        return _publishSet(OVER_CAP, OVER_CAP);
    }

    function _fundedPositionThenOversizedSet() private returns (uint256 shares) {
        shares = _depositAndWrap(alice, NETUID1, DEPOSIT);
        _publishOversizedSet();
    }

    function _expectTooLarge(uint256 count) private {
        vm.expectRevert(abi.encodeWithSelector(ValidatorSetTooLarge.selector, count));
    }

    function test_WrapAcceptsExactlyMaxValidators() public {
        bytes32[] memory hks = _setValidatorCount(NETUID1, MAX_VALIDATORS);
        _depositAndWrap(alice, NETUID1, DEPOSIT);

        assertEq(lens.totalStake(TOKEN1), DEPOSIT, "the cap itself is a valid set");
        assertEq(_lastSeen(TOKEN1).length, MAX_VALIDATORS, "every attested name is recorded");
        _assertEvenSpread(hks, NETUID1, DEPOSIT);
    }

    function test_AlphaUnwrapAcceptsExactlyMaxValidators() public {
        _setValidatorCount(NETUID1, MAX_VALIDATORS);
        uint256 shares = _depositAndWrap(alice, NETUID1, DEPOSIT);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        assertEq(vault.balanceOf(alice, TOKEN1), 0, "the cap exits through the alpha path too");
        assertEq(lens.totalStake(TOKEN1), 0);
    }

    function test_RevertWhen_WrapWithValidatorSetOverCap() public {
        bytes32[] memory hks = _publishOversizedSet();
        _simulateAlphaDeposit(alice, NETUID1, DEPOSIT);

        vm.prank(alice);
        _expectTooLarge(OVER_CAP);
        vault.wrap(NETUID1, hks[0], 0);
    }

    function test_RevertWhen_RebalanceWithValidatorSetOverCap() public {
        _fundedPositionThenOversizedSet();

        _expectTooLarge(OVER_CAP);
        vault.rebalance(NETUID1);
    }

    function test_RevertWhen_AlphaUnwrapWithValidatorSetOverCap() public {
        uint256 shares = _fundedPositionThenOversizedSet();

        vm.prank(alice);
        _expectTooLarge(OVER_CAP);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
    }

    function test_OversizeIsReportedAheadOfMismatchedLengths() public {
        bytes32[] memory hks = _publishSet(OVER_CAP, MAX_VALIDATORS);
        _simulateAlphaDeposit(alice, NETUID1, DEPOSIT);

        vm.prank(alice);
        _expectTooLarge(OVER_CAP);
        vault.wrap(NETUID1, hks[0], 0);
    }

    function test_TaoUnwrapStillExitsWhenValidatorSetOverCap() public {
        uint256 shares = _fundedPositionThenOversizedSet();
        uint256 balanceBefore = alice.balance;

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(vault.balanceOf(alice, TOKEN1), 0, "the whole position exited");
        assertGt(alice.balance, balanceBefore, "and it paid out in TAO");
    }

    function test_RebalanceRecoversAfterSetShrinksBackUnderCap() public {
        _fundedPositionThenOversizedSet();

        _expectTooLarge(OVER_CAP);
        vault.rebalance(NETUID1);

        bytes32[] memory hks = _setValidatorCount(NETUID1, MAX_VALIDATORS);
        vault.rebalance(NETUID1);

        assertEq(lens.totalStake(TOKEN1), DEPOSIT, "backing survived the excursion");
        _assertEvenSpread(hks, NETUID1, DEPOSIT);
    }

    function testFuzz_RevertWhen_WrapWithValidatorSetOverCap(uint256 rawCount) public {
        uint256 count = bound(rawCount, OVER_CAP, MAX_VALIDATORS + 24);
        bytes32[] memory hks = _publishSet(count, count);
        _simulateAlphaDeposit(alice, NETUID1, DEPOSIT);

        vm.prank(alice);
        _expectTooLarge(count);
        vault.wrap(NETUID1, hks[0], 0);
    }
}

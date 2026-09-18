// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { MAX_VALIDATORS } from "src/interfaces/IValidatorRegistry.sol";
import { ValidatorSetTooLarge } from "src/VaultErrors.sol";

contract ValidatorSetCapTest is AlphaVaultTestBase {
    function _publishOversizedSet(uint256 netuid, uint256 count) private returns (bytes32[] memory hks) {
        hks = _hotkeysFrom("oversized", count);
        _recordHotkeyOwners(hks);
        registry.setRaw(netuid, hks, _evenWeights(count));
    }

    function _fundedPositionThenOversizedSet(uint256 deposit, uint256 count) private returns (uint256 shares) {
        shares = _depositAndWrap(alice, NETUID1, deposit);
        _publishOversizedSet(NETUID1, count);
    }

    function test_WrapAcceptsExactlyMaxValidators() public {
        bytes32[] memory hks = _setValidatorCount(NETUID1, MAX_VALIDATORS);
        _depositAndWrap(alice, NETUID1, 10 ether);

        assertEq(lens.totalStake(TOKEN1), 10 ether, "the cap itself is a valid set");
        assertEq(_lastSeen(TOKEN1).length, MAX_VALIDATORS, "every attested name is recorded");
        _assertEvenSpread(hks, NETUID1, 10 ether);
    }

    function test_RevertWhen_WrapWithValidatorSetOverCap() public {
        bytes32[] memory hks = _publishOversizedSet(NETUID1, MAX_VALIDATORS + 1);
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ValidatorSetTooLarge.selector, MAX_VALIDATORS + 1));
        vault.wrap(NETUID1, hks[0], 0);
    }

    function test_RevertWhen_RebalanceWithValidatorSetOverCap() public {
        _fundedPositionThenOversizedSet(10 ether, MAX_VALIDATORS + 1);

        vm.expectRevert(abi.encodeWithSelector(ValidatorSetTooLarge.selector, MAX_VALIDATORS + 1));
        vault.rebalance(NETUID1);
    }

    function test_RevertWhen_AlphaUnwrapWithValidatorSetOverCap() public {
        uint256 shares = _fundedPositionThenOversizedSet(10 ether, MAX_VALIDATORS + 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ValidatorSetTooLarge.selector, MAX_VALIDATORS + 1));
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
    }

    function test_TaoUnwrapStillExitsWhenValidatorSetOverCap() public {
        uint256 shares = _fundedPositionThenOversizedSet(10 ether, MAX_VALIDATORS + 1);
        uint256 balanceBefore = alice.balance;

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(vault.balanceOf(alice, TOKEN1), 0, "the whole position exited");
        assertGt(alice.balance, balanceBefore, "and it paid out in TAO");
    }

    function test_RebalanceRecoversAfterSetShrinksBackUnderCap() public {
        _fundedPositionThenOversizedSet(10 ether, MAX_VALIDATORS + 1);

        vm.expectRevert(abi.encodeWithSelector(ValidatorSetTooLarge.selector, MAX_VALIDATORS + 1));
        vault.rebalance(NETUID1);

        bytes32[] memory hks = _setValidatorCount(NETUID1, MAX_VALIDATORS);
        vault.rebalance(NETUID1);

        assertEq(lens.totalStake(TOKEN1), 10 ether, "backing survived the excursion");
        _assertEvenSpread(hks, NETUID1, 10 ether);
    }

    function testFuzz_RevertWhen_WrapWithValidatorSetOverCap(uint256 rawCount) public {
        uint256 count = bound(rawCount, MAX_VALIDATORS + 1, MAX_VALIDATORS + 24);
        bytes32[] memory hks = _publishOversizedSet(NETUID1, count);
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ValidatorSetTooLarge.selector, count));
        vault.wrap(NETUID1, hks[0], 0);
    }

    function testFuzz_WrapAcceptsAnySetWithinCap(uint256 rawCount) public {
        uint256 count = bound(rawCount, 1, MAX_VALIDATORS);
        bytes32[] memory hks = _setValidatorCount(NETUID1, count);
        _depositAndWrap(alice, NETUID1, 10 ether);

        assertEq(lens.totalStake(TOKEN1), 10 ether, "no set at or under the cap is rejected");
        assertEq(_lastSeen(TOKEN1).length, count);
        _assertEvenSpread(hks, NETUID1, 10 ether);
    }
}

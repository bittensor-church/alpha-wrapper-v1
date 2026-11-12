// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { DepositScenarios } from "./helpers/DepositScenarios.sol";
import { ValidatorSetTooLarge } from "src/VaultErrors.sol";

contract ValidatorSetCapTest is DepositScenarios {
    uint256 private constant OVER_CAP = 11;

    function _publishSet(uint256 hotkeyCount, uint256 weightCount) private returns (bytes32[] memory hks) {
        hks = _hotkeysFrom("oversized", hotkeyCount);
        _recordHotkeyOwners(hks);
        registry.setRaw(NETUID1, hks, _evenWeights(weightCount));
    }

    function _fundedPositionThenOversizedSet() private returns (uint256 shares) {
        shares = _depositAndWrap(alice, NETUID1, SPREAD_DEPOSIT);
        _publishSet(OVER_CAP, OVER_CAP);
    }

    function _expectTooLarge(uint256 count) private {
        vm.expectRevert(abi.encodeWithSelector(ValidatorSetTooLarge.selector, count));
    }

    function test_Unwrap_AcceptsExactlyMaxValidators() public {
        bytes32[] memory hks = _setValidatorCount(NETUID1, VALIDATOR_CAP);
        uint256 shares = _depositAndWrap(alice, NETUID1, SPREAD_DEPOSIT);
        bytes32 aliceColdkey = _toSubstrate(alice);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, aliceColdkey, 0);

        assertEq(vault.balanceOf(alice, TOKEN1), 0, "the cap exits through the alpha path too");
        assertEq(lens.totalStake(TOKEN1), 0);
        assertEq(_stakeAcross(hks, aliceColdkey, NETUID1), SPREAD_DEPOSIT, "all ten slots reach the holder");
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

    function test_RevertWhen_OversizedSetAlsoHasMismatchedLengths() public {
        _simulateAlphaDeposit(alice, NETUID1, SPREAD_DEPOSIT);
        bytes32[] memory hks = _publishSet(OVER_CAP, VALIDATOR_CAP);

        vm.prank(alice);
        _expectTooLarge(OVER_CAP);
        vault.wrap(NETUID1, hks[0], 0);
    }

    function test_UnwrapForTao_ExitsWhenValidatorSetOverCap() public {
        uint256 shares = _fundedPositionThenOversizedSet();
        uint256 balanceBefore = alice.balance;

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(vault.balanceOf(alice, TOKEN1), 0, "the whole position exited");
        assertEq(alice.balance - balanceBefore, 500 * TAO, "10,000 alpha sold at 0.05 TAO");
    }

    function test_Rebalance_RecoversAfterSetShrinksBackUnderCap() public {
        _fundedPositionThenOversizedSet();

        bytes32[] memory hks = _setValidatorCount(NETUID1, VALIDATOR_CAP);
        vault.rebalance(NETUID1);

        // 1000 bps of 10,000 alpha on each of the ten validators.
        _assertSpread(hks, _subnetColdkey(NETUID1), NETUID1, 1_000 * ALPHA, 1_000 * ALPHA);
    }

    function testFuzz_RevertWhen_WrapWithValidatorSetOverCap(uint256 rawCount) public {
        uint256 count = bound(rawCount, OVER_CAP, 34);
        _simulateAlphaDeposit(alice, NETUID1, SPREAD_DEPOSIT);
        bytes32[] memory hks = _publishSet(count, count);

        vm.prank(alice);
        _expectTooLarge(count);
        vault.wrap(NETUID1, hks[0], 0);
    }
}

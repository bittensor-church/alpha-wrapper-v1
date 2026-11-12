// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { AttestedHotkeyRetired } from "src/VaultErrors.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

contract ZeroHotkeyRecoveryTest is AlphaVaultTestBase {
    bytes32 private constant ZERO = bytes32(0);
    uint256 private constant VICTIMS_DEPOSIT = 600 * ALPHA;
    uint256 private constant NONCE_AFTER_SET_UP = 2;

    MockStaking private staking;

    function setUp() public override {
        super.setUp();
        staking = MockStaking(STAKING_PRECOMPILE);
        _setValidators(NETUID1, _hotkeys(hotkey1), _weights(BPS_BASE));
    }

    function _depositOnTheOnlyValidator(uint256 deposit) private {
        _depositAndWrap(alice, NETUID1, deposit);
        assertEq(_getVaultStake(hotkey1, NETUID1), deposit, "the single validator holds the whole deposit");
    }

    function _parkFromZeroHotkey(uint256 backing) private {
        vault.syncBacking(TOKEN1);
        assertEq(_parkedStake(NETUID1), 0, "nothing is located at declaration");

        vm.expectEmit(true, true, true, true, address(vault));
        emit BackingRecovered(TOKEN1, ZERO, vault.parkingHotkey(), backing);
        vault.recoverStray(TOKEN1, ZERO);

        assertEq(_parkedStake(NETUID1), backing, "the watcher parks the whole backing from hotkey 0");
        assertEq(_getVaultStake(ZERO, NETUID1), 0, "leaving nothing under hotkey 0");
        assertEq(lens.missingStake(TOKEN1), 0, "and nothing missing");

        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingParked(TOKEN1, backing, NONCE_AFTER_SET_UP);
        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), backing, "nothing is written off");
        assertEq(lens.writeOffDeadline(TOKEN1), 0, "and the clock is gone");
    }

    function test_SwapIntoTheZeroHotkey_IsParkedAndReleasedOntoTheNextAttestation() public {
        _depositOnTheOnlyValidator(VICTIMS_DEPOSIT);
        uint256 aliceShares = vault.balanceOf(alice, TOKEN1);

        _simulatePerSubnetSwap(NETUID1, hotkey1, ZERO);
        (bool hasEdge, bytes32 edge) = staking.getHotkeySuccessor(hotkey1, uint16(NETUID1));
        assertTrue(hasEdge && edge == ZERO, "chain edge hotkey1 -> 0x0 exists");
        assertEq(_getVaultStake(ZERO, NETUID1), VICTIMS_DEPOSIT, "the clone's alpha now sits on hotkey 0");
        assertFalse(lens.isBackingIntact(TOKEN1), "a zero successor is not followed");

        _parkFromZeroHotkey(VICTIMS_DEPOSIT);
        assertTrue(vault.awaitingAttestation(TOKEN1), "the parked position waits for the attesters");

        _setValidators(NETUID1, _hotkeys(hotkey2), _weights(BPS_BASE));
        vault.rebalance(NETUID1);
        assertEq(
            _getVaultStake(hotkey2, NETUID1), VICTIMS_DEPOSIT, "the republish releases parking onto the new validator"
        );

        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares, _toSubstrate(alice), 0);
        assertEq(vault.totalSupply(TOKEN1), 0, "every share retires");
        assertEq(_getStakeForColdkey(hotkey2, _toSubstrate(alice), NETUID1), VICTIMS_DEPOSIT, "holders exit in full");
    }

    function testFuzz_SwapIntoTheZeroHotkey_IsParkedInFull(uint256 deposit) public {
        deposit = bound(deposit, ALPHA, MAX_SUBNET_ALPHA);
        _depositOnTheOnlyValidator(deposit);

        _simulatePerSubnetSwap(NETUID1, hotkey1, ZERO);
        _parkFromZeroHotkey(deposit);
    }

    function _ownerlessAttestedHotkeyBesideHeldBacking() private returns (uint256 shares) {
        shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        staking.setHotkeyOwned(ZERO, true);
        _setValidators(NETUID1, _hotkeys(hotkey4, hotkey1), _weights(5000, 5000));
        staking.setHotkeyDeleted(hotkey4, true);
    }

    function test_RevertWhen_AnOwnerlessAttestedHotkeyWouldFallBackToTheZeroHotkey() public {
        uint256 shares = _ownerlessAttestedHotkeyBesideHeldBacking();

        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey4));
        vault.rebalance(NETUID1);
        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey4));
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice), 0);
    }

    function test_OwnerlessAttestedHotkeyBesideTheOwnedZeroHotkey_LeavesTheFullAlphaExitOpen() public {
        uint256 shares = _ownerlessAttestedHotkeyBesideHeldBacking();

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        assertEq(_getStake(hotkey1, alice, NETUID1), 30 * ALPHA, "the full exit pays from the held hotkey");
        assertEq(vault.totalSupply(TOKEN1), 0, "and retires every share");
    }
}

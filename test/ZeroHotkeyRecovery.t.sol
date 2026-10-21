// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { AttestedHotkeyRetired } from "src/VaultErrors.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

contract ZeroHotkeyRecoveryTest is AlphaVaultTestBase {
    bytes32 private constant ZERO = bytes32(0);
    uint256 private constant VICTIMS_DEPOSIT = 600 * ALPHA;

    MockStaking private staking;

    function setUp() public override {
        super.setUp();
        staking = MockStaking(STAKING_PRECOMPILE);
        _setValidators(NETUID1, _hotkeys(hotkey1), _weights(BPS_BASE));
    }

    function _victimsDeposit() private returns (uint256 backing) {
        _depositAndWrap(alice, NETUID1, VICTIMS_DEPOSIT);
        backing = _getVaultStake(hotkey1, NETUID1);
    }

    function _validatorSwapsInto(bytes32 from, bytes32 to) private {
        _simulatePerSubnetSwap(NETUID1, from, to);
    }

    function _parkFromZeroHotkey(uint256 backing) private {
        vault.syncBacking(TOKEN1);
        assertEq(_parkedStake(NETUID1), 0, "nothing is located at declaration");

        vm.expectEmit(true, true, false, true, address(vault));
        emit BackingRecovered(TOKEN1, vault.parkingHotkey(), backing);
        vault.recoverStray(TOKEN1, ZERO);

        assertEq(_parkedStake(NETUID1), backing, "the watcher parks the whole backing from hotkey 0");
        assertEq(_getVaultStake(ZERO, NETUID1), 0);
        assertEq(lens.missingStake(TOKEN1), 0);

        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingParked(TOKEN1, backing, registry.nonces(NETUID1));
        vault.syncBacking(TOKEN1);
        assertEq(lens.totalStake(TOKEN1), backing, "nothing is written off");
        assertEq(lens.writeOffDeadline(TOKEN1), 0);
    }

    function test_P3LB01_SwapIntoZeroHotkey_IsParkedAndReleasedOntoTheNextAttestation() public {
        uint256 backing = _victimsDeposit();
        uint256 aliceShares = vault.balanceOf(alice, TOKEN1);

        _validatorSwapsInto(hotkey1, ZERO);
        (bool hasEdge, bytes32 edge) = staking.getHotkeySuccessor(hotkey1, uint16(NETUID1));
        assertTrue(hasEdge && edge == ZERO, "chain edge hotkey1 -> 0x0 exists");
        assertEq(_getVaultStake(ZERO, NETUID1), backing, "the clone's alpha now sits on hotkey 0");
        assertFalse(lens.isBackingIntact(TOKEN1), "a zero successor is not followed");

        _parkFromZeroHotkey(backing);
        assertTrue(vault.awaitingAttestation(TOKEN1));

        _setValidators(NETUID1, _hotkeys(hotkey2), _weights(BPS_BASE));
        vault.rebalance(NETUID1);
        assertEq(_getVaultStake(hotkey2, NETUID1), backing, "the republish releases parking onto the new validator");

        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares, _toSubstrate(alice), 0);
        assertEq(vault.totalSupply(TOKEN1), 0);
        assertEq(_getStakeForColdkey(hotkey2, _toSubstrate(alice), NETUID1), backing, "holders exit in full");
    }

    function testFuzz_SwapIntoZeroHotkey_IsParkedInFull(uint256 deposit) public {
        deposit = bound(deposit, ALPHA, MAX_SUBNET_ALPHA);
        _depositAndWrap(alice, NETUID1, deposit);
        uint256 backing = _getVaultStake(hotkey1, NETUID1);

        _validatorSwapsInto(hotkey1, ZERO);
        _parkFromZeroHotkey(backing);
    }

    function _ownerlessNameBesideHeldBacking() private returns (uint256 shares) {
        shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        staking.setHotkeyOwned(ZERO, true);
        _setValidators(NETUID1, _hotkeys(hotkey4, hotkey1), _weights(5000, 5000));
        staking.setHotkeyDeleted(hotkey4, true);
    }

    function test_RevertWhen_AnOwnerlessNameWouldFallBackToTheZeroHotkey() public {
        uint256 shares = _ownerlessNameBesideHeldBacking();

        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey4));
        vault.rebalance(NETUID1);
        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey4));
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice), 0);
    }

    function test_OwnerlessNameBesideTheOwnedZeroHotkey_LeavesTheFullAlphaExitOpen() public {
        uint256 shares = _ownerlessNameBesideHeldBacking();

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        assertEq(_getStake(hotkey1, alice, NETUID1), 30 * ALPHA, "the full exit pays from the held key");
    }
}

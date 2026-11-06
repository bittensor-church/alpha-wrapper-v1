// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE, MAX_STAKING_HOTKEYS } from "src/interfaces/IStaking.sol";
import { AttestedHotkeyRetired } from "src/VaultErrors.sol";

contract StrandedStakeClaimTest is AlphaVaultTestBase {
    bytes32 private constant PROTECTED_COLDKEY = keccak256("ml-dsa-coldkey");
    bytes32 private constant UID = keccak256("successor-uid");

    function _strandFirstSlot(uint256 deposit) private returns (uint256 shares) {
        shares = _depositAndWrap(alice, NETUID1, deposit);
        _simulateSwapStrandingVaultStake(NETUID1, hotkey1, hotkey4);
    }

    function _assertClaimedBy(bytes32 hotkey, bytes32 coldkey) private view {
        (bool exists, bytes32 owner) = MockStaking(STAKING_PRECOMPILE).getHotkeyOwner(hotkey);
        assertTrue(exists, "the hotkey has an owner record again");
        assertEq(owner, coldkey, "the account holding the stake owns the hotkey");
        assertEq(_stakingHotkeyCount(_toSubstrate(address(vault))), 1, "the vault lists only the parking hotkey");
    }

    function _userStake(address user, bytes32 hotkey) private view returns (uint256) {
        return MockStaking(STAKING_PRECOMPILE).getStake(hotkey, _toSubstrate(user), NETUID1);
    }

    function test_StrandedSlot_BlocksDepositsAlignmentAndPartialExits() public {
        uint256 shares = _strandFirstSlot(30 * ALPHA);

        _simulateAlphaDeposit(bob, NETUID1, 6 * ALPHA);
        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey1));
        _wrapHotkey(bob, NETUID1, hotkey2);
        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey1));
        vault.rebalance(NETUID1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey1));
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 0);

        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "the stranded alpha still counts");
    }

    function testFuzz_FullUnwrap_ClaimsTheStrandedHotkeyForTheClone(uint256 deposit) public {
        deposit = bound(deposit, 10 * ALPHA, 1_000_000 * ALPHA);
        uint256 shares = _strandFirstSlot(deposit);
        bytes32 cloneColdkey = _subnetColdkey(NETUID1);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        _assertClaimedBy(hotkey1, cloneColdkey);
        assertEq(
            _listedHotkeys(cloneColdkey), _hotkeys(hotkey1), "the claim adds no entry beyond the one the crumb keeps"
        );
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "the stranded pile left the clone");
        assertApproxEqAbs(
            _userStake(alice, hotkey1) + _userStake(alice, hotkey2) + _userStake(alice, hotkey3),
            deposit,
            3,
            "and reached the holder"
        );
    }

    function testFuzz_UnwrapForTao_ClaimsTheStrandedHotkeyForTheClone(uint256 deposit) public {
        deposit = bound(deposit, 10 * ALPHA, 1_000_000 * ALPHA);
        uint256 shares = _strandFirstSlot(deposit);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        _assertClaimedBy(hotkey1, _subnetColdkey(NETUID1));
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "the stranded pile was sold");
        assertGt(alice.balance, 0, "and paid out in TAO");
    }

    function test_Rebalance_ClaimsTheStrandedHotkeyOnceTheSuccessorIsPublished() public {
        _strandFirstSlot(30 * ALPHA);
        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );

        vault.rebalance(NETUID1);

        _assertClaimedBy(hotkey1, _subnetColdkey(NETUID1));
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "the slot left the stranded hotkey");
        assertApproxEqAbs(
            _getVaultStake(hotkey4, NETUID1), (30 * ALPHA * NETUID1_BPS_HK1) / BPS_BASE, 2, "for the successor"
        );
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "losing nothing");
    }

    function test_ReplaceClone_ClaimsTheStrandedHotkeyForTheOldClone() public {
        _strandFirstSlot(30 * ALPHA);
        bytes32 oldClone = _subnetColdkey(NETUID1);
        _fillListTo(oldClone, MAX_STAKING_HOTKEYS / 2);

        vault.replaceClone(TOKEN1, UID);

        _assertClaimedBy(hotkey1, oldClone);
        assertApproxEqAbs(
            _getVaultStake(hotkey1, NETUID1),
            (30 * ALPHA * NETUID1_BPS_HK1) / BPS_BASE,
            2,
            "the pile moved to the successor clone"
        );
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA);
    }

    function test_HashedSchemeHotkey_StaysFrozenUntilAProtectedAccountClaimsIt() public {
        uint256 shares = _strandFirstSlot(30 * ALPHA);
        MockStaking mock = MockStaking(STAKING_PRECOMPILE);
        mock.setHashedSchemeHotkey(hotkey1, true);

        vm.prank(alice);
        vm.expectRevert();
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
        vm.prank(alice);
        vm.expectRevert();
        vault.unwrapForTao(TOKEN1, shares, 0);
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "the alpha stays put");

        mock.setHotkeyOwner(hotkey1, PROTECTED_COLDKEY);
        mock.setHotkeyDeleted(hotkey1, false);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        (, bytes32 owner) = mock.getHotkeyOwner(hotkey1);
        assertEq(owner, PROTECTED_COLDKEY, "the claim stays with the protected account");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "and the pile left the clone");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { CloneOwner } from "src/CloneOwner.sol";
import { STAKING_PRECOMPILE, MAX_STAKING_HOTKEYS } from "src/interfaces/IStaking.sol";
import { AttestedHotkeyRetired } from "src/VaultErrors.sol";

contract StrandedStakeClaimTest is AlphaVaultTestBase {
    bytes32 private constant PROTECTED_COLDKEY = keccak256("ml-dsa-coldkey");
    bytes32 private constant UID = keccak256("successor-uid");
    address private stranger = makeAddr("stranger");

    function _fundedSlotLosesItsOwnerRecord(uint256 deposit) private returns (uint256 shares) {
        shares = _depositAndWrap(alice, NETUID1, deposit);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);
    }

    function _assertClaimedBy(bytes32 hotkey, bytes32 ownerColdkey) private view {
        (bool exists, bytes32 owner) = MockStaking(STAKING_PRECOMPILE).getHotkeyOwner(hotkey);
        assertTrue(exists, "the hotkey has an owner record again");
        assertEq(owner, ownerColdkey, "the clone's owner contract owns the hotkey");
        assertEq(_stakingHotkeyCount(_toSubstrate(address(vault))), 1, "the vault lists only the parking hotkey");
    }

    function _userStake(address user, bytes32 hotkey) private view returns (uint256) {
        return MockStaking(STAKING_PRECOMPILE).getStake(hotkey, _toSubstrate(user), NETUID1);
    }

    function test_OwnerlessFundedSlot_BlocksDepositsAlignmentAndPartialExits() public {
        uint256 shares = _fundedSlotLosesItsOwnerRecord(30 * ALPHA);

        _simulateAlphaDeposit(bob, NETUID1, 6 * ALPHA);
        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey1));
        _wrapHotkey(bob, NETUID1, hotkey2);
        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey1));
        vault.rebalance(NETUID1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey1));
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 0);

        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "the alpha still counts");
    }

    function testFuzz_FullUnwrap_ClaimsTheHotkeyForTheCloneOwner(uint256 deposit) public {
        deposit = bound(deposit, 10 * ALPHA, 1_000_000 * ALPHA);
        uint256 shares = _fundedSlotLosesItsOwnerRecord(deposit);
        bytes32 ownerColdkey = _cloneOwnerColdkey(NETUID1);
        assertEq(vault.cloneFactory().cloneOwnerOf(_subnetColdkey(NETUID1)), _ownerCandidate(vault.subnetClone(TOKEN1)));

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        _assertClaimedBy(hotkey1, ownerColdkey);
        assertEq(
            _listedHotkeys(ownerColdkey),
            _hotkeys(_subnetColdkey(NETUID1), hotkey1),
            "the claim joins the clone's own hotkey on the owner contract's list"
        );
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "the pile left the clone");
        assertApproxEqAbs(
            _userStake(alice, hotkey1) + _userStake(alice, hotkey2) + _userStake(alice, hotkey3),
            deposit,
            3,
            "and reached the holder"
        );
    }

    function testFuzz_UnwrapForTao_ClaimsTheHotkeyForTheCloneOwner(uint256 deposit) public {
        deposit = bound(deposit, 10 * ALPHA, 1_000_000 * ALPHA);
        uint256 shares = _fundedSlotLosesItsOwnerRecord(deposit);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        _assertClaimedBy(hotkey1, _cloneOwnerColdkey(NETUID1));
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "the pile was sold");
        assertGt(alice.balance, 0, "and paid out in TAO");
    }

    function test_Rebalance_ClaimsTheHotkeyOnceTheRegistryReplacesIt() public {
        _fundedSlotLosesItsOwnerRecord(30 * ALPHA);
        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );

        vault.rebalance(NETUID1);

        _assertClaimedBy(hotkey1, _cloneOwnerColdkey(NETUID1));
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "the slot left the ownerless hotkey");
        assertApproxEqAbs(
            _getVaultStake(hotkey4, NETUID1), (30 * ALPHA * NETUID1_BPS_HK1) / BPS_BASE, 2, "for its replacement"
        );
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "losing nothing");
    }

    function test_ReplaceClone_ClaimsTheHotkeyForTheOldCloneOwner() public {
        _fundedSlotLosesItsOwnerRecord(30 * ALPHA);
        bytes32 oldCloneOwner = _cloneOwnerColdkey(NETUID1);
        _fillListTo(_subnetColdkey(NETUID1), MAX_STAKING_HOTKEYS / 2);

        vault.replaceClone(TOKEN1, UID);

        _assertClaimedBy(hotkey1, oldCloneOwner);
        assertApproxEqAbs(
            _getVaultStake(hotkey1, NETUID1),
            (30 * ALPHA * NETUID1_BPS_HK1) / BPS_BASE,
            2,
            "the pile moved to the successor clone"
        );
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA);
    }

    function test_HashedSchemeHotkey_StaysFrozenUntilAProtectedAccountClaimsIt() public {
        uint256 shares = _fundedSlotLosesItsOwnerRecord(30 * ALPHA);
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

    function testFuzz_A1_StrangerCannotGrowTheCloneOwnersList(uint256 hotkeySeed, uint256 amount) public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        MockStaking mock = MockStaking(STAKING_PRECOMPILE);
        bytes32 clone = _subnetColdkey(NETUID1);
        bytes32 ownerColdkey = _cloneOwnerColdkey(NETUID1);
        bytes32 strangerHotkey = keccak256(abi.encode("stranger hotkey", hotkeySeed));
        bytes32 strangerColdkey = _toSubstrate(stranger);
        amount = bound(amount, CRUMB, 100_000 * ALPHA);
        mock.setHotkeyOwned(strangerHotkey, true);
        mock.setStake(strangerHotkey, strangerColdkey, NETUID2, amount);
        assertTrue(mock.getRejectStakingHotkeyGrowth(ownerColdkey), "the owner contract refuses list growth");
        assertEq(_listedHotkeys(ownerColdkey), _hotkeys(clone), "the owner contract lists the clone's account only");

        vm.prank(stranger);
        _expectChainRefusal();
        mock.transferStake(ownerColdkey, strangerHotkey, NETUID2, NETUID2, amount);
    }

    function test_A1_DepositLandingOnAVacatedFirstEntry_ClaimsItForTheCloneOwner() public {
        MockStaking mock = MockStaking(STAKING_PRECOMPILE);
        _setValidators(NETUID1, _hotkeys(hotkey1), _weights(BPS_BASE));
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 clone = _subnetColdkey(NETUID1);
        bytes32 ownerColdkey = _cloneOwnerColdkey(NETUID1);

        mock.setStake(hotkey1, clone, NETUID2, CRUMB);
        _setValidators(NETUID1, _hotkeys(hotkey2), _weights(BPS_BASE));
        vault.rebalance(NETUID1);
        assertEq(_listedHotkeys(clone)[0], hotkey1, "rotated-out hotkey1 stays the clone's first entry");

        mock.setHotkeyDeleted(hotkey1, true);
        _setValidators(NETUID1, _hotkeys(hotkey3), _weights(BPS_BASE));

        _simulateAlphaDeposit(bob, NETUID1, 6 * ALPHA);
        _wrapHotkey(bob, NETUID1, hotkey3);

        _assertClaimedBy(hotkey1, ownerColdkey);
        assertEq(
            _listedHotkeys(ownerColdkey), _hotkeys(clone, hotkey1), "the claim joins the owner contract's own list"
        );
        assertEq(vault.balanceOf(bob, TOKEN1), 6e18, "the deposit mints its exact share");
        assertEq(_getVaultStake(hotkey3, NETUID1), 36 * ALPHA, "all backing sits under the attested hotkey");
        assertEq(lens.totalStake(TOKEN1), 36 * ALPHA);
    }

    function test_RevertWhen_NonVaultClaimsThroughTheCloneOwner() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        CloneOwner owner = CloneOwner(_ownerCandidate(vault.subnetClone(TOKEN1)));

        vm.prank(bob);
        vm.expectRevert(CloneOwner.NotVault.selector);
        owner.tryAssociateHotkey(hotkey4);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVaultTestBase } from "../AlphaVaultTestBase.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";
import { MockStaking } from "../mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

abstract contract BackingScenarios is AlphaVaultTestBase {
    /// @dev 30 alpha at 3334 / 3333 / 3333 bps: hotkey1 holds 10.002 alpha, hotkey2 and hotkey3 9.999 each.
    uint256 internal constant FIRST_SLOT = 10_002_000_000;
    uint256 internal constant OTHER_SLOT = 9_999_000_000;
    uint256 internal constant OTHER_TWO_SLOTS = 19_998_000_000;
    uint256 internal constant REFILLED_FIRST_SLOT = 6_667_333_200;
    /// @dev 0.02 alpha: half the 0.04 alpha the vault moves at 0.05 TAO/alpha.
    uint256 internal constant DUST = ALPHA_FLOOR / 2;
    /// @dev The registry nonce setUp's attestation leaves on NETUID1.
    uint256 internal constant SETUP_NONCE = 1;

    uint256 internal constant WIDE_SET_NETUID = 9;
    uint64 internal constant WIDE_SET_REGISTERED_AT = 400;

    function _hotkeyOwner(bytes32 hotkey) internal view returns (bytes32 owner) {
        bool owned;
        (owned, owner) = MockStaking(STAKING_PRECOMPILE).getHotkeyOwner(hotkey);
        assertTrue(owned, "the hotkey has no owner record");
    }

    function _sweepEverySlot() internal returns (uint256[] memory swept) {
        bytes32[] memory hotkeys = _hotkeys(hotkey1, hotkey2, hotkey3);
        swept = new uint256[](hotkeys.length);
        for (uint256 i; i < hotkeys.length; ++i) {
            swept[i] = _sweepDuringCrash(NETUID1, hotkeys[i]);
        }
    }

    function _positionFollowingASwap(bytes32 successor) internal returns (uint256 shares) {
        shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulateFollowedSwap(NETUID1, hotkey1, successor);
        vault.rebalance(NETUID1);
    }

    /// @dev Leaves 19.998 alpha on hotkey2 and hotkey3 behind 1.9998e19 shares, with the first slot
    ///      emptied on the successor.
    function _positionWithADrainedSwap(bytes32 successor) internal {
        _positionFollowingASwap(successor);
        _drainTheFirstSlot(alice, NETUID1);
    }

    function _wideSetPosition(uint256 count, uint256 deposit)
        internal
        returns (bytes32[] memory hotkeys, uint256 tokenId)
    {
        _setRegBlock(WIDE_SET_NETUID, WIDE_SET_REGISTERED_AT);
        hotkeys = _setValidatorCount(WIDE_SET_NETUID, count);
        _simulateAlphaDeposit(alice, WIDE_SET_NETUID, deposit);
        _wrapHotkey(alice, WIDE_SET_NETUID, hotkeys[0]);
        tokenId = vault.currentTokenId(WIDE_SET_NETUID);
    }

    function _assertSlotsOnDistinctHotkeys(uint256 tokenId) internal view {
        VaultReads.Slot[] memory slots = vault.recordedSlots(tokenId);
        assertGt(slots.length, 1, "a single slot has nothing to collide with");
        for (uint256 i; i < slots.length; ++i) {
            for (uint256 j = i + 1; j < slots.length; ++j) {
                assertTrue(slots[i].stakedUnder != slots[j].stakedUnder, "no two slots answer for one hotkey");
            }
        }
    }

    function _depositOnEveryRail(bytes32 chosenHotkey) internal {
        assertEq(lens.previewWrap(TOKEN1, 30 * ALPHA), 3e19, "the wrap quote is 1e9 shares per RAO");
        assertEq(_depositAndWrap(bob, NETUID1, 30 * ALPHA), 3e19, "the wrap mints the quote");

        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        vm.prank(alice);
        vault.reclaimAlphaFromMailbox(NETUID1, _toSubstrate(alice));
        bytes32 mailboxHotkey = _mailboxColdkey(alice, NETUID1);
        assertEq(_getStake(mailboxHotkey, alice, NETUID1), 10 * ALPHA, "the reclaim returns the whole deposit");

        uint256 sharesBefore = vault.balanceOf(alice, TOKEN1);
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        _wrapHotkey(alice, NETUID1, chosenHotkey);
        assertEq(vault.balanceOf(alice, TOKEN1) - sharesBefore, 1e19, "the second wrap mints at the same rate");
    }

    function _exitOnEveryRail() internal {
        (uint256 quotedAlpha,) = lens.previewUnwrap(TOKEN1, 1.5e19);
        assertEq(quotedAlpha, 15 * ALPHA, "half of bob's shares quote half of his 30 alpha");
        vm.prank(bob);
        vault.unwrap(TOKEN1, 1.5e19, _toSubstrate(bob), 0);
        assertEq(_userStakeAcrossHotkeys(bob, NETUID1), 15 * ALPHA, "the alpha exit paid the quote");

        (uint256 quotedSale,) = lens.previewUnwrap(TOKEN1, 7.5e18);
        assertEq(quotedSale, 7_500_000_000, "a quarter of bob's shares quote a quarter of his 30 alpha");
        uint256 taoBefore = bob.balance;
        vm.prank(bob);
        vault.unwrapForTao(TOKEN1, 7.5e18, 0);
        assertEq(bob.balance - taoBefore, 0.375e18, "the TAO exit sold 7.5 alpha at 0.05 TAO/alpha");

        vault.rebalance(NETUID1);
    }

    function _assertEveryRailWorks(bytes32 chosenHotkey, uint256 backingAfter) internal {
        _depositOnEveryRail(chosenHotkey);
        _exitOnEveryRail();
        assertEq(lens.totalStake(TOKEN1), backingAfter, "the backing less the 15 alpha and 7.5 alpha exits");
        assertTrue(lens.isBackingIntact(TOKEN1), "record sound throughout");
    }
}

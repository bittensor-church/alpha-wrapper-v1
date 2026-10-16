// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { AttestedHotkeyRetired } from "src/VaultErrors.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";

contract ColdkeyLineageTest is AlphaVaultTestBase {
    MockStaking internal mock;
    bytes32 internal validatorColdkey;
    bytes32 internal constant NEXT_COLDKEY = keccak256("validator-next-coldkey");
    bytes32 internal constant THIRD_COLDKEY = keccak256("validator-third-coldkey");
    bytes32 internal constant NEWCOMER_COLDKEY = keccak256("newcomer-coldkey");

    function setUp() public override {
        super.setUp();
        mock = MockStaking(STAKING_PRECOMPILE);
        validatorColdkey = mock.ownerOf(hotkey1);
    }

    function _swapColdkey(bytes32 from, bytes32 to) internal {
        mock.simulateColdkeySwap(from, to, NETUID1, new bytes32[](0));
    }

    function _assertPricedOperationsRun(address holder) internal {
        vault.rebalance(NETUID1);
        uint256 before = lens.totalStake(TOKEN1);
        _depositAndWrap(bob, NETUID1, 10 * ALPHA);
        assertEq(lens.totalStake(TOKEN1), before + 10 * ALPHA, "the deposit joins the backing");
        uint256 shares = vault.balanceOf(holder, TOKEN1);
        vm.prank(holder);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(holder), 0);
        assertEq(vault.balanceOf(holder, TOKEN1), shares - shares / 2, "the partial exit pays");
        assertTrue(lens.isBackingIntact(TOKEN1));
    }

    function test_ValidatorColdkeySwap_KeepsTheSlotLiveWithoutANewAttestation() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        uint256 nonce = registry.nonces(NETUID1);

        _swapColdkey(validatorColdkey, NEXT_COLDKEY);

        (, bytes32 owner) = mock.getHotkeyOwner(hotkey1);
        assertEq(owner, NEXT_COLDKEY, "the hotkey answers to the new coldkey");
        assertEq(VaultReads.lineageRootOf(NEXT_COLDKEY), validatorColdkey, "which the chain links to the old one");
        _assertPricedOperationsRun(alice);
        assertEq(registry.nonces(NETUID1), nonce, "no attestation was needed");
    }

    function testFuzz_ColdkeySwapChain_KeepsTheSlotLive(uint8 hopCount) public {
        uint256 hops = bound(hopCount, 1, 8);
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);

        bytes32 current = validatorColdkey;
        for (uint256 i; i < hops; ++i) {
            bytes32 next = keccak256(abi.encode("validator-coldkey-hop", i));
            _swapColdkey(current, next);
            current = next;
            vault.rebalance(NETUID1);
        }

        assertEq(VaultReads.lineageRootOf(current), validatorColdkey, "every hop keeps the first coldkey as root");
        _assertPricedOperationsRun(alice);
    }

    function test_ReattestationAfterAColdkeySwap_RecordsTheLineageRoot() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _swapColdkey(validatorColdkey, NEXT_COLDKEY);

        _reattestCurrentSet(NETUID1);

        (,, bytes32[] memory ownerRoots) = registry.getValidators(NETUID1);
        assertEq(ownerRoots[0], validatorColdkey, "the registry stores the root, not the live coldkey");
        _swapColdkey(NEXT_COLDKEY, THIRD_COLDKEY);
        _assertPricedOperationsRun(alice);
    }

    function test_HotkeySwapAfterAColdkeySwap_IsFollowedUnderTheLineage() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _swapColdkey(validatorColdkey, NEXT_COLDKEY);

        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);

        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey4, "the successor under the new coldkey is followed");
        (, bytes32 owner) = mock.getHotkeyOwner(hotkey4);
        assertEq(owner, NEXT_COLDKEY);
        _assertPricedOperationsRun(alice);
    }

    function test_SwapIntoTheAbandonedColdkey_KeepsTheValidatorLiveAndFundsNoneOfItsHotkeys() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _swapColdkey(validatorColdkey, NEXT_COLDKEY);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);

        mock.associate(hotkey1, NEWCOMER_COLDKEY);
        _swapColdkey(NEWCOMER_COLDKEY, validatorColdkey);

        (, bytes32 owner) = mock.getHotkeyOwner(hotkey1);
        assertEq(owner, validatorColdkey, "the vacated name now answers to the abandoned coldkey");
        assertEq(VaultReads.lineageRootOf(validatorColdkey), NEWCOMER_COLDKEY, "whose root is now the newcomer's");
        vault.rebalance(NETUID1);
        assertTrue(lens.isBackingIntact(TOKEN1), "the validator stays live on its successor");

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
        _simulateAlphaDepositHotkey(bob, NETUID1, 10 * ALPHA, hotkey1);
        _wrapHotkey(bob, NETUID1, hotkey1);

        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "nothing lands on the name the newcomer holds");
        assertGt(_getVaultStake(hotkey4, NETUID1), 0, "the deposit rests on the validator's own key");
    }

    function test_SwapIntoTheLiveColdkey_BlocksUntilTheNextAttestation() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);

        _swapColdkey(NEWCOMER_COLDKEY, validatorColdkey);

        assertEq(VaultReads.lineageRootOf(validatorColdkey), NEWCOMER_COLDKEY);
        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey1));
        vault.rebalance(NETUID1);

        _reattestCurrentSet(NETUID1);

        (,, bytes32[] memory ownerRoots) = registry.getValidators(NETUID1);
        assertEq(ownerRoots[0], NEWCOMER_COLDKEY, "the refreshed attestation records the rewritten root");
        _assertPricedOperationsRun(alice);
    }
}

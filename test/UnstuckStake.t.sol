// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { DEFAULT_ALPHA_PRICE_E18 } from "./mocks/MockAlpha.sol";
import { IAlphaVaultAbi } from "src/interfaces/IAlphaVaultAbi.sol";
import { MAX_STAKING_HOTKEYS, STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import {
    AlphaTransfersDisabled,
    NoFundedHotkey,
    NotRetiredClone,
    SubnetInDissolutionBlackoutPeriod,
    UnstuckBelowFloor,
    ZeroAmount
} from "src/VaultErrors.sol";

contract UnstuckStakeTest is AlphaVaultTestBase {
    uint256 private constant DUMPED_ALPHA_PRICE_E18 = DEFAULT_ALPHA_PRICE_E18 / 100;
    uint256 private constant STRANDED_PILE = ALPHA;
    uint256 private constant DUST_PILE = 1_000_000;
    address private stranger = makeAddr("stranger");
    MockStaking private mock;

    function setUp() public override {
        super.setUp();
        mock = MockStaking(STAKING_PRECOMPILE);
    }

    function _layOutBacking(uint256 middlePile) private {
        _depositAndWrap(alice, NETUID1, 60 * ALPHA);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 30 * ALPHA;
        amounts[1] = middlePile;
        amounts[2] = 30 * ALPHA;
        _plantVaultLayout(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey3), amounts);
    }

    function _replaceCurrentClone(bytes32 uid, bytes32[] memory nextValidators) private returns (address retired) {
        retired = vault.subnetClone(TOKEN1);
        _fillListTo(_toSubstrate(retired), MAX_STAKING_HOTKEYS - 1);
        _setValidators(NETUID1, nextValidators, _weights(3334, 3333, 3333));
        vault.replaceClone(TOKEN1, uid);
    }

    function _replaceDuringAPriceDump() private returns (address retired) {
        _layOutBacking(STRANDED_PILE);
        _setAlphaPrice(NETUID1, DUMPED_ALPHA_PRICE_E18);
        retired = _replaceCurrentClone(keccak256("dump"), _hotkeys(hotkey1, hotkey2, hotkey4));
    }

    function _giftFromStranger(bytes32 coldkey, bytes32 hotkey, uint256 amount) private {
        mock.setStake(hotkey, _toSubstrate(stranger), NETUID1, amount);
        vm.prank(stranger);
        mock.transferStake(coldkey, hotkey, NETUID1, NETUID1, amount);
    }

    function test_UnstuckStake_ReturnsAPileTheReplacementSkippedDuringAPriceDump() public {
        address retired = _replaceDuringAPriceDump();
        assertEq(_getStakeForColdkey(hotkey2, _toSubstrate(retired), NETUID1), STRANDED_PILE, "the dump stranded it");
        assertEq(lens.totalStake(TOKEN1), 60 * ALPHA, "the stranded pile left the backing");
        _setAlphaPrice(NETUID1, DEFAULT_ALPHA_PRICE_E18);

        vm.expectEmit(address(vault));
        emit IAlphaVaultAbi.StakeUnstuck(TOKEN1, retired, hotkey2, hotkey1, STRANDED_PILE);
        vault.unstuckStake(TOKEN1, retired, hotkey2);

        assertEq(_getStakeForColdkey(hotkey2, _toSubstrate(retired), NETUID1), 0, "the retired clone is emptied");
        assertEq(_getVaultStake(hotkey1, NETUID1), 31 * ALPHA, "it lands on the first funded recorded key");
        assertEq(lens.totalStake(TOKEN1), 61 * ALPHA, "the backing is whole again");
    }

    function testFuzz_UnstuckStake_AddsAStrangersGiftToTheBacking(uint256 gift) public {
        gift = bound(gift, ALPHA, 1_000_000 * ALPHA);
        _layOutBacking(DUST_PILE);
        address retired = _replaceCurrentClone(keccak256("dust"), _hotkeys(hotkey1, hotkey2, hotkey4));
        _giftFromStranger(_toSubstrate(retired), hotkey2, gift);
        uint256 shares = vault.totalSupply(TOKEN1);

        vault.unstuckStake(TOKEN1, retired, hotkey2);

        assertEq(lens.totalStake(TOKEN1), 60 * ALPHA + DUST_PILE + gift, "the dust and the gift both arrive");
        assertEq(vault.totalSupply(TOKEN1), shares, "no shares are minted");
    }

    function test_UnstuckStake_FromAnEarlierCloneAfterASecondReplacement() public {
        address firstRetired = _replaceDuringAPriceDump();
        _setAlphaPrice(NETUID1, DEFAULT_ALPHA_PRICE_E18);
        vault.rebalance(NETUID1);
        _replaceCurrentClone(keccak256("second"), _hotkeys(hotkey1, hotkey3, hotkey5));

        vault.unstuckStake(TOKEN1, firstRetired, hotkey2);

        assertEq(_getStakeForColdkey(hotkey2, _toSubstrate(firstRetired), NETUID1), 0);
        assertApproxEqAbs(lens.totalStake(TOKEN1), 61 * ALPHA, 4, "the newest clone receives it");
    }

    function test_RevertWhen_UnstuckingTheCurrentClone() public {
        _replaceDuringAPriceDump();
        address current = vault.subnetClone(TOKEN1);

        vm.expectRevert(NotRetiredClone.selector);
        vault.unstuckStake(TOKEN1, current, hotkey1);
    }

    function test_RevertWhen_UnstuckingAnAddressThatWasNeverAClone() public {
        _replaceDuringAPriceDump();

        vm.expectRevert(NotRetiredClone.selector);
        vault.unstuckStake(TOKEN1, stranger, hotkey2);
    }

    function test_RevertWhen_UnstuckingIntoAnotherToken() public {
        address retired = _replaceDuringAPriceDump();
        _setAlphaPrice(NETUID1, DEFAULT_ALPHA_PRICE_E18);

        vm.expectRevert(NotRetiredClone.selector);
        vault.unstuckStake(TOKEN2, retired, hotkey2);
    }

    function test_RevertWhen_UnstuckingAHotkeyWithNoStake() public {
        address retired = _replaceDuringAPriceDump();
        _setAlphaPrice(NETUID1, DEFAULT_ALPHA_PRICE_E18);

        vm.expectRevert(ZeroAmount.selector);
        vault.unstuckStake(TOKEN1, retired, hotkey5);
    }

    function test_RevertWhen_UnstuckingWhileThePriceIsStillDumped() public {
        address retired = _replaceDuringAPriceDump();

        vm.expectRevert(UnstuckBelowFloor.selector);
        vault.unstuckStake(TOKEN1, retired, hotkey2);
    }

    function test_RevertWhen_UnstuckingWhileTransfersAreDisabled() public {
        address retired = _replaceDuringAPriceDump();
        _setAlphaPrice(NETUID1, DEFAULT_ALPHA_PRICE_E18);
        _setTransfersEnabled(NETUID1, false);

        vm.expectRevert(abi.encodeWithSelector(AlphaTransfersDisabled.selector, uint16(NETUID1)));
        vault.unstuckStake(TOKEN1, retired, hotkey2);
    }

    function test_RevertWhen_UnstuckingWhileTheSubnetDissolves() public {
        address retired = _replaceDuringAPriceDump();
        _setAlphaPrice(NETUID1, DEFAULT_ALPHA_PRICE_E18);
        _setDissolving(NETUID1, true);

        vm.expectRevert(SubnetInDissolutionBlackoutPeriod.selector);
        vault.unstuckStake(TOKEN1, retired, hotkey2);
    }

    function test_RevertWhen_TheCurrentCloneHoldsNoStake() public {
        address retired = _replaceDuringAPriceDump();
        _setAlphaPrice(NETUID1, DEFAULT_ALPHA_PRICE_E18);
        uint256 shares = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        vm.expectRevert(NoFundedHotkey.selector);
        vault.unstuckStake(TOKEN1, retired, hotkey2);
    }
}

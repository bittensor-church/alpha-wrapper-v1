// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Vm } from "forge-std/Test.sol";
import { DepositScenarios } from "./helpers/DepositScenarios.sol";
import { WithdrawTooSmall } from "src/VaultErrors.sol";
import { IAlphaVaultAbi } from "src/interfaces/IAlphaVaultAbi.sol";
import { CHAIN_MIN_STAKE, CHAIN_MIN_TRANSFER } from "./mocks/MockStaking.sol";

contract MinStakeFloorTest is DepositScenarios {
    uint256 private constant PRICE_LOW = 0.01e18;

    /// @dev Worth 0.00105 TAO at 0.05 TAO per alpha: above the move minimum, below the unstake minimum.
    uint256 private constant BETWEEN_MINIMUMS_DEPOSIT = 21_000_000;

    // The vault adds 1 RAO per alpha to the price: 2 RAO on a floor-sized pile at 0.001 TAO, plus 1 of rounding.
    uint256 private constant READ_PRICE_MARGIN = 3;

    function _setChainMinStake(uint256 minStakeTao) private {
        mock.setChainMinStake(minStakeTao);
    }

    function _oneAlphaOnTwoEvenValidators() private {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        _simulateAlphaDeposit(alice, NETUID1, ALPHA);
        _wrapHotkey(alice, NETUID1, hotkey1);
    }

    function _slotIndex(bytes32 hotkey) private view returns (uint256) {
        if (hotkey == hotkey1) return 0;
        if (hotkey == hotkey2) return 1;
        assertEq(hotkey, hotkey3, "a move names only the attested hotkeys");
        return 2;
    }

    /// @dev 0.0100000005 TAO/alpha reads as 0.01 in whole RAO, valuing 0.2 alpha at exactly the 2e6 RAO floor.
    function test_Wrap_AcceptsTheFloorAtTheTruncatedPriceRead() public {
        _setAlphaPrice(NETUID1, 0.0100000005e18);

        assertEq(_depositAndWrap(alice, NETUID1, 200_000_000), 2e17, "0.2 alpha mints 1e9 shares per RAO");
        assertEq(_getVaultStake(hotkey1, NETUID1), 200_000_000, "the sub-floor alignment leaves it whole");
        assertEq(lens.totalStake(TOKEN1), 200_000_000);
    }

    function test_RevertWhen_DepositIsOneRaoBelowTheFloorAtTheTruncatedPriceRead() public {
        _setAlphaPrice(NETUID1, 0.0100000005e18);
        _simulateAlphaDeposit(alice, NETUID1, 199_999_999);

        vm.prank(alice);
        vm.expectRevert(IAlphaVaultAbi.DepositTooSmall.selector);
        vault.wrap(NETUID1, hotkey1, 0);
    }

    function test_Rebalance_SkipsSubFloorMove() public {
        _oneAlphaOnTwoEvenValidators();

        _setAlphaPrice(NETUID1, PRICE_LOW);
        // The 0.1-alpha corrective move is worth 0.001 TAO, below the 0.002 TAO floor.
        _plantVaultStake(hotkey1, NETUID1, 600_000_000);
        _plantVaultStake(hotkey2, NETUID1, 400_000_000);

        vm.recordLogs();
        vault.rebalance(NETUID1);
        assertEq(_countLogs(vm.getRecordedLogs(), Rebalanced.selector), 0, "sub-floor move skipped pre-call");
        assertEq(_getVaultStake(hotkey1, NETUID1), 600_000_000);
        assertEq(_getVaultStake(hotkey2, NETUID1), 400_000_000);
    }

    function test_Wrap_SkipsASubFloorAlignmentMove() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(9900, 100));
        _setAlphaPrice(NETUID1, PRICE_LOW);

        // The 1% slot's 0.005-alpha move is worth 0.00005 TAO, below the chain's own move minimum.
        _simulateAlphaDeposit(alice, NETUID1, 500_000_000);
        vm.recordLogs();
        vm.prank(alice);
        vault.wrap(NETUID1, hotkey1, 0);

        assertEq(_countLogs(vm.getRecordedLogs(), Rebalanced.selector), 0, "doomed move never attempted");
        assertEq(vault.balanceOf(alice, TOKEN1), 5e17, "the wrap completed");
        assertEq(_getVaultStake(hotkey1, NETUID1), 500_000_000, "the deposit stays where it landed");
        assertEq(_getVaultStake(hotkey2, NETUID1), 0);
    }

    function test_RevertWhen_UnwrapWithAllSlotsSubFloor() public {
        _depositAndWrap(alice, NETUID1, 90_000_000);
        _plantVaultStakes(NETUID1, 30_000_000, 30_000_000, 30_000_000);

        vm.prank(alice);
        vm.expectRevert(IAlphaVaultAbi.GatherBelowFloor.selector);
        vault.unwrap(TOKEN1, 9e16, _toSubstrate(alice), 0);
    }

    function test_RevertWhen_UnwrapRequestBelowFloor() public {
        _oneAlphaOnTwoEvenValidators();
        _setAlphaPrice(NETUID1, PRICE_LOW);

        // 5% of 1 alpha is worth 0.0005 TAO.
        vm.prank(alice);
        vm.expectRevert(WithdrawTooSmall.selector);
        vault.unwrap(TOKEN1, 5e16, _toSubstrate(alice), 0);
    }

    function test_Unwrap_DeliversExactlyAtFloorValue() public {
        _depositAndWrap(alice, NETUID1, ALPHA);

        // 0.04 alpha is worth exactly 0.002 TAO.
        vm.prank(alice);
        vault.unwrap(TOKEN1, 4e16, _toSubstrate(alice), 0);

        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), 40_000_000, "a request worth exactly the floor delivers");
    }

    function test_RevertWhen_UnwrapRequestIsOneRaoBelowTheFloor() public {
        _depositAndWrap(alice, NETUID1, ALPHA);

        // 39,999,999 RAO at 0.05 TAO per alpha is worth 1,999,999 TAO RAO.
        vm.prank(alice);
        vm.expectRevert(WithdrawTooSmall.selector);
        vault.unwrap(TOKEN1, 39_999_999e9, _toSubstrate(alice), 0);
    }

    function test_RevertWhen_UnwrapBelowRaisedChainFloor() public {
        _depositAndWrap(alice, NETUID1, ALPHA);
        _setChainMinStake(5_000_000);

        // 0.06 alpha is worth 0.003 TAO, below the raised 0.005 TAO minimum.
        vm.prank(alice);
        vm.expectRevert(WithdrawTooSmall.selector);
        vault.unwrap(TOKEN1, 6e16, _toSubstrate(alice), 0);
    }

    function test_RevertWhen_WrapBetweenTheMoveAndUnstakeMinimums() public {
        _registerSubnet(99, hotkey4);
        _simulateAlphaDeposit(alice, 99, BETWEEN_MINIMUMS_DEPOSIT);

        vm.prank(alice);
        vm.expectRevert(IAlphaVaultAbi.DepositTooSmall.selector);
        vault.wrap(99, hotkey4, 0);
    }

    function test_Wrap_LandsOnceTheUnstakeMinimumFallsToTheMoveMinimum() public {
        _registerSubnet(99, hotkey4);
        _simulateAlphaDeposit(alice, 99, BETWEEN_MINIMUMS_DEPOSIT);
        _setChainMinStake(CHAIN_MIN_TRANSFER);

        _wrapHotkey(alice, 99, hotkey4);

        assertEq(
            _getVaultStake(hotkey4, 99), BETWEEN_MINIMUMS_DEPOSIT, "the chain takes it once the vault stops refusing"
        );
    }

    // Full drains bypass the minimum, so the request must be a partial sale.
    function test_RevertWhen_UnwrapForTaoBelowRaisedChainFloor() public {
        _depositAndWrap(alice, NETUID1, 10 * ALPHA);
        _setChainMinStake(10_000_000);

        // 0.1 alpha is worth 0.005 TAO: above the default minimum, below the raised 0.01 TAO.
        vm.prank(alice);
        vm.expectRevert(WithdrawTooSmall.selector);
        vault.unwrapForTao(TOKEN1, 1e17, 0);
    }

    function test_Rebalance_SkipsEveryMoveBelowRaisedChainFloor() public {
        _depositAndWrap(alice, NETUID1, ALPHA);
        _plantVaultStakes(NETUID1, 500_000_000, 250_000_000, 250_000_000);
        _setChainMinStake(50_000_000);

        vm.recordLogs();
        vault.rebalance(NETUID1);

        assertEq(
            _countLogs(vm.getRecordedLogs(), Rebalanced.selector), 0, "a raised minimum stops every corrective move"
        );
        assertEq(_getVaultStake(hotkey1, NETUID1), 500_000_000, "the split is left drifted");
    }

    function test_Rebalance_FollowsLoweredChainFloor() public {
        _depositAndWrap(alice, NETUID1, ALPHA);
        _setAlphaPrice(NETUID1, PRICE_LOW);
        _plantVaultStakes(NETUID1, 400_000_000, 300_000_000, 300_000_000);

        // Each 0.0333-alpha corrective move is worth 0.000333 TAO.
        vault.rebalance(NETUID1);
        assertEq(_getVaultStake(hotkey1, NETUID1), 400_000_000, "the corrective moves are under the current minimum");

        _setChainMinStake(300_000);
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey1, NETUID1), 333_400_000, "they land once the minimum drops below them");
        assertEq(_getVaultStake(hotkey2, NETUID1), 333_300_000);
        assertEq(_getVaultStake(hotkey3, NETUID1), 333_300_000);
    }

    function test_Wrap_ChainMinimumOfZeroLeavesTheGateOpen() public {
        _setChainMinStake(0);
        _registerSubnet(99, hotkey4);
        // 0.002 alpha is worth the chain's 0.0001 TAO move minimum.
        _simulateAlphaDeposit(alice, 99, 2_000_000);

        _wrapHotkey(alice, 99, hotkey4);

        assertEq(_getVaultStake(hotkey4, 99), 2_000_000, "a zero minimum admits whatever the chain will move");
    }

    function testFuzz_Wrap_GateBindsAtTheChainMinimum(uint256 chainMinStake, uint256 deposit) public {
        chainMinStake = bound(chainMinStake, 1, 50e6);
        deposit = bound(deposit, 1, 2 * ALPHA);
        _setChainMinStake(chainMinStake);
        _registerSubnet(99, hotkey4);
        _simulateAlphaDeposit(alice, 99, deposit);

        vm.prank(alice);
        (bool ok, bytes memory ret) = address(vault).call(abi.encodeCall(vault.wrap, (99, hotkey4, 0)));

        // TAO RAO at 0.05 TAO per alpha. The exposed unstake minimum can differ from the transfer minimum.
        uint256 depositValue = deposit / 20;
        bool clearsVaultGate = depositValue >= chainMinStake;
        bool chainWillMoveIt = depositValue >= CHAIN_MIN_TRANSFER;
        assertEq(ok, clearsVaultGate && chainWillMoveIt, "the gate binds exactly at the chain's reported minimum");

        if (!ok) {
            bytes memory expectedRefusal =
                clearsVaultGate ? bytes("") : abi.encodeWithSelector(IAlphaVaultAbi.DepositTooSmall.selector);
            assertEq(ret, expectedRefusal, "the refusal came from the bar that binds first");
        }
    }

    function test_RevertWhen_GatherBelowRaisedChainFloor() public {
        _depositAndWrap(alice, NETUID1, ALPHA);
        _plantVaultStakes(NETUID1, 350_000_000, 350_000_000, 300_000_000);
        _setChainMinStake(20_000_000);

        // The 0.5-alpha request clears the raised 0.02 TAO minimum; its richest 0.35-alpha slot does not.
        vm.prank(alice);
        vm.expectRevert(IAlphaVaultAbi.GatherBelowFloor.selector);
        vault.unwrap(TOKEN1, 5e17, _toSubstrate(alice), 0);
    }

    function test_PreviewUnwrap_QuotesWhatDustUnwrapRefuses() public {
        _depositAndWrap(alice, NETUID1, ALPHA);
        _setAlphaPrice(NETUID1, PRICE_LOW);

        (uint256 previewAlpha,) = lens.previewUnwrap(TOKEN1, 3e16);
        assertEq(previewAlpha, 30_000_000, "preview quotes the pro-rata alpha");

        vm.prank(alice);
        vm.expectRevert(WithdrawTooSmall.selector);
        vault.unwrap(TOKEN1, 3e16, _toSubstrate(alice), 0);
    }

    function testFuzz_Rebalance_AlignsByWeightDownToTheFloor(uint256 priceRao, uint256 a, uint256 b, uint256 c) public {
        uint256[3] memory balances =
            [bound(a, 0, MAX_SUBNET_ALPHA / 3), bound(b, 0, MAX_SUBNET_ALPHA / 3), bound(c, 0, MAX_SUBNET_ALPHA / 3)];
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        uint256 total = _plantVaultStakes(NETUID1, balances[0], balances[1], balances[2]);
        uint256 priceE18 = _wholeRaoPrice(priceRao);
        _setAlphaPrice(NETUID1, priceE18);

        vm.recordLogs();
        vault.rebalance(NETUID1);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(vault) || logs[i].topics[0] != Rebalanced.selector) continue;
            uint256 amount = abi.decode(logs[i].data, (uint256));
            assertGe(amount * priceE18 / 1e18, CHAIN_MIN_STAKE, "every attempted move clears the chain floor");
            balances[_slotIndex(logs[i].topics[2])] -= amount;
            balances[_slotIndex(logs[i].topics[3])] += amount;
        }
        assertEq(_getVaultStake(hotkey1, NETUID1), balances[0], "every stake change is a logged move");
        assertEq(_getVaultStake(hotkey2, NETUID1), balances[1]);
        assertEq(_getVaultStake(hotkey3, NETUID1), balances[2]);
        assertEq(lens.totalStake(TOKEN1), total, "moves conserve the position");
        // The refused move is worth under the floor, so no slot is two floors off; the last target rounds by 2 RAO.
        uint256 maxOffTarget = 2 * CHAIN_MIN_STAKE * 1e18 / priceE18 + 2;
        uint16[3] memory weights = [NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3];
        for (uint256 i; i < 3; ++i) {
            assertApproxEqAbs(balances[i], total * weights[i] / BPS_BASE, maxOffTarget, "each slot sits at its weight");
        }

        vm.recordLogs();
        vault.rebalance(NETUID1);

        logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertFalse(
                logs[i].emitter == address(vault) && logs[i].topics[0] == Rebalanced.selector,
                "a second rebalance has nothing left worth the floor"
            );
        }
        assertEq(_getVaultStake(hotkey1, NETUID1), balances[0], "the second rebalance moved nothing");
        assertEq(_getVaultStake(hotkey2, NETUID1), balances[1]);
        assertEq(_getVaultStake(hotkey3, NETUID1), balances[2]);
    }

    function testFuzz_Rebalance_ConsolidationMatchesChainFloor(uint256 dust, uint256 priceRao) public {
        dust = bound(dust, 1, MAX_SUBNET_ALPHA);
        uint256 priceE18 = _wholeRaoPrice(priceRao);
        _registerSubnet(99, hotkey4);
        _simulateAlphaDeposit(alice, 99, 10 * ALPHA);
        _wrapHotkey(alice, 99, hotkey4);
        uint256 tokenId = vault.currentTokenId(99);
        _plantVaultStake(hotkey4, 99, dust);
        _setValidators(99, _hotkeys(hotkey1), _weights(BPS_BASE));
        _setAlphaPrice(99, priceE18);
        uint256 pileValue = dust * priceE18 / 1e18;

        (bool ok, bytes memory ret) = address(vault).call(abi.encodeCall(vault.rebalance, (99)));

        if (!ok) {
            assertEq(bytes4(ret), IAlphaVaultAbi.ConsolidationBelowFloor.selector, "only the vault refuses");
            assertLt(pileValue, CHAIN_MIN_STAKE, "and only a pile worth less than the floor");
            return;
        }
        assertEq(_getVaultStake(hotkey4, 99), 0, "rotated-out stake consolidated");
        assertEq(_getVaultStake(hotkey1, 99), dust, "the whole pile landed on the attested validator");
        assertEq(lens.totalStake(tokenId), dust, "pile conserved onto the current set");
        assertGe(pileValue + READ_PRICE_MARGIN, CHAIN_MIN_STAKE, "the vault attempts only piles at the floor");
    }

    function testFuzz_Unwrap_DeliversExactlyOrRefusesAtTheFloor(
        uint256 deposit,
        uint256 a,
        uint256 b,
        uint256 shareBps,
        uint256 priceRao
    ) public {
        PlantedBurn memory burn = _burnOverAPlantedLayout(deposit, a, b, shareBps, priceRao);
        uint256 requestValue = burn.alphaWorth * burn.priceE18 / 1e18;
        uint256 largestValue = burn.largestSlot * burn.priceE18 / 1e18;
        bool needsGather = burn.alphaWorth > burn.largestSlot;
        bytes32 aliceColdkey = _toSubstrate(alice);

        vm.prank(alice);
        (bool ok, bytes memory ret) =
            address(vault).call(abi.encodeCall(vault.unwrap, (TOKEN1, burn.shares, aliceColdkey, burn.alphaWorth)));

        if (requestValue < CHAIN_MIN_STAKE) {
            assertEq(ret, abi.encodeWithSelector(WithdrawTooSmall.selector), "an exit below the floor is refused");
            return;
        }
        if (!ok) {
            assertEq(
                ret, abi.encodeWithSelector(IAlphaVaultAbi.GatherBelowFloor.selector), "an unmovable pile is refused"
            );
            assertTrue(needsGather, "only an exit larger than every slot gathers");
            assertLt(largestValue, CHAIN_MIN_STAKE, "and only from a largest slot worth less than the floor");
            return;
        }
        if (needsGather) {
            assertGe(largestValue + READ_PRICE_MARGIN, CHAIN_MIN_STAKE, "a gather starts only from a floor-worth slot");
        }
        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), burn.alphaWorth, "delivery is exact");
        assertEq(lens.totalStake(TOKEN1), burn.deposit - burn.alphaWorth, "only the delivered alpha left the vault");
    }

    function test_Unwrap_ANewValidatorsPileCarriesASubFloorSlot() public {
        _setValidators(NETUID1, _hotkeys(hotkey1), _weights(BPS_BASE));
        uint256 shares = _depositAndWrap(alice, NETUID1, ALPHA);
        _setValidators(NETUID1, _hotkeys(hotkey2), _weights(BPS_BASE));
        _strangerReturns(NETUID1, hotkey2, 10 * ALPHA);
        _setAlphaPrice(NETUID1, 0.001e18);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice), 0);

        // 5e17 * (11e9 + 1) / (1e18 + 1e9), floored.
        assertEq(_getStake(hotkey2, alice, NETUID1), 5_499_999_995, "half of the 11 alpha on the new hotkey");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "the dropped slot was consolidated");
        assertEq(_getVaultStake(hotkey2, NETUID1), 11 * ALPHA - 5_499_999_995, "the rest stays on the new hotkey");
    }

    // The pile reads as 1,999,999 TAO RAO, under the floor; the price read drops half a RAO, so its true
    // value is 2,000,000 TAO RAO.
    function test_Rebalance_ConsolidatesRichestSlotInsideOracleQuantumBand() public {
        _registerSubnet(99, hotkey4);
        _simulateAlphaDeposit(alice, 99, ALPHA);
        _wrapHotkey(alice, 99, hotkey4);

        _plantVaultStake(hotkey4, 99, 199_999_999);
        _setValidators(99, _hotkeys(hotkey1), _weights(BPS_BASE));
        _setAlphaPrice(99, 0.0100000005e18);

        vault.rebalance(99);

        assertEq(_getVaultStake(hotkey4, 99), 0, "in-band richest slot consolidated by the chain's own check");
        assertEq(_getVaultStake(hotkey1, 99), 199_999_999, "pile landed on the current set");
    }

    function testFuzz_Unwrap_DeliversExactlyPreview(uint256 priceRao, uint256 deposit) public {
        uint256 priceE18 = _wholeRaoPrice(priceRao);
        uint256 floorAlpha = (CHAIN_MIN_STAKE * 1e18) / priceE18 + 1;
        // Keep all weighted slots above the floor.
        deposit = bound(deposit, 4 * floorAlpha, 100_000 * ALPHA);

        _setAlphaPrice(NETUID1, priceE18);
        uint256 shares = _depositAndWrap(alice, NETUID1, deposit);

        (uint256 previewAlpha,) = lens.previewUnwrap(TOKEN1, shares);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        uint256 received = _userStakeAcrossHotkeys(alice, NETUID1);
        assertEq(received, deposit, "the sole holder's full exit delivers every RAO");
        assertEq(previewAlpha, received, "and the preview quoted it");
    }

    function test_Unwrap_GatherWithinOneQuantumOfFloorDelivers() public {
        _depositAndWrap(alice, NETUID1, 599_999_943);
        _plantVaultStakes(NETUID1, 199_999_981, 199_999_981, 199_999_981);
        _setAlphaPrice(NETUID1, PRICE_LOW);

        vm.prank(alice);
        vault.unwrap(TOKEN1, 599_999_943e9, _toSubstrate(alice), 0);

        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), 599_999_943, "the gather delivered every slot");
    }

    /// @dev 199,999,980 RAO is worth 1,999,999 TAO RAO even at the 0.010000001 the read can hide.
    function test_RevertWhen_GatherStartsBelowTheFloorEvenAtTheHighestHiddenPrice() public {
        _depositAndWrap(alice, NETUID1, 599_999_940);
        _plantVaultStakes(NETUID1, 199_999_980, 199_999_980, 199_999_980);
        _setAlphaPrice(NETUID1, PRICE_LOW);

        vm.prank(alice);
        vm.expectRevert(IAlphaVaultAbi.GatherBelowFloor.selector);
        vault.unwrap(TOKEN1, 599_999_940e9, _toSubstrate(alice), 0);
    }
}

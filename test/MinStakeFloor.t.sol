// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { WithdrawTooSmall } from "src/VaultErrors.sol";
import { IAlphaVaultAbi } from "src/interfaces/IAlphaVaultAbi.sol";
import { CHAIN_MIN_STAKE, CHAIN_MIN_TRANSFER, MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

contract MinStakeFloorTest is AlphaVaultTestBase {
    uint256 private constant PRICE_LOW = 0.01e18;

    /// @dev Worth 0.00105 TAO at 0.05 TAO per alpha: above the move minimum, below the unstake minimum.
    uint256 private constant BETWEEN_MINIMUMS_DEPOSIT = 21_000_000;

    function _setChainMinStake(uint256 minStakeTao) private {
        MockStaking(STAKING_PRECOMPILE).setChainMinStake(minStakeTao);
    }

    function test_RevertWhen_WrapDepositBelowTaoFloor() public {
        _registerSubnet(99, hotkey4);
        _setAlphaPrice(99, PRICE_LOW);

        _simulateAlphaDepositHotkey(alice, 99, 150_000_000, hotkey4);
        vm.prank(alice);
        vm.expectRevert(IAlphaVaultAbi.DepositTooSmall.selector);
        vault.wrap(99, hotkey4, 0);
    }

    function test_Wrap_SucceedsAtTaoFloorBoundaryUnderLowPrice() public {
        _registerSubnet(99, hotkey4);
        _setAlphaPrice(99, PRICE_LOW);

        _simulateAlphaDepositHotkey(alice, 99, 200_000_000, hotkey4);
        _wrapHotkey(alice, 99, hotkey4);

        assertEq(_getVaultStake(hotkey4, 99), 200_000_000);
        assertEq(vault.balanceOf(alice, vault.currentTokenId(99)), 2e17);
    }

    function test_Rebalance_SkipsSubFloorMove() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        _simulateAlphaDepositHotkey(alice, NETUID1, ALPHA, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);

        _setAlphaPrice(NETUID1, PRICE_LOW);
        // The 0.1-alpha corrective move is worth 0.001 TAO, below the 0.002 TAO floor.
        _plantVaultStake(hotkey1, NETUID1, 600_000_000);
        _plantVaultStake(hotkey2, NETUID1, 400_000_000);

        vm.recordLogs();
        vault.rebalance(NETUID1);
        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 0, "sub-floor move skipped pre-call");
        assertEq(_getVaultStake(hotkey1, NETUID1), 600_000_000);
        assertEq(_getVaultStake(hotkey2, NETUID1), 400_000_000);
    }

    function test_RevertWhen_RebalanceMoveFailsAboveFloor() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        _simulateAlphaDepositHotkey(alice, NETUID1, ALPHA, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);

        _plantVaultStake(hotkey1, NETUID1, 600_000_000);
        _plantVaultStake(hotkey2, NETUID1, 400_000_000);
        MockStaking(STAKING_PRECOMPILE).setMoveStakeReverts(true);

        _expectChainRefusal();
        vault.rebalance(NETUID1);
    }

    // A refused move consumes all forwarded gas, so the budget also checks that no call is attempted.
    function test_Wrap_SkipsSubFloorRebalanceWithinGasBudget() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(9900, 100));
        _setAlphaPrice(NETUID1, PRICE_LOW);

        // The 1% slot's 0.005-alpha move is worth 0.00005 TAO, below the chain's own move minimum.
        _simulateAlphaDepositHotkey(alice, NETUID1, 500_000_000, hotkey1);
        vm.recordLogs();
        vm.prank(alice);
        vault.wrap{ gas: 1_500_000 }(NETUID1, hotkey1, 0);

        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 0, "doomed move never attempted");
        assertEq(vault.balanceOf(alice, TOKEN1), 5e17, "wrap completed within the fixed gas budget");
    }

    function test_RevertWhen_UnwrapWithAllSlotsSubFloor() public {
        _depositAndWrap(alice, NETUID1, 90_000_000);
        _plantVaultStakes(NETUID1, 30_000_000, 30_000_000, 30_000_000);

        vm.prank(alice);
        vm.expectRevert(IAlphaVaultAbi.GatherBelowFloor.selector);
        vault.unwrap(TOKEN1, 9e16, _toSubstrate(alice), 0);
    }

    function test_RevertWhen_UnwrapRequestBelowFloor() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        _simulateAlphaDepositHotkey(alice, NETUID1, ALPHA, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);
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
        _simulateAlphaDepositHotkey(alice, 99, BETWEEN_MINIMUMS_DEPOSIT, hotkey4);

        vm.prank(alice);
        vm.expectRevert(IAlphaVaultAbi.DepositTooSmall.selector);
        vault.wrap(99, hotkey4, 0);
    }

    function test_Wrap_LandsOnceTheUnstakeMinimumFallsToTheMoveMinimum() public {
        _registerSubnet(99, hotkey4);
        _simulateAlphaDepositHotkey(alice, 99, BETWEEN_MINIMUMS_DEPOSIT, hotkey4);
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

        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 0, "a raised minimum stops every corrective move");
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
        _simulateAlphaDepositHotkey(alice, 99, 2_000_000, hotkey4);

        _wrapHotkey(alice, 99, hotkey4);

        assertEq(_getVaultStake(hotkey4, 99), 2_000_000, "a zero minimum admits whatever the chain will move");
    }

    function testFuzz_Wrap_GateBindsAtTheChainMinimum(uint256 chainMinStake, uint256 deposit) public {
        chainMinStake = bound(chainMinStake, 1, 50e6);
        deposit = bound(deposit, 1, 2 * ALPHA);
        _setChainMinStake(chainMinStake);
        _registerSubnet(99, hotkey4);
        _simulateAlphaDepositHotkey(alice, 99, deposit, hotkey4);

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

    function testFuzz_Rebalance_NeverTripsChainFloor(uint256 priceRao, uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 0, MAX_SUBNET_ALPHA / 3);
        b = bound(b, 0, MAX_SUBNET_ALPHA / 3);
        c = bound(c, 0, MAX_SUBNET_ALPHA / 3);
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        uint256 total = _plantVaultStakes(NETUID1, a, b, c);
        _setAlphaPrice(NETUID1, _wholeRaoPrice(priceRao));

        vault.rebalance(NETUID1);

        assertEq(lens.totalStake(TOKEN1), total, "every attempted move cleared the chain floor");
    }

    // A pile the vault attempts is worth the 0.002 TAO floor less price rounding, far above the chain's
    // 0.0001 TAO move minimum, so the vault's own refusal is the only one reachable.
    function testFuzz_Rebalance_ConsolidationMatchesChainFloor(uint256 dust, uint256 priceRao) public {
        dust = bound(dust, 1, MAX_SUBNET_ALPHA);
        uint256 priceE18 = _wholeRaoPrice(priceRao);
        _registerSubnet(99, hotkey4);
        _simulateAlphaDepositHotkey(alice, 99, 10 * ALPHA, hotkey4);
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
        assertEq(lens.totalStake(tokenId), dust, "pile conserved onto the current set");
        assertGe(pileValue, CHAIN_MIN_TRANSFER, "the roll landed, so it cleared the chain's move bar");
    }

    function testFuzz_Unwrap_DeliversExactlyOrRefusesAtTheFloor(
        uint256 deposit,
        uint256 a,
        uint256 b,
        uint256 shareBps,
        uint256 priceRao
    ) public {
        deposit = bound(deposit, 1, 100_000) * ALPHA;
        a = bound(a, 0, deposit);
        b = bound(b, 0, deposit - a);
        shareBps = bound(shareBps, 1, BPS_BASE);
        uint256 supply = _depositAndWrap(alice, NETUID1, deposit);
        _plantVaultStakes(NETUID1, a, b, deposit - a - b);
        _setAlphaPrice(NETUID1, _wholeRaoPrice(priceRao));
        uint256 shares = supply * shareBps / BPS_BASE;
        // `deposit * 1e9` shares back `deposit` RAO, so a burn is worth shares / 1e9 RAO.
        uint256 expected = shares / 1e9;

        vm.prank(alice);
        (bool ok, bytes memory ret) =
            address(vault).call(abi.encodeCall(vault.unwrap, (TOKEN1, shares, _toSubstrate(alice), expected)));

        if (!ok) {
            bytes4 selector = bytes4(ret);
            assertTrue(
                selector == WithdrawTooSmall.selector || selector == IAlphaVaultAbi.GatherBelowFloor.selector,
                "only floor-classed reverts are legitimate"
            );
            return;
        }
        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), expected, "delivery is exact");
        assertEq(lens.totalStake(TOKEN1), deposit - expected, "only the delivered alpha left the vault");
    }

    // The pile reads as 1,999,999 TAO RAO, under the floor; the price read drops half a RAO, so its true
    // value is 2,000,000 TAO RAO.
    function test_Rebalance_ConsolidatesRichestSlotInsideOracleQuantumBand() public {
        _registerSubnet(99, hotkey4);
        _simulateAlphaDepositHotkey(alice, 99, ALPHA, hotkey4);
        _wrapHotkey(alice, 99, hotkey4);

        _plantVaultStake(hotkey4, 99, 199_999_999);
        _setValidators(99, _hotkeys(hotkey1), _weights(BPS_BASE));
        _setAlphaPrice(99, 0.0100000005e18);

        vault.rebalance(99);

        assertEq(_getVaultStake(hotkey4, 99), 0, "in-band richest slot consolidated by the chain's own check");
        assertEq(_getVaultStake(hotkey1, 99), 199_999_999, "pile landed on the current set");
    }

    function test_RevertWhen_DeliveryTransferFails() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        _simulateAlphaDepositHotkey(alice, NETUID1, ALPHA, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);

        MockStaking(STAKING_PRECOMPILE).setTransferStakeReverts(true);

        vm.prank(alice);
        _expectChainRefusal();
        vault.unwrap(TOKEN1, 1e18, _toSubstrate(alice), 0);
    }

    function testFuzz_Unwrap_DeliversExactlyPreview(uint256 priceRao, uint256 deposit) public {
        uint256 priceE18 = _wholeRaoPrice(priceRao);
        uint256 floorAlpha = (CHAIN_MIN_STAKE * 1e18) / priceE18 + 1;
        // Keep all weighted slots above the floor; this mock does not apply stake-share rounding.
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

    // At 0.01 TAO per alpha each slot is worth 1,999,999 TAO RAO; one price quantum lifts it to the floor.
    function test_Unwrap_GatherWithinOneQuantumOfFloorDelivers() public {
        _depositAndWrap(alice, NETUID1, 599_999_997);
        _plantVaultStakes(NETUID1, 199_999_999, 199_999_999, 199_999_999);
        _setAlphaPrice(NETUID1, PRICE_LOW);

        vm.prank(alice);
        vault.unwrap(TOKEN1, 599_999_997e9, _toSubstrate(alice), 0);

        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), 599_999_997, "the gather delivered every slot");
    }

    function test_RevertWhen_WrapFlushFailsForNonFloorReason() public {
        _registerSubnet(99, hotkey4);
        _simulateAlphaDepositHotkey(alice, 99, ALPHA, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setTransferStakeReverts(true);

        vm.prank(alice);
        _expectChainRefusal();
        vault.wrap(99, hotkey4, 0);
    }
}

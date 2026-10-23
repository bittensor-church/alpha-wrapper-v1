// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { WithdrawTooSmall } from "src/VaultErrors.sol";
import { IAlphaVaultAbi } from "src/interfaces/IAlphaVaultAbi.sol";
import { CHAIN_MIN_TRANSFER, MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

contract MinStakeFloorTest is AlphaVaultTestBase {
    uint256 private constant PRICE_LOW = 0.01e18;

    /// @dev Worth 0.00105 TAO at 0.05 TAO per alpha: above the move floor, below the unstake minimum.
    uint256 private constant BELOW_UNSTAKE_MINIMUM_DEPOSIT = 21_000_000;

    /// @dev Worth 0.00015 TAO at 0.05 TAO per alpha: above the chain's transfer minimum, below the move floor.
    uint256 private constant BELOW_MOVE_FLOOR_DEPOSIT = 3_000_000;

    function _setChainMinStake(uint256 minStakeTao) private {
        MockStaking(STAKING_PRECOMPILE).setChainMinStake(minStakeTao);
    }

    function test_RevertWhen_WrapDepositBelowTaoFloor() public {
        _registerSubnet(99, hotkey4);
        _setAlphaPrice(99, PRICE_LOW);

        _simulateAlphaDeposit(alice, 99, 15_000_000);
        vm.prank(alice);
        vm.expectRevert(IAlphaVaultAbi.DepositTooSmall.selector);
        vault.wrap(99, hotkey4, 0);
    }

    function test_Wrap_SucceedsAtTaoFloorBoundaryUnderLowPrice() public {
        _registerSubnet(99, hotkey4);
        _setAlphaPrice(99, PRICE_LOW);

        _simulateAlphaDeposit(alice, 99, 20_000_000);
        _wrapHotkey(alice, 99, hotkey4);

        assertEq(_getVaultStake(hotkey4, 99), 20_000_000);
        assertEq(vault.balanceOf(alice, vault.currentTokenId(99)), 2e16);
    }

    /// @dev 0.0100000005 TAO/alpha reads as 0.01 in whole RAO, valuing 0.02 alpha at exactly the 2e5 RAO floor.
    function test_Wrap_AcceptsTheFloorAtTheTruncatedPriceRead() public {
        _setAlphaPrice(NETUID1, 0.0100000005e18);

        assertEq(_depositAndWrap(alice, NETUID1, 20_000_000), 2e16, "0.02 alpha mints 1e9 shares per RAO");
    }

    function test_RevertWhen_DepositIsOneRaoBelowTheFloorAtTheTruncatedPriceRead() public {
        _setAlphaPrice(NETUID1, 0.0100000005e18);
        _simulateAlphaDeposit(alice, NETUID1, 19_999_999);

        vm.prank(alice);
        vm.expectRevert(IAlphaVaultAbi.DepositTooSmall.selector);
        vault.wrap(NETUID1, hotkey1, 0);
    }

    function test_Rebalance_SkipsSubFloorMove() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        _simulateAlphaDeposit(alice, NETUID1, ALPHA);
        _wrapHotkey(alice, NETUID1, hotkey1);

        _setAlphaPrice(NETUID1, PRICE_LOW);
        // The 0.015-alpha corrective move is worth 0.00015 TAO, below the 0.0002 TAO floor.
        _plantVaultStake(hotkey1, NETUID1, 515_000_000);
        _plantVaultStake(hotkey2, NETUID1, 485_000_000);

        vm.recordLogs();
        vault.rebalance(NETUID1);
        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 0, "sub-floor move skipped pre-call");
        assertEq(_getVaultStake(hotkey1, NETUID1), 515_000_000);
        assertEq(_getVaultStake(hotkey2, NETUID1), 485_000_000);
    }

    function test_RevertWhen_RebalanceMoveFailsAboveFloor() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        _simulateAlphaDeposit(alice, NETUID1, ALPHA);
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
        _simulateAlphaDeposit(alice, NETUID1, 500_000_000);
        vm.recordLogs();
        vm.prank(alice);
        vault.wrap{ gas: 1_500_000 }(NETUID1, hotkey1, 0);

        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 0, "doomed move never attempted");
        assertEq(vault.balanceOf(alice, TOKEN1), 5e17, "wrap completed within the fixed gas budget");
    }

    function test_RevertWhen_UnwrapWithAllSlotsSubFloor() public {
        _depositAndWrap(alice, NETUID1, 9_000_000);
        _plantVaultStakes(NETUID1, 3_000_000, 3_000_000, 3_000_000);

        vm.prank(alice);
        vm.expectRevert(IAlphaVaultAbi.GatherBelowFloor.selector);
        vault.unwrap(TOKEN1, 9e15, _toSubstrate(alice), 0);
    }

    function test_RevertWhen_UnwrapRequestBelowFloor() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        _simulateAlphaDeposit(alice, NETUID1, ALPHA);
        _wrapHotkey(alice, NETUID1, hotkey1);
        _setAlphaPrice(NETUID1, PRICE_LOW);

        // 1% of 1 alpha is worth 0.0001 TAO.
        vm.prank(alice);
        vm.expectRevert(WithdrawTooSmall.selector);
        vault.unwrap(TOKEN1, 1e16, _toSubstrate(alice), 0);
    }

    function test_Unwrap_DeliversExactlyAtFloorValue() public {
        _depositAndWrap(alice, NETUID1, ALPHA);

        // 0.004 alpha is worth exactly 0.0002 TAO.
        vm.prank(alice);
        vault.unwrap(TOKEN1, 4e15, _toSubstrate(alice), 0);

        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), 4_000_000, "a request worth exactly the floor delivers");
    }

    function test_RevertWhen_UnwrapBelowRaisedChainFloor() public {
        _depositAndWrap(alice, NETUID1, ALPHA);
        _setChainMinTransfer(2_500_000);

        // 0.06 alpha is worth 0.003 TAO, below the raised 0.005 TAO floor.
        vm.prank(alice);
        vm.expectRevert(WithdrawTooSmall.selector);
        vault.unwrap(TOKEN1, 6e16, _toSubstrate(alice), 0);
    }

    function test_Wrap_LandsADepositBelowTheUnstakeMinimum() public {
        _registerSubnet(99, hotkey4);
        _simulateAlphaDeposit(alice, 99, BELOW_UNSTAKE_MINIMUM_DEPOSIT);

        _wrapHotkey(alice, 99, hotkey4);

        assertEq(_getVaultStake(hotkey4, 99), BELOW_UNSTAKE_MINIMUM_DEPOSIT, "only the move floor gates a deposit");
    }

    function test_Wrap_LandsOnceTheTransferMinimumFalls() public {
        _registerSubnet(99, hotkey4);
        _simulateAlphaDeposit(alice, 99, BELOW_MOVE_FLOOR_DEPOSIT);
        vm.prank(alice);
        vm.expectRevert(IAlphaVaultAbi.DepositTooSmall.selector);
        vault.wrap(99, hotkey4, 0);

        _setChainMinTransfer(75_000);
        _wrapHotkey(alice, 99, hotkey4);

        assertEq(_getVaultStake(hotkey4, 99), BELOW_MOVE_FLOOR_DEPOSIT, "a halved transfer minimum halves the floor");
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
        _setChainMinTransfer(25_000_000);

        vm.recordLogs();
        vault.rebalance(NETUID1);

        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 0, "a raised minimum stops every corrective move");
        assertEq(_getVaultStake(hotkey1, NETUID1), 500_000_000, "the split is left drifted");
    }

    function test_Rebalance_FollowsLoweredChainFloor() public {
        _depositAndWrap(alice, NETUID1, ALPHA);
        _setAlphaPrice(NETUID1, PRICE_LOW);
        _plantVaultStakes(NETUID1, 340_000_000, 330_000_000, 330_000_000);

        // Each 0.0033-alpha corrective move is worth 0.000033 TAO.
        vault.rebalance(NETUID1);
        assertEq(_getVaultStake(hotkey1, NETUID1), 340_000_000, "the corrective moves are under the current minimum");

        _setChainMinTransfer(15_000);
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey1, NETUID1), 333_400_000, "they land once the minimum drops below them");
        assertEq(_getVaultStake(hotkey2, NETUID1), 333_300_000);
        assertEq(_getVaultStake(hotkey3, NETUID1), 333_300_000);
    }

    function test_Wrap_TransferMinimumOfZeroLeavesTheGateOpen() public {
        _setChainMinTransfer(0);
        _registerSubnet(99, hotkey4);
        // 20 RAO of alpha is worth 1 TAO RAO.
        _simulateAlphaDeposit(alice, 99, 20);

        _wrapHotkey(alice, 99, hotkey4);

        assertEq(_getVaultStake(hotkey4, 99), 20, "a zero minimum admits whatever the chain will move");
    }

    function testFuzz_Wrap_GateBindsAtTwiceTheTransferMinimum(
        uint256 chainMinTransfer,
        uint256 chainMinStake,
        uint256 deposit
    ) public {
        chainMinTransfer = bound(chainMinTransfer, 1, 25e6);
        chainMinStake = bound(chainMinStake, 0, 50e6);
        deposit = bound(deposit, 1, 2 * ALPHA);
        _setChainMinTransfer(chainMinTransfer);
        _setChainMinStake(chainMinStake);
        _registerSubnet(99, hotkey4);
        _simulateAlphaDeposit(alice, 99, deposit);

        vm.prank(alice);
        (bool ok, bytes memory ret) = address(vault).call(abi.encodeCall(vault.wrap, (99, hotkey4, 0)));

        // TAO RAO at 0.05 TAO per alpha.
        uint256 depositValue = deposit / 20;
        assertEq(ok, depositValue >= 2 * chainMinTransfer, "the gate binds exactly at twice the transfer minimum");
        if (!ok) assertEq(ret, abi.encodeWithSelector(IAlphaVaultAbi.DepositTooSmall.selector), "the vault refuses");
    }

    function test_RevertWhen_GatherBelowRaisedChainFloor() public {
        _depositAndWrap(alice, NETUID1, ALPHA);
        _plantVaultStakes(NETUID1, 350_000_000, 350_000_000, 300_000_000);
        _setChainMinTransfer(10_000_000);

        // The 0.5-alpha request clears the raised 0.02 TAO floor; its richest 0.35-alpha slot does not.
        vm.prank(alice);
        vm.expectRevert(IAlphaVaultAbi.GatherBelowFloor.selector);
        vault.unwrap(TOKEN1, 5e17, _toSubstrate(alice), 0);
    }

    function test_PreviewUnwrap_QuotesWhatDustUnwrapRefuses() public {
        _depositAndWrap(alice, NETUID1, ALPHA);
        _setAlphaPrice(NETUID1, PRICE_LOW);

        (uint256 previewAlpha,) = lens.previewUnwrap(TOKEN1, 1e16);
        assertEq(previewAlpha, 10_000_000, "preview quotes the pro-rata alpha");

        vm.prank(alice);
        vm.expectRevert(WithdrawTooSmall.selector);
        vault.unwrap(TOKEN1, 1e16, _toSubstrate(alice), 0);
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

    // A pile the vault attempts is worth the 0.0002 TAO floor less price rounding, above the chain's
    // 0.0001 TAO transfer minimum, so the vault's own refusal is the only one reachable.
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
            assertLt(pileValue, MOVE_FLOOR, "and only a pile worth less than the floor");
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
        uint256 price = _wholeRaoPrice(priceRao);
        uint256 supply = _depositAndWrap(alice, NETUID1, deposit);
        _plantVaultStakes(NETUID1, a, b, deposit - a - b);
        _setAlphaPrice(NETUID1, price);
        uint256 shares = supply * shareBps / BPS_BASE;
        // `deposit * 1e9` shares back `deposit` RAO, so a burn is worth shares / 1e9 RAO.
        uint256 expected = shares / 1e9;
        uint256 largest = a > b ? a : b;
        if (deposit - a - b > largest) largest = deposit - a - b;
        bool belowFloor = expected * price / 1e18 < MOVE_FLOOR;
        // Gathering starts from the largest slot, refused when even the highest price the read can hide leaves it
        // below the floor.
        bool cannotGather = expected > largest && largest * (price + 1e9) / 1e18 < MOVE_FLOOR;

        vm.prank(alice);
        (bool ok, bytes memory ret) =
            address(vault).call(abi.encodeCall(vault.unwrap, (TOKEN1, shares, _toSubstrate(alice), expected)));

        if (belowFloor) {
            assertEq(ret, abi.encodeWithSelector(WithdrawTooSmall.selector), "an exit below the floor is refused");
            return;
        }
        if (cannotGather) {
            assertEq(
                ret, abi.encodeWithSelector(IAlphaVaultAbi.GatherBelowFloor.selector), "an unmovable pile is refused"
            );
            return;
        }
        assertTrue(ok, "an exit above the floor with a movable pile pays");
        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), expected, "delivery is exact");
        assertEq(lens.totalStake(TOKEN1), deposit - expected, "only the delivered alpha left the vault");
    }

    /// @dev The recorded 1-alpha slot is below the 2-alpha floor at 0.0001 TAO/alpha, but the newly attested key already
    ///      holds 10 alpha the record does not know about: consolidation rolls that pile through the dropped slot.
    function test_Unwrap_ANewValidatorsPileCarriesASubFloorSlot() public {
        _setValidators(NETUID1, _hotkeys(hotkey1), _weights(BPS_BASE));
        uint256 shares = _depositAndWrap(alice, NETUID1, ALPHA);
        _setValidators(NETUID1, _hotkeys(hotkey2), _weights(BPS_BASE));
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, _subnetColdkey(NETUID1), NETUID1, 10 * ALPHA);
        _setAlphaPrice(NETUID1, 0.0001e18);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice), 0);

        // 5e17 * (11e9 + 1) / (1e18 + 1e9), floored.
        assertEq(_getStake(hotkey2, alice, NETUID1), 5_499_999_995, "half of the 11 alpha on the new key");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "the dropped slot was consolidated");
        assertEq(_getVaultStake(hotkey2, NETUID1), 11 * ALPHA - 5_499_999_995, "the rest stays on the new key");
    }

    // The pile reads as 199,999 TAO RAO, under the floor; the price read drops 0.9 RAO, so its true
    // value is 200,000 TAO RAO.
    function test_Rebalance_ConsolidatesRichestSlotInsideOracleQuantumBand() public {
        _registerSubnet(99, hotkey4);
        _simulateAlphaDeposit(alice, 99, ALPHA);
        _wrapHotkey(alice, 99, hotkey4);

        _plantVaultStake(hotkey4, 99, 19_999_999);
        _setValidators(99, _hotkeys(hotkey1), _weights(BPS_BASE));
        _setAlphaPrice(99, 0.0100000009e18);

        vault.rebalance(99);

        assertEq(_getVaultStake(hotkey4, 99), 0, "in-band richest slot consolidated by the chain's own check");
        assertEq(_getVaultStake(hotkey1, 99), 19_999_999, "pile landed on the current set");
    }

    function test_RevertWhen_DeliveryTransferFails() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        _simulateAlphaDeposit(alice, NETUID1, ALPHA);
        _wrapHotkey(alice, NETUID1, hotkey1);

        MockStaking(STAKING_PRECOMPILE).setTransferStakeReverts(true);

        vm.prank(alice);
        _expectChainRefusal();
        vault.unwrap(TOKEN1, 1e18, _toSubstrate(alice), 0);
    }

    function testFuzz_Unwrap_DeliversExactlyPreview(uint256 priceRao, uint256 deposit) public {
        uint256 priceE18 = _wholeRaoPrice(priceRao);
        uint256 floorAlpha = (MOVE_FLOOR * 1e18) / priceE18 + 1;
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

    // At 0.01 TAO per alpha each slot is worth 199,999 TAO RAO; one price quantum lifts it to the floor.
    function test_Unwrap_GatherWithinOneQuantumOfFloorDelivers() public {
        _depositAndWrap(alice, NETUID1, 59_999_997);
        _plantVaultStakes(NETUID1, 19_999_999, 19_999_999, 19_999_999);
        _setAlphaPrice(NETUID1, PRICE_LOW);

        vm.prank(alice);
        vault.unwrap(TOKEN1, 59_999_997e9, _toSubstrate(alice), 0);

        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), 59_999_997, "the gather delivered every slot");
    }

    function test_RevertWhen_WrapFlushFailsForNonFloorReason() public {
        _registerSubnet(99, hotkey4);
        _simulateAlphaDeposit(alice, 99, ALPHA);
        MockStaking(STAKING_PRECOMPILE).setTransferStakeReverts(true);

        vm.prank(alice);
        _expectChainRefusal();
        vault.wrap(99, hotkey4, 0);
    }
}

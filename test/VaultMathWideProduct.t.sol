// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test, stdError } from "forge-std/Test.sol";
import { StakeOps } from "src/libraries/StakeOps.sol";
import { VaultMath } from "src/libraries/VaultMath.sol";

contract WideProduct {
    function assetsFor(uint256 stake, uint256 supply, uint256 shares) external pure returns (uint256) {
        return VaultMath.assetsFor(stake, supply, shares);
    }

    function proRata(uint256 total, uint256 shares, uint256 supply) external pure returns (uint256) {
        return VaultMath.proRata(total, shares, supply);
    }

    function taoValue(uint256 alphaAmount, uint256 alphaPriceE18) external pure returns (uint256) {
        return StakeOps.taoValue(alphaAmount, alphaPriceE18);
    }
}

contract NarrowProduct {
    function assetsFor(uint256 stake, uint256 supply, uint256 shares) external pure returns (uint256) {
        return (shares * (stake + VaultMath.VIRTUAL_ASSETS)) / (supply + VaultMath.VIRTUAL_SHARES);
    }

    function proRata(uint256 total, uint256 shares, uint256 supply) external pure returns (uint256) {
        return (total * shares) / supply;
    }

    function taoValue(uint256 alphaAmount, uint256 alphaPriceE18) external pure returns (uint256) {
        return (alphaAmount * alphaPriceE18) / VaultMath.ALPHA_PRICE_SCALE;
    }
}

contract VaultMathWideProductTest is Test {
    WideProduct internal wide;
    NarrowProduct internal narrow;

    uint256 internal constant SUPPLY_CAP = VaultMath.TAO_NATIVE_QUANTUM * VaultMath.TAO_INDEX_PRECISION;
    uint256 internal constant MAX_ALPHA_BACKING = 64 * uint256(type(uint64).max);
    uint256 internal constant TAO_MAX_SUPPLY_WEI = 21_000_000e18;
    uint256 internal constant NARROW_SAFE_BOUND = type(uint120).max;

    function setUp() public {
        wide = new WideProduct();
        narrow = new NarrowProduct();
    }

    function testFuzz_AssetsFor_AgreesWithTheNarrowProductWhereItFits(uint256 stake, uint256 supply, uint256 shares)
        public
        view
    {
        stake = bound(stake, 0, NARROW_SAFE_BOUND);
        supply = bound(supply, 0, NARROW_SAFE_BOUND);
        shares = bound(shares, 0, NARROW_SAFE_BOUND);

        assertEq(wide.assetsFor(stake, supply, shares), narrow.assetsFor(stake, supply, shares));
    }

    function testFuzz_ProRata_AgreesWithTheNarrowProductWhereItFits(uint256 total, uint256 shares, uint256 supply)
        public
        view
    {
        total = bound(total, 0, NARROW_SAFE_BOUND);
        shares = bound(shares, 0, NARROW_SAFE_BOUND);
        supply = bound(supply, 1, type(uint256).max);

        assertEq(wide.proRata(total, shares, supply), narrow.proRata(total, shares, supply));
    }

    function testFuzz_TaoValue_AgreesWithTheNarrowProductWhereItFits(uint256 alphaAmount, uint256 alphaPriceE18)
        public
        view
    {
        alphaAmount = bound(alphaAmount, 0, NARROW_SAFE_BOUND);
        alphaPriceE18 = bound(alphaPriceE18, 0, NARROW_SAFE_BOUND);

        assertEq(wide.taoValue(alphaAmount, alphaPriceE18), narrow.taoValue(alphaAmount, alphaPriceE18));
    }

    function test_AssetsFor_ReturnsTheExactQuotientWhereTheNarrowProductOverflows() public {
        uint256 stake = 1 << 200;
        uint256 supply = (1 << 200) - VaultMath.VIRTUAL_SHARES;
        uint256 shares = 1 << 200;

        vm.expectRevert(stdError.arithmeticError);
        narrow.assetsFor(stake, supply, shares);

        assertEq(wide.assetsFor(stake, supply, shares), stake + VaultMath.VIRTUAL_ASSETS);
    }

    function test_ProRata_ReturnsTheExactQuotientWhereTheNarrowProductOverflows() public {
        uint256 total = 1 << 200;
        uint256 shares = 1 << 200;
        uint256 supply = 1 << 200;

        vm.expectRevert(stdError.arithmeticError);
        narrow.proRata(total, shares, supply);

        assertEq(wide.proRata(total, shares, supply), total);
    }

    function test_TaoValue_ReturnsTheExactQuotientWhereTheNarrowProductOverflows() public {
        uint256 alphaAmount = 1 << 200;

        vm.expectRevert(stdError.arithmeticError);
        narrow.taoValue(alphaAmount, VaultMath.ALPHA_PRICE_SCALE);

        assertEq(wide.taoValue(alphaAmount, VaultMath.ALPHA_PRICE_SCALE), alphaAmount);
    }

    function testFuzz_ProRata_HoldsBeyondTaoSupplyAtTheShareCap(uint256 total, uint256 sharesSeed) public view {
        total = bound(total, 1, type(uint200).max);
        uint256 shares = bound(sharesSeed, 1, SUPPLY_CAP);

        uint256 refund = wide.proRata(total, shares, SUPPLY_CAP);

        assertLe(refund, total);
        assertEq(wide.proRata(total, SUPPLY_CAP, SUPPLY_CAP), total);
    }

    function testFuzz_ProRata_NeverPaysOutMoreThanThePot(uint256 total, uint256 supply, uint256 firstSeed) public view {
        total = bound(total, 0, TAO_MAX_SUPPLY_WEI);
        supply = bound(supply, 2, SUPPLY_CAP);
        uint256 first = bound(firstSeed, 1, supply - 1);

        assertLe(wide.proRata(total, first, supply) + wide.proRata(total, supply - first, supply), total);
    }

    function testFuzz_AssetsFor_NeverExceedsBackingAtTheShareCap(uint256 stake, uint256 sharesSeed) public view {
        stake = bound(stake, 0, MAX_ALPHA_BACKING);
        uint256 shares = bound(sharesSeed, 0, SUPPLY_CAP);

        assertLe(wide.assetsFor(stake, SUPPLY_CAP, shares), stake);
    }

    function testFuzz_AssetsFor_IsMonotonicInShares(uint256 stake, uint256 supply, uint256 lowSeed, uint256 highSeed)
        public
        view
    {
        stake = bound(stake, 0, MAX_ALPHA_BACKING);
        supply = bound(supply, 1, SUPPLY_CAP);
        uint256 low = bound(lowSeed, 0, supply);
        uint256 high = bound(highSeed, low, supply);

        assertLe(wide.assetsFor(stake, supply, low), wide.assetsFor(stake, supply, high));
    }

    function test_AssetsFor_RoundsDown() public view {
        assertEq(wide.assetsFor(1, VaultMath.VIRTUAL_SHARES, VaultMath.VIRTUAL_SHARES), 1);
        assertEq(wide.assetsFor(1, VaultMath.VIRTUAL_SHARES, VaultMath.VIRTUAL_SHARES - 1), 0);
    }

    function test_ProRata_RoundsDown() public view {
        assertEq(wide.proRata(10, 1, 3), 3);
        assertEq(wide.proRata(type(uint256).max, 1, 3), type(uint256).max / 3);
    }

    function test_TaoValue_RoundsDown() public view {
        assertEq(wide.taoValue(3, VaultMath.ALPHA_PRICE_SCALE / 2), 1);
        assertEq(wide.taoValue(1, VaultMath.ALPHA_PRICE_SCALE - 1), 0);
    }

    function test_ZeroInputsQuoteZero() public view {
        assertEq(wide.assetsFor(1e21, 1e30, 0), 0);
        assertEq(wide.assetsFor(0, 1e30, 1e30), 0);
        assertEq(wide.proRata(0, 1e30, 1e30), 0);
        assertEq(wide.proRata(1e24, 0, 1e30), 0);
        assertEq(wide.taoValue(0, VaultMath.ALPHA_PRICE_SCALE), 0);
        assertEq(wide.taoValue(1e21, 0), 0);
    }

    function test_AssetsFor_AtZeroSupplyPricesAgainstTheVirtualOffsets() public view {
        assertEq(wide.assetsFor(0, 0, VaultMath.VIRTUAL_SHARES), 1);
        assertEq(wide.assetsFor(0, 0, VaultMath.VIRTUAL_SHARES - 1), 0);
    }

    function test_RevertWhen_ProRataDividesByZeroSupply() public {
        vm.expectRevert(stdError.divisionError);
        wide.proRata(1e24, 1, 0);
    }

    function test_RevertWhen_TheQuotientItselfExceedsUint256() public {
        vm.expectRevert(stdError.arithmeticError);
        wide.proRata(type(uint256).max, type(uint256).max, 1);

        vm.expectRevert(stdError.arithmeticError);
        wide.taoValue(type(uint256).max, type(uint256).max);

        vm.expectRevert(stdError.arithmeticError);
        wide.assetsFor(type(uint256).max - 1, 0, type(uint256).max);
    }
}

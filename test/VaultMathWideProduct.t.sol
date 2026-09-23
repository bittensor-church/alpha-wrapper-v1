// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
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

    function test_AssetsFor_ReturnsTheExactQuotientWhereTheNarrowProductOverflows() public view {
        uint256 stake = 1 << 200;
        uint256 supply = (1 << 200) - VaultMath.VIRTUAL_SHARES;
        uint256 shares = 1 << 200;

        assertEq(wide.assetsFor(stake, supply, shares), stake + VaultMath.VIRTUAL_ASSETS);
    }
}

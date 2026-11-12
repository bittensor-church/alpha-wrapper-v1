// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVaultTestBase } from "../AlphaVaultTestBase.sol";
import { MockStaking } from "../mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

abstract contract DepositScenarios is AlphaVaultTestBase {
    /// @dev Ten alpha over ten validators leaves each 1 alpha, above the 0.04-alpha floor at 0.05 TAO per alpha.
    uint256 internal constant MIN_SPREADABLE = 10 * ALPHA;

    uint256 internal constant SPREAD_DEPOSIT = 10_000 * ALPHA;

    /// @dev At a price the EVM reads as zero (5e-10 TAO/alpha) the chain moves only piles of 200,000 alpha
    ///      or more, so positions there are sized in millions of alpha.
    uint256 internal constant LARGE_POSITION = 1_000_000 * ALPHA;

    struct PlantedBurn {
        uint256 deposit;
        uint256 largestSlot;
        uint256 shares;
        uint256 alphaWorth;
        uint256 priceE18;
    }

    MockStaking internal mock;

    function setUp() public virtual override {
        super.setUp();
        mock = MockStaking(STAKING_PRECOMPILE);
    }

    /// @dev `deposit * 1e9` shares back `deposit` RAO, so a burn is worth `shares / 1e9` RAO.
    function _burnOverAPlantedLayout(uint256 deposit, uint256 a, uint256 b, uint256 shareBps, uint256 priceRao)
        internal
        returns (PlantedBurn memory burn)
    {
        burn.deposit = bound(deposit, 1, 100_000) * ALPHA;
        a = bound(a, 0, burn.deposit);
        b = bound(b, 0, burn.deposit - a);
        uint256 c = burn.deposit - a - b;
        burn.largestSlot = a > b ? a : b;
        if (c > burn.largestSlot) burn.largestSlot = c;
        burn.priceE18 = _wholeRaoPrice(priceRao);
        uint256 supply = _depositAndWrap(alice, NETUID1, burn.deposit);
        _plantVaultStakes(NETUID1, a, b, c);
        _setAlphaPrice(NETUID1, burn.priceE18);
        burn.shares = supply * bound(shareBps, 1, BPS_BASE) / BPS_BASE;
        burn.alphaWorth = burn.shares / 1e9;
    }
}

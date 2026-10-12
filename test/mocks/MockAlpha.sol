// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { MockStaking } from "./MockStaking.sol";

/// @dev 0.05 TAO per alpha, a round price inside the chain's usual range.
uint256 constant DEFAULT_ALPHA_PRICE_E18 = 0.05e18;

/// @dev The swap's minimum price, 1e-6 TAO per alpha: it refuses any sale at or below it.
uint256 constant MIN_SELL_PRICE_E18 = 1e12;

contract MockAlpha {
    uint256 private constant PRICE_QUANTUM_E18 = 1e9;

    mapping(uint16 => uint256) private _chainPriceE18;
    mapping(uint16 => bool) private _isSet;

    /// @dev Use a price below 1e9 to model a zero EVM read with nonzero chain-side value.
    function setAlphaPrice(uint16 netuid, uint256 alphaPriceE18) external {
        require(alphaPriceE18 != 0, "MockAlpha: zero chain price unrepresentable");
        _chainPriceE18[netuid] = alphaPriceE18;
        _isSet[netuid] = true;
    }

    /// @dev The precompile truncates to whole RAO, saturates at u64 and scales back to 1e18.
    function getAlphaPrice(uint16 netuid) external view returns (uint256) {
        uint256 priceRao = chainAlphaPrice(netuid) / PRICE_QUANTUM_E18;
        if (priceRao > type(uint64).max) priceRao = type(uint64).max;
        return priceRao * PRICE_QUANTUM_E18;
    }

    function chainAlphaPrice(uint16 netuid) public view returns (uint256) {
        return _isSet[netuid] ? _chainPriceE18[netuid] : DEFAULT_ALPHA_PRICE_E18;
    }

    bool public simSwapReverts;
    mapping(uint64 => bool) private _simRefused;
    mapping(uint64 => uint256) private _simQuoteOverride;
    mapping(uint64 => bool) private _simQuoteSet;

    function setSimSwapReverts(bool v) external {
        simSwapReverts = v;
    }

    /// @dev Refuses any sale of one exact input, as a pool too shallow for it would.
    function setSimSwapRefused(uint64 alpha, bool refused) external {
        _simRefused[alpha] = refused;
    }

    /// @dev Exact-input overrides model price impact absent from the default linear rate.
    function setSimSwapQuote(uint64 alpha, uint256 taoOut) external {
        _simQuoteOverride[alpha] = taoOut;
        _simQuoteSet[alpha] = true;
    }

    /// @dev The swap refuses a sale at or below its minimum price, an input that would pay nothing and a sale the pool
    ///      cannot fill. Simulated and executed sales run the same checks.
    function refusesSale(uint16 netuid, uint64 alpha) public view returns (bool) {
        return simSwapReverts || _simRefused[alpha] || chainAlphaPrice(netuid) <= MIN_SELL_PRICE_E18
            || _simQuote(netuid, alpha) == 0;
    }

    /// @dev A refused simulation consumes every unit of forwarded gas, as on chain.
    function simSwapAlphaForTao(uint16 netuid, uint64 alpha) external view returns (uint256) {
        if (refusesSale(netuid, alpha)) {
            assembly {
                invalid()
            }
        }
        return _simQuote(netuid, alpha);
    }

    function _simQuote(uint16 netuid, uint64 alpha) private view returns (uint256) {
        return
            _simQuoteSet[alpha] ? _simQuoteOverride[alpha] : MockStaking(STAKING_PRECOMPILE).quoteTaoOut(netuid, alpha);
    }
}

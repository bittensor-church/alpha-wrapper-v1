// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { MockStaking } from "./MockStaking.sol";

/// @dev 0.05 TAO per alpha, a round price inside the chain's usual range.
uint256 constant DEFAULT_ALPHA_PRICE_E18 = 0.05e18;

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
    mapping(uint64 => uint256) private _simQuoteOverride;
    mapping(uint64 => bool) private _simQuoteSet;

    function setSimSwapReverts(bool v) external {
        simSwapReverts = v;
    }

    /// @dev Exact-input overrides model price impact absent from the default linear rate.
    function setSimSwapQuote(uint64 alpha, uint256 taoOut) external {
        _simQuoteOverride[alpha] = taoOut;
        _simQuoteSet[alpha] = true;
    }

    /// @dev A refused simulation consumes every unit of forwarded gas, as on chain.
    function simSwapAlphaForTao(uint16 netuid, uint64 alpha) external view returns (uint256) {
        if (simSwapReverts) {
            assembly {
                invalid()
            }
        }
        if (_simQuoteSet[alpha]) return _simQuoteOverride[alpha];
        return MockStaking(STAKING_PRECOMPILE).quoteTaoOut(netuid, alpha);
    }
}

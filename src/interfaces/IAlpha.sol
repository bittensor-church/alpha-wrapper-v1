// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @dev Excerpt of the Alpha precompile interface published in Subtensor; docs/deployment.md lists the
///      behavior the vault relies on.
interface IAlpha {
    function getAlphaPrice(uint16 netuid) external view returns (uint256);

    function simSwapAlphaForTao(uint16 netuid, uint64 alpha) external view returns (uint256);
}

address constant ALPHA_PRECOMPILE = 0x0000000000000000000000000000000000000808;

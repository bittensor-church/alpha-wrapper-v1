// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IAlphaVault } from "./IAlphaVault.sol";

/// @notice Subset of AlphaVaultLens for contracts that value AlphaVault shares.
interface IAlphaVaultLens {
    function vault() external view returns (IAlphaVault);
    function previewUnwrap(uint256 tokenId, uint256 shares) external view returns (uint256 alpha, uint256 tao);
    function claimableTaoOf(address account, uint256 tokenId) external view returns (uint256);
    function lastSeenHotkeys(uint256 tokenId) external view returns (bytes32[] memory);
}

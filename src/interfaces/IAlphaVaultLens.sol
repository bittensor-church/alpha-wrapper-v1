// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { VaultReads } from "../libraries/VaultReads.sol";
import { IAlphaVault } from "./IAlphaVault.sol";

interface IAlphaVaultLens {
    function vault() external view returns (IAlphaVault);
    function totalStake(uint256 tokenId) external view returns (uint256);
    function locatedStake(uint256 tokenId) external view returns (uint256);
    function missingStake(uint256 tokenId) external view returns (uint256);
    function resolvedBacking(uint256 tokenId) external view returns (VaultReads.Backing memory backing);
    function lastSeenHotkeys(uint256 tokenId) external view returns (bytes32[] memory);
    function isBackingIntact(uint256 tokenId) external view returns (bool);
    function writeOffDeadline(uint256 tokenId) external view returns (uint256 deadline);
    function sharePrice(uint256 tokenId) external view returns (uint256);
    function previewWrap(uint256 tokenId, uint256 assets) external view returns (uint256);
    function previewUnwrap(uint256 tokenId, uint256 shares) external view returns (uint256 alpha, uint256 tao);
    function claimableTaoOf(address account, uint256 tokenId) external view returns (uint256);
    function batchClaimableTaoOf(address account, uint256[] calldata tokenIds) external view returns (uint256[] memory amounts);
}

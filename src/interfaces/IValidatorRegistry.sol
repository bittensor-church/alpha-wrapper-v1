// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

uint256 constant MAX_VALIDATORS = 64;

interface IValidatorRegistry {
    /// @dev Empty means unconfigured. Otherwise 1..64 distinct nonzero hotkeys with matching nonzero
    ///      BPS weights summing to 10000, and the coldkey-swap lineage root of the coldkey that owned
    ///      each hotkey when the set landed: its `getColdkeyRoot`, or the coldkey itself when that
    ///      reports no swap history. Ownership was checked at submission, not guaranteed now.
    function getValidators(uint256 netuid) external view
        returns (bytes32[] memory hotkeys, uint16[] memory weights, bytes32[] memory ownerRoots);

    /// @notice Validator updates landed for `netuid`; each landing increments it by one.
    function nonces(uint256 netuid) external view returns (uint256);
}

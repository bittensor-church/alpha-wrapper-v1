// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

uint256 constant MAX_VALIDATORS = 10;

interface IValidatorRegistry {
    /// @dev Hotkeys must be nonzero and distinct. The vault reads 0x0 as "no swap successor".
    ///      Weights must sum to 10000.
    ///      Every hotkey the vault stakes under must have an owner.
    function getValidators(uint256 netuid) external view
        returns (bytes32[] memory hotkeys, uint16[] memory weights);

    /// @notice Validator updates landed for `netuid`; each landing increments it by one.
    /// @dev Must be nonzero once a set is published. The vault reads 0 as "not parked".
    function nonces(uint256 netuid) external view returns (uint256);
}

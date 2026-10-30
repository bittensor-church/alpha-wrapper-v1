// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IValidatorRegistry } from "./interfaces/IValidatorRegistry.sol";
import { StakeOps } from "./libraries/StakeOps.sol";
import { VaultMath } from "./libraries/VaultMath.sol";
import { NetuidOutOfRange, ZeroHotkey } from "./VaultErrors.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @notice One validator per subnet, updated immediately by an owner with two-step transfers.
/// @dev The vault performs staking.
contract BasicValidatorRegistry is IValidatorRegistry, Ownable2Step {
    mapping(uint256 => bytes32) private _hotkeys;
    mapping(uint256 => uint256) public override nonces;

    event ValidatorUpdated(uint256 indexed netuid, uint256 nonce, bytes32 hotkey);

    error OwnerlessHotkey(bytes32 hotkey);
    error RenunciationDisabled();

    constructor(address initialOwner) Ownable(initialOwner) { }

    /// @notice Keep an owner available to update validators and release recovered parking.
    function renounceOwnership() public view override onlyOwner { revert RenunciationDisabled(); }

    /// @notice Set the subnet's sole validator at 100% weight; there is no delay.
    /// @dev Resubmitting the same hotkey advances the nonce, which lets the vault leave parking after
    ///      a fresh owner decision.
    function setValidator(uint256 netuid, bytes32 hotkey) external onlyOwner {
        if (netuid > type(uint16).max) revert NetuidOutOfRange();
        if (hotkey == bytes32(0)) revert ZeroHotkey();
        if (!StakeOps.hasOwner(hotkey)) revert OwnerlessHotkey(hotkey);

        _hotkeys[netuid] = hotkey; uint256 nonce = ++nonces[netuid];
        emit ValidatorUpdated(netuid, nonce, hotkey);
    }

    /// @inheritdoc IValidatorRegistry
    function getValidators(uint256 netuid) external view override
        returns (bytes32[] memory hotkeys, uint16[] memory weights) {
        bytes32 hotkey = _hotkeys[netuid];
        if (hotkey == bytes32(0)) return (hotkeys, weights);

        hotkeys = new bytes32[](1); weights = new uint16[](1);
        hotkeys[0] = hotkey; weights[0] = VaultMath.BPS_BASE;
    }
}

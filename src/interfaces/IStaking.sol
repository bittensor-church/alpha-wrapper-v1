// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @dev Excerpt of the Staking V2 precompile interface published in Subtensor; docs/deployment.md lists
///      the behavior the vault relies on.
interface IStaking {
    function transferStake(bytes32 destination_coldkey, bytes32 hotkey, uint256 origin_netuid,
        uint256 destination_netuid, uint256 amount) external payable;

    function moveStake(bytes32 origin_hotkey, bytes32 destination_hotkey, uint256 origin_netuid,
        uint256 destination_netuid, uint256 amount) external payable;

    function getStake(bytes32 hotkey, bytes32 coldkey, uint256 netuid) external view returns (uint256);

    function getHotkeyOwner(bytes32 hotkey) external view returns (bool exists, bytes32 owner);

    function getHotkeySuccessor(bytes32 hotkey, uint16 netuid) external view returns (bool exists, bytes32 successor);

    function removeStake(bytes32 hotkey, uint256 amount, uint256 netuid) external payable;

    function getNominatorMinRequiredStake() external view returns (uint256);

    function getDefaultMinStake() external view returns (uint256);

    function getColdkeyLock(bytes32 coldkey, uint256 netuid) external view
        returns (bool exists, bytes32 hotkey, uint256 lockedAlpha, uint128 conviction, bool perpetual);

    function getRejectLockedAlpha(bytes32 coldkey) external view returns (bool);

    function getColdkeyRoot(bytes32 coldkey) external view returns (bool exists, bytes32 root);

    function getOwnedHotkeys(bytes32 coldkey) external view returns (bytes32[] memory);
}

address constant STAKING_PRECOMPILE = 0x0000000000000000000000000000000000000805;

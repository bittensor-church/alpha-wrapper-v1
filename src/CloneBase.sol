// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { IStaking, STAKING_PRECOMPILE } from "./interfaces/IStaking.sol";

abstract contract CloneBase {
    address public wrapper;
    bool public initialized;

    error AlreadyInitialized();
    error NotWrapper();

    /// @dev Disable initialization on the implementation; clones have fresh storage.
    constructor() { initialized = true; }

    modifier onlyWrapper() { if (msg.sender != wrapper) revert NotWrapper(); _; }

    /// @dev Refusing staking-list growth keeps strangers from filling the list that admits deposits.
    function initialize() external {
        if (initialized) revert AlreadyInitialized();
        wrapper = msg.sender; initialized = true;
        _claimOwnHotkey();
        IStaking(STAKING_PRECOMPILE).setRejectStakingHotkeyGrowth(true);
    }

    function _claimOwnHotkey() internal virtual { }

    /// @notice Transfer staked alpha to another coldkey without changing its hotkey or subnet.
    function flush(bytes32 destinationColdkey, bytes32 hotkey, uint256 netuid, uint256 amount) external onlyWrapper {
        if (amount > 0) { IStaking(STAKING_PRECOMPILE).transferStake(destinationColdkey, hotkey, netuid, netuid, amount); }
    }

    /// @param amount Native TAO in EVM wei.
    function unwrapTao(address payable to, uint256 amount) external onlyWrapper {
        if (amount > 0) Address.sendValue(to, amount);
    }

    function sellAlphaForTao(bytes32 hotkey, uint256 netuid, uint256 amount) external onlyWrapper {
        if (amount > 0) { IStaking(STAKING_PRECOMPILE).removeStake(hotkey, amount, netuid); }
    }

}

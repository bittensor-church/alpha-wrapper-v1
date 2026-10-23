// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

address constant BALANCE_TRANSFER_PRECOMPILE = 0x0000000000000000000000000000000000000800;

interface IBalanceTransfer {
    function transferAll(bytes32 destination, bool keepAlive) external;
}

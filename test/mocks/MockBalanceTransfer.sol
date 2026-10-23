// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Vm } from "forge-std/Vm.sol";
import { MockStaking, VM_ADDRESS } from "./MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

contract MockBalanceTransfer {
    Vm private constant VM = Vm(VM_ADDRESS);

    function transferAll(bytes32 destination, bool keepAlive) external {
        require(!keepAlive, "MockBalanceTransfer: keep-alive unsupported");
        address target = MockStaking(STAKING_PRECOMPILE).evmAccountOf(destination);
        require(target != address(0), "MockBalanceTransfer: unknown destination");
        uint256 amount = msg.sender.balance;
        VM.deal(msg.sender, 0);
        VM.deal(target, target.balance + amount);
    }
}

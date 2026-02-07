// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {VortexAgent} from "../src/VortexAgent.sol";

contract DeployVortexAgentScript is Script {
    function run() public {
        address poolManager = vm.envOr("POOL_MANAGER", address(0));
        if (poolManager == address(0)) revert("Set POOL_MANAGER");
        vm.startBroadcast();
        new VortexAgent(poolManager);
        vm.stopBroadcast();
    }
}

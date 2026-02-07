// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VortexAgent} from "../src/VortexAgent.sol";

contract VortexAgentTest is Test {
    VortexAgent public agent;
    address poolManager;

    function setUp() public {
        poolManager = address(0x1111);
        agent = new VortexAgent(poolManager);
    }

    function test_Constructor() public view {
        assertEq(address(agent.poolManager()), poolManager);
    }

    function test_NameAndSymbol() public view {
        assertEq(agent.name(), "VortexAgent Position");
        assertEq(agent.symbol(), "VAP");
    }
}

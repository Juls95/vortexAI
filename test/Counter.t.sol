// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VortexAgent} from "../src/VortexAgent.sol";
import {OptionalHook} from "../src/OptionalHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

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

contract OptionalHookTest is Test {
    function test_ConstructorRevertsWhenVortexAgentZero() public {
        address pm = address(0x1111);
        vm.expectRevert(OptionalHook.HookAddressNotValid.selector);
        new OptionalHook(IPoolManager(pm), address(0), address(0));
    }

    function test_ConstructorRevertsWhenPoolManagerZero() public {
        address agent = address(0x2222);
        vm.expectRevert(OptionalHook.HookAddressNotValid.selector);
        new OptionalHook(IPoolManager(address(0)), agent, address(0));
    }
}

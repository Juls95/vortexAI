// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {VortexAgent} from "../src/VortexAgent.sol";
import {OptionalHook} from "../src/OptionalHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

// =============================================================================
// Deploy VortexAgent (and optionally OptionalHook) for Sepolia or anvil fork
// =============================================================================
//
// Sepolia (live):
//   POOL_MANAGER=<Sepolia_PoolManager> forge script script/DeployVortexAgent.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --verify
//
// Local anvil fork (test against Sepolia state without broadcasting):
//   anvil --fork-url $SEPOLIA_RPC_URL
//   POOL_MANAGER=<Sepolia_PoolManager> forge script script/DeployVortexAgent.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
//
// Dry-run (no broadcast):
//   POOL_MANAGER=0x0000000000000000000000000000000000000001 forge script script/DeployVortexAgent.s.sol -vvvv
//
// Env:
//   POOL_MANAGER   (required when broadcasting) Uniswap v4 PoolManager address on target chain.
//   DEPLOY_HOOK   (optional) Set to 1 to deploy OptionalHook (fork only; real net needs CREATE2 for valid hook address).
//   CURRENCY0     (optional) Example pool key currency0 (address). Default: 0x0000...0001
//   CURRENCY1     (optional) Example pool key currency1 (address). Default: 0x0000...0002
//   FEE           (optional) Example pool fee. Default: 3000
//   TICK_SPACING  (optional) Example tick spacing. Default: 60
// =============================================================================

contract DeployVortexAgentScript is Script {
    function run() public {
        address poolManagerAddr = vm.envOr("POOL_MANAGER", address(0));
        if (poolManagerAddr == address(0)) revert("Set POOL_MANAGER");

        vm.startBroadcast();

        VortexAgent vortexAgent = new VortexAgent(poolManagerAddr);

        OptionalHook hook = OptionalHook(address(0));
        if (vm.envOr("DEPLOY_HOOK", uint256(0)) == 1) {
            hook = new OptionalHook(
                IPoolManager(poolManagerAddr),
                address(vortexAgent),
                address(0) // oracleKeeper optional
            );
            console.log("OptionalHook deployed at:", address(hook));
        }

        vm.stopBroadcast();

        // Example pool key (for docs / cast usage)
        address currency0 = vm.envOr("CURRENCY0", address(0));
        if (currency0 == address(0)) currency0 = address(0x0000000000000000000000000000000000000001);
        address currency1 = vm.envOr("CURRENCY1", address(0));
        if (currency1 == address(0)) currency1 = address(0x0000000000000000000000000000000000000002);
        uint24 fee = uint24(vm.envOr("FEE", uint256(3000)));
        int24 tickSpacing = int24(uint24(vm.envOr("TICK_SPACING", uint256(60))));

        address c0 = currency0 < currency1 ? currency0 : currency1;
        address c1 = currency0 < currency1 ? currency1 : currency0;
        PoolKey memory exampleKey = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: address(hook) != address(0) ? IHooks(address(hook)) : IHooks(address(0))
        });

        console.log("VortexAgent deployed at:", address(vortexAgent));
        console.log("Example pool key currency0:", c0);
        console.log("Example pool key currency1:", c1);
        console.log("Example pool key fee:", exampleKey.fee);
        console.log("Example pool key tickSpacing:", uint256(int256(exampleKey.tickSpacing)));
        console.log("Example pool key hooks:", address(exampleKey.hooks));
    }
}

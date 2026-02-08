// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

// =============================================================================
// Initialize a Uniswap v4 pool (once per PoolKey) so addLiquidity can succeed.
// Run this before InteractiveVortexAgent or any addLiquidity for that pool.
// =============================================================================
//
// Usage:
//   POOL_MANAGER=$POOL_MANAGER forge script script/InitializePool.s.sol:InitializePoolScript \
//     --rpc-url $SEPOLIA_RPC_URL --broadcast --private-key $PRIVATE_KEY
//
// Env (same as InteractiveVortexAgent / DeployVortexAgent defaults):
//   POOL_MANAGER   (required)
//   CURRENCY0      default 0x0000000000000000000000000000000000000001
//   CURRENCY1      default 0x0000000000000000000000000000000000000002
//   FEE            default 3000
//   TICK_SPACING   default 60
//   HOOKS          default 0x0000000000000000000000000000000000000000
// =============================================================================

contract InitializePoolScript is Script {
    /// @dev 1:1 price in Q64.96 (same as v4-core test Constants.SQRT_PRICE_1_1)
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function run() external {
        address poolManagerAddr = vm.envOr("POOL_MANAGER", address(0));
        if (poolManagerAddr == address(0)) revert("Set POOL_MANAGER");

        PoolKey memory key = _makePoolKey();

        vm.startBroadcast();
        IPoolManager pm = IPoolManager(poolManagerAddr);
        int24 tick = pm.initialize(key, SQRT_PRICE_1_1);
        vm.stopBroadcast();

        console.log("Pool initialized; initial tick:", uint256(int256(tick)));
    }

    function _makePoolKey() internal view returns (PoolKey memory) {
        address c0 = vm.envOr("CURRENCY0", address(0x0000000000000000000000000000000000000001));
        address c1 = vm.envOr("CURRENCY1", address(0x0000000000000000000000000000000000000002));
        if (uint160(c0) > uint160(c1)) (c0, c1) = (c1, c0);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: uint24(vm.envOr("FEE", uint256(3000))),
            tickSpacing: int24(int256(vm.envOr("TICK_SPACING", int256(60)))),
            hooks: IHooks(vm.envOr("HOOKS", address(0)))
        });
    }
}

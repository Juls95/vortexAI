// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MockERC20} from "./MockERC20.sol";

// =============================================================================
// Deploy two mock ERC20 tokens on Sepolia for VortexAgent pool testing.
// Mints 1e24 (1M with 18 decimals) to the broadcaster. Use the logged
// CURRENCY0 and CURRENCY1 (sorted by address) for InitializePool and
// InteractiveVortexAgent, then approve VortexAgent and add liquidity.
// =============================================================================
//
// Usage:
//   forge script script/DeployMockCurrencies.s.sol:DeployMockCurrenciesScript \
//     --rpc-url $SEPOLIA_RPC_URL --broadcast --private-key $PRIVATE_KEY
//
// Then set in .env or export:
//   CURRENCY0=<first logged address>
//   CURRENCY1=<second logged address>
//   VORTEX_AGENT=<your VortexAgent address>
//
// Approve VortexAgent (e.g. 1e24 each):
//   cast send $CURRENCY0 "approve(address,uint256)" $VORTEX_AGENT 1000000000000000000000000 --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY
//   cast send $CURRENCY1 "approve(address,uint256)" $VORTEX_AGENT 1000000000000000000000000 --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY
//
// Then: InitializePool (with CURRENCY0, CURRENCY1), then InteractiveVortexAgent.
// =============================================================================

contract DeployMockCurrenciesScript is Script {
    uint256 internal constant MINT_AMOUNT = 1e24; // 1M tokens (18 decimals)

    function run() external {
        vm.startBroadcast();

        MockERC20 tokenA = new MockERC20("Test Token A", "TTA");
        MockERC20 tokenB = new MockERC20("Test Token B", "TTB");
        address a = address(tokenA);
        address b = address(tokenB);

        (address c0, address c1) = a < b ? (a, b) : (b, a);
        MockERC20(c0).mint(msg.sender, MINT_AMOUNT);
        MockERC20(c1).mint(msg.sender, MINT_AMOUNT);

        vm.stopBroadcast();

        console.log("CURRENCY0 (use as env):", c0);
        console.log("CURRENCY1 (use as env):", c1);
        console.log("Minted", MINT_AMOUNT, "of each to", msg.sender);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {VortexAgent} from "../src/VortexAgent.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";

// =============================================================================
// INTERACTIVE SCRIPT: define liquidity ranges via env vars, check NFT state
// =============================================================================
//
// Usage (simulation, no broadcast):
//   TICK_LOWER_1=-1000 TICK_UPPER_1=1000 LIQUIDITY_1=1000000000000000000 \
//   forge script script/InteractiveVortexAgent.s.sol --sig "run()" -vvvv
//
// Add a second range to the same NFT:
//   TICK_LOWER_2=-2000 TICK_UPPER_2=0 LIQUIDITY_2=2000000000000000000 \
//   forge script script/InteractiveVortexAgent.s.sol:InteractiveVortexAgentScript --sig "run()"
//
// With broadcast (testnet/mainnet), set POOL_MANAGER and optionally VORTEX_AGENT:
//   forge script script/InteractiveVortexAgent.s.sol --sig "run()" --broadcast -vvvv
//
// Env vars (optional; defaults shown):
//   POOL_MANAGER     = (deploy mock if unset)
//   VORTEX_AGENT     = (deploy if unset)
//   USER             = msg.sender / 0xBEEF in sim
//   TICK_LOWER_1     = -1020   (must be multiple of TICK_SPACING, e.g. 60)
//   TICK_UPPER_1     = 1020
//   LIQUIDITY_1      = 1e18
//   TICK_LOWER_2     = (skip second range if unset)
//   TICK_UPPER_2     =
//   LIQUIDITY_2      =
//   CURRENCY0        = 0x0000000000000000000000000000000000000001
//   CURRENCY1        = 0x0000000000000000000000000000000000000002
//   FEE              = 3000
//   TICK_SPACING     = 60
// =============================================================================

contract InteractiveVortexAgentScript is Script {
    using PoolIdLibrary for PoolKey;

    function run() public {
        int24 tickLower1 = int24(vm.envOr("TICK_LOWER_1", int256(-1020)));
        int24 tickUpper1 = int24(vm.envOr("TICK_UPPER_1", int256(1020)));
        int256 liquidity1 = int256(vm.envOr("LIQUIDITY_1", uint256(1e18)));
        int24 tickLower2 = int24(vm.envOr("TICK_LOWER_2", int256(0)));   // 0 = skip
        int24 tickUpper2 = int24(vm.envOr("TICK_UPPER_2", int256(0)));
        uint256 liquidity2U = vm.envOr("LIQUIDITY_2", uint256(0));
        bool addSecondRange = (vm.envOr("TICK_LOWER_2", int256(0)) != 0 || liquidity2U != 0);

        address poolManagerAddr = vm.envOr("POOL_MANAGER", address(0));
        address agentAddr = vm.envOr("VORTEX_AGENT", address(0));

        PoolKey memory key = _makePoolKey();

        vm.startBroadcast();

        if (poolManagerAddr == address(0)) {
            (poolManagerAddr,) = _deployMock();
            console.log("Deployed MockPoolManager at", poolManagerAddr);
        }
        VortexAgent agent;
        if (agentAddr == address(0)) {
            agent = new VortexAgent(poolManagerAddr);
            agentAddr = address(agent);
            console.log("Deployed VortexAgent at", agentAddr);
        } else {
            agent = VortexAgent(agentAddr);
        }

        // --- First range (mint NFT if tokenId 0) ---
        console.log("--- Add range 1 ---");
        console.log("tickLower");
        console.logInt(int256(tickLower1));
        console.log("tickUpper", uint256(int256(tickUpper1)));
        console.log("liquidity", uint256(int256(liquidity1)));
        agent.addLiquidity(0, key, tickLower1, tickUpper1, liquidity1, "");
        uint256 tokenId = agent.totalSupply();
        console.log("NFT minted/used tokenId=", tokenId);
        console.log("Owner", agent.ownerOf(tokenId));
        console.log("Total supply", agent.totalSupply());
        _logRanges(agent, tokenId);

        if (addSecondRange && liquidity2U != 0) {
            int256 liquidity2 = int256(liquidity2U);
            if (vm.envOr("TICK_LOWER_2", int256(0)) == 0) tickLower2 = -2000;
            if (vm.envOr("TICK_UPPER_2", int256(0)) == 0) tickUpper2 = 0;
            console.log("--- Add range 2 ---");
            console.log("tickLower");
            console.logInt(int256(tickLower2));
            console.log("tickUpper", uint256(int256(tickUpper2)));
            console.log("liquidity=", liquidity2U);
            agent.addLiquidity(tokenId, key, tickLower2, tickUpper2, liquidity2, "");
            console.log("NFT tokenId=", tokenId);
            console.log("owner", agent.ownerOf(tokenId));
            _logRanges(agent, tokenId);
        }

        console.log("--- Done ---");
        vm.stopBroadcast();
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

    function _deployMock() internal returns (address, address) {
        // Deploy a minimal mock inline (no dependency on test file)
        MockPoolManager mock = new MockPoolManager();
        return (address(mock), address(0));
    }

    function _logRanges(VortexAgent agent, uint256 tokenId) internal view {
        uint256 n = agent.getRangeCount(tokenId);
        console.log("Range count", n);
        // getRanges(tokenId) can be called on-chain to read tickLower[], tickUpper[], liquidity[] per range
        if (n == 0) return;
        console.log("(Call getRanges(tokenId) on-chain for tick/liquidity per range)");
    }
}

// Minimal mock for script (no import from test)
contract MockPoolManager is IPoolManager {
    using PoolIdLibrary for PoolKey;

    bool private _unlocked;

    function unlock(bytes calldata data) external returns (bytes memory) {
        require(!_unlocked, "AlreadyUnlocked");
        _unlocked = true;
        bytes memory result = IUnlockCallback(msg.sender).unlockCallback(data);
        _unlocked = false;
        return result;
    }

    function modifyLiquidity(PoolKey memory, IPoolManager.ModifyLiquidityParams memory, bytes calldata)
        external
        returns (BalanceDelta, BalanceDelta)
    {
        require(_unlocked, "ManagerLocked");
        return (BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function sync(Currency) external {}
    function take(Currency, address, uint256) external {}
    function settle() external payable returns (uint256) { return 0; }
    function settleFor(address) external payable returns (uint256) { return 0; }
    function mint(address, uint256, uint256) external {}
    function burn(address, uint256, uint256) external {}
    function initialize(PoolKey memory, uint160) external returns (int24) { return 0; }
    function swap(PoolKey memory, IPoolManager.SwapParams memory, bytes calldata) external returns (BalanceDelta) { return BalanceDeltaLibrary.ZERO_DELTA; }
    function donate(PoolKey memory, uint256, uint256, bytes calldata) external returns (BalanceDelta) { return BalanceDeltaLibrary.ZERO_DELTA; }
    function clear(Currency, uint256) external {}
    function updateDynamicLPFee(PoolKey memory, uint24) external {}
    function extsload(bytes32) external pure returns (bytes32) { return bytes32(0); }
    function extsload(bytes32, uint256) external pure returns (bytes32[] memory) { return new bytes32[](0); }
    function extsload(bytes32[] calldata) external pure returns (bytes32[] memory) { return new bytes32[](0); }
    function exttload(bytes32) external pure returns (bytes32) { return bytes32(0); }
    function exttload(bytes32[] calldata) external pure returns (bytes32[] memory) { return new bytes32[](0); }
    function protocolFeesAccrued(Currency) external pure returns (uint256) { return 0; }
    function setProtocolFeeController(address) external {}
    function setProtocolFee(PoolKey memory, uint24) external {}
    function collectProtocolFees(address, Currency, uint256) external returns (uint256) { return 0; }
    function protocolFeeController() external pure returns (address) { return address(0); }
    function balanceOf(address, uint256) external pure returns (uint256) { return 0; }
    function allowance(address, address, uint256) external pure returns (uint256) { return 0; }
    function isOperator(address, address) external pure returns (bool) { return false; }
    function transfer(address, uint256, uint256) external returns (bool) { return true; }
    function transferFrom(address, address, uint256, uint256) external returns (bool) { return true; }
    function approve(address, uint256, uint256) external returns (bool) { return true; }
    function setOperator(address, bool) external returns (bool) { return true; }
}

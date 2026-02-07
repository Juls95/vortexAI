// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";

/// @title OptionalHook
/// @notice Uniswap v4 hook that charges a small dynamic fee (0.01%) on liquidity modifications
///         when the caller is the VortexAgent, rewarding keepers. Uses beforeAddLiquidity,
///         beforeRemoveLiquidity, and afterSwap for transparency and oracle composability.
contract OptionalHook is IHooks {
    using SafeCast for uint256;

    /// @dev 0.01% = 1 basis point = 1/10000
    uint256 internal constant FEE_BPS = 1;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @dev PoolManager; only it may call hook functions.
    IPoolManager public immutable poolManager;

    /// @dev VortexAgent contract; fee is charged only when this address is the modifyLiquidity sender.
    address public immutable vortexAgent;

    /// @dev Optional oracle / keeper address for composability (e.g. for events or future extensions).
    address public immutable oracleKeeper;

    error OnlyPoolManager();
    error HookAddressNotValid();

    event AgentBeforeAddLiquidity(
        address indexed sender,
        PoolKey key,
        IPoolManager.ModifyLiquidityParams params,
        bytes hookData
    );
    event AgentBeforeRemoveLiquidity(
        address indexed sender,
        PoolKey key,
        IPoolManager.ModifyLiquidityParams params,
        bytes hookData
    );
    event AgentAfterAddLiquidityFee(address indexed sender, int128 fee0, int128 fee1);
    event AgentAfterRemoveLiquidityFee(address indexed sender, int128 fee0, int128 fee1);
    event SwapForTransparency(
        address indexed sender,
        PoolKey key,
        IPoolManager.SwapParams params,
        BalanceDelta delta,
        bytes hookData
    );

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    /// @param _poolManager Uniswap v4 PoolManager.
    /// @param _vortexAgent VortexAgent contract; fee applies only when sender == _vortexAgent.
    /// @param _oracleKeeper Optional address for oracle/keeper composability (can be address(0)).
    /// @dev Deploy via CREATE2 so the deployed address has the correct hook permission bits (see Hooks library).
    constructor(IPoolManager _poolManager, address _vortexAgent, address _oracleKeeper) {
        if (address(_poolManager) == address(0) || _vortexAgent == address(0)) revert HookAddressNotValid();
        poolManager = _poolManager;
        vortexAgent = _vortexAgent;
        oracleKeeper = _oracleKeeper;

        Hooks.validateHookPermissions(
            this,
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: true,
                afterAddLiquidity: true,
                beforeRemoveLiquidity: true,
                afterRemoveLiquidity: true,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: true,
                afterRemoveLiquidityReturnDelta: true
            })
        );
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external onlyPoolManager returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external onlyPoolManager returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4) {
        if (sender == vortexAgent) {
            emit AgentBeforeAddLiquidity(sender, key, params, hookData);
        }
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address sender,
        PoolKey calldata, /* key */
        IPoolManager.ModifyLiquidityParams calldata, /* params */
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, BalanceDelta) {
        if (sender != vortexAgent) {
            return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
        }
        (int128 fee0, int128 fee1) = _feeFromDelta(delta, true);
        emit AgentAfterAddLiquidityFee(sender, fee0, fee1);
        return (IHooks.afterAddLiquidity.selector, toBalanceDelta(fee0, fee1));
    }

    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4) {
        if (sender == vortexAgent) {
            emit AgentBeforeRemoveLiquidity(sender, key, params, hookData);
        }
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata, /* key */
        IPoolManager.ModifyLiquidityParams calldata, /* params */
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, BalanceDelta) {
        if (sender != vortexAgent) {
            return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
        }
        (int128 fee0, int128 fee1) = _feeFromDelta(delta, false);
        emit AgentAfterRemoveLiquidityFee(sender, fee0, fee1);
        return (IHooks.afterRemoveLiquidity.selector, toBalanceDelta(fee0, fee1));
    }

    function beforeSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, int128) {
        emit SwapForTransparency(sender, key, params, delta, hookData);
        return (IHooks.afterSwap.selector, 0);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @dev Compute 0.01% fee from |delta|; hook receives this as positive BalanceDelta (caller pays / receives less).
    function _feeFromDelta(BalanceDelta delta, bool) internal pure returns (int128 fee0, int128 fee1) {
        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();
        uint128 abs0 = a0 < 0 ? uint128(-a0) : uint128(a0);
        uint128 abs1 = a1 < 0 ? uint128(-a1) : uint128(a1);
        uint256 f0 = (uint256(abs0) * FEE_BPS) / BPS_DENOMINATOR;
        uint256 f1 = (uint256(abs1) * FEE_BPS) / BPS_DENOMINATOR;
        fee0 = f0.toInt128();
        fee1 = f1.toInt128();
    }

    error HookNotImplemented();
}

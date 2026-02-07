// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "solady/tokens/ERC721.sol";
import {RedBlackTreeLib} from "solady/utils/RedBlackTreeLib.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";

/// @title VortexAgent
/// @notice Multi-range Uniswap v4 position manager: one ERC721 NFT holds multiple liquidity ranges.
///         Integrates with PoolManager via unlock callback; supports agentic rebalance around current tick.
contract VortexAgent is ERC721, IUnlockCallback {
    using RedBlackTreeLib for RedBlackTreeLib.Tree;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    /// @dev Offset for encoding int24 ticks as uint256 (handles negative ticks; Solady tree does not support 0).
    uint256 internal constant TICK_OFFSET = 887273;

    /// @dev Rebalance target: concentrate this fraction of liquidity within ±REBALANCE_TICK_WINDOW of current tick.
    uint256 internal constant REBALANCE_INNER_PERCENT = 80;
    uint256 internal constant REBALANCE_TICK_WINDOW = 500;

    IPoolManager public immutable poolManager;

    struct RangeInfo {
        uint256 encodedTickUpper;
        int256 liquidity;
    }

    /// @dev tokenId => Red-Black tree of encoded tick lowers (ascending).
    mapping(uint256 => RedBlackTreeLib.Tree) private _positionTrees;
    /// @dev tokenId => encodedTickLower => RangeInfo
    mapping(uint256 => mapping(uint256 => RangeInfo)) private _rangeInfo;
    /// @dev tokenId => pool key (set on first add for that position).
    mapping(uint256 => PoolKey) private _poolKeyByTokenId;
    /// @dev tokenId => whether this position has ever had liquidity (pool key fixed).
    mapping(uint256 => bool) private _positionInitialized;

    uint256 private _nextTokenId;

    struct LiquidityAction {
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        bytes32 salt;
    }

    enum UnlockAction {
        AddLiquidity,
        RemoveLiquidity,
        Rebalance
    }

    struct UnlockData {
        UnlockAction action;
        uint256 tokenId;
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        int24 currentTick;
        bytes hookData;
    }

    error InvalidTokenId();
    error NotTokenOwner();
    error PoolKeyMismatch();
    error PositionNotInitialized();
    error ZeroLiquidity();

    constructor(address _poolManager) {
        if (_poolManager == address(0)) revert();
        poolManager = IPoolManager(_poolManager);
    }

    function name() public view virtual override returns (string memory) {
        return "VortexAgent Position";
    }

    function symbol() public view virtual override returns (string memory) {
        return "VAP";
    }

    function tokenURI(uint256 id) public view virtual override returns (string memory) {
        if (_ownerOf(id) == address(0)) revert();
        return "";
    }

    /// @notice Add liquidity to a range for a position (mints NFT if tokenId is 0).
    /// @param tokenId Position NFT id; pass 0 to mint a new position.
    /// @param key Pool key (must match existing pool for position if tokenId != 0).
    /// @param tickLower Lower tick of the range.
    /// @param tickUpper Upper tick of the range.
    /// @param liquidityDelta Liquidity to add (positive).
    /// @param hookData Data passed through to pool hooks.
    function addLiquidity(
        uint256 tokenId,
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        bytes calldata hookData
    ) external payable {
        if (liquidityDelta <= 0) revert ZeroLiquidity();
        if (tokenId == 0) {
            tokenId = _mintNext(msg.sender);
        } else {
            if (_ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        }
        _ensurePoolKey(tokenId, key);
        _applyLiquidityChange(tokenId, key, tickLower, tickUpper, liquidityDelta, true);
        poolManager.unlock(
            abi.encode(
                UnlockData({
                    action: UnlockAction.AddLiquidity,
                    tokenId: tokenId,
                    key: key,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: liquidityDelta,
                    currentTick: 0,
                    hookData: hookData
                })
            )
        );
    }

    /// @notice Remove liquidity from a range.
    /// @param tokenId Position NFT id.
    /// @param key Pool key (must match position's pool).
    /// @param tickLower Lower tick of the range.
    /// @param tickUpper Upper tick of the range.
    /// @param liquidityDelta Liquidity to remove (positive; will be negated internally).
    /// @param hookData Data passed through to pool hooks.
    function removeLiquidity(
        uint256 tokenId,
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        bytes calldata hookData
    ) external payable {
        if (_ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        if (!_positionInitialized[tokenId]) revert PositionNotInitialized();
        if (PoolId.unwrap(_poolKeyByTokenId[tokenId].toId()) != PoolId.unwrap(key.toId())) revert PoolKeyMismatch();
        if (liquidityDelta <= 0) revert ZeroLiquidity();
        _applyLiquidityChange(tokenId, key, tickLower, tickUpper, -liquidityDelta, false);
        poolManager.unlock(
            abi.encode(
                UnlockData({
                    action: UnlockAction.RemoveLiquidity,
                    tokenId: tokenId,
                    key: key,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: -liquidityDelta,
                    currentTick: 0,
                    hookData: hookData
                })
            )
        );
    }

    /// @notice Rebalance position so ~80% of liquidity is within ±500 ticks of current tick.
    /// @param tokenId Position NFT id.
    /// @param currentTick Current pool tick (use int24; for negative ticks pass as signed value).
    /// @param hookData Data passed through to pool hooks.
    function rebalance(uint256 tokenId, int24 currentTick, bytes calldata hookData) external payable {
        if (_ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        if (!_positionInitialized[tokenId]) revert PositionNotInitialized();
        PoolKey memory key = _poolKeyByTokenId[tokenId];
        poolManager.unlock(
            abi.encode(
                UnlockData({
                    action: UnlockAction.Rebalance,
                    tokenId: tokenId,
                    key: key,
                    tickLower: 0,
                    tickUpper: 0,
                    liquidityDelta: 0,
                    currentTick: currentTick,
                    hookData: hookData
                })
            )
        );
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert();
        UnlockData memory ud = abi.decode(data, (UnlockData));
        LiquidityAction[] memory actions = _populateActions(ud);
        for (uint256 i = 0; i < actions.length; i++) {
            LiquidityAction memory a = actions[i];
            if (a.liquidityDelta == 0) continue;
            (, BalanceDelta delta) = poolManager.modifyLiquidity(
                ud.key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: a.tickLower,
                    tickUpper: a.tickUpper,
                    liquidityDelta: a.liquidityDelta,
                    salt: a.salt
                }),
                ud.hookData
            );
            _accumulateAndSettle(ud.key, delta);
        }
        return "";
    }

    /// @dev Ensures position's pool key is set and matches.
    function _ensurePoolKey(uint256 tokenId, PoolKey memory key) internal {
        if (!_positionInitialized[tokenId]) {
            _poolKeyByTokenId[tokenId] = key;
            _positionInitialized[tokenId] = true;
        } else {
            if (PoolId.unwrap(_poolKeyByTokenId[tokenId].toId()) != PoolId.unwrap(key.toId())) revert PoolKeyMismatch();
        }
    }

    /// @dev Encode int24 tick for tree storage (no zero; negative ticks supported via TICK_OFFSET).
    function _encodeTick(int24 tick) internal pure returns (uint256) {
        return uint256(int256(tick) + int256(TICK_OFFSET));
    }

    /// @dev Decode stored tick back to int24.
    function _decodeTick(uint256 encoded) internal pure returns (int24) {
        return int24(int256(encoded - TICK_OFFSET));
    }

    /// @dev Apply liquidity delta to in-memory tree and range info (for add/remove).
    function _applyLiquidityChange(
        uint256 tokenId,
        PoolKey memory,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        bool isAdd
    ) internal {
        uint256 encLower = _encodeTick(tickLower);
        uint256 encUpper = _encodeTick(tickUpper);
        RangeInfo storage info = _rangeInfo[tokenId][encLower];
        RedBlackTreeLib.Tree storage tree = _positionTrees[tokenId];

        if (isAdd) {
            if (!tree.exists(encLower)) {
                tree.insert(encLower);
            }
            info.encodedTickUpper = encUpper;
            info.liquidity += liquidityDelta;
        } else {
            info.liquidity += liquidityDelta;
            if (info.liquidity <= 0) {
                if (tree.exists(encLower)) {
                    tree.remove(encLower);
                }
                delete _rangeInfo[tokenId][encLower];
            }
        }
    }

    /// @dev Build list of modifyLiquidity actions for the current unlock (add, remove, or rebalance).
    function _populateActions(UnlockData memory ud) internal returns (LiquidityAction[] memory) {
        if (ud.action == UnlockAction.AddLiquidity) {
            LiquidityAction[] memory actions = new LiquidityAction[](1);
            actions[0] = LiquidityAction({
                tickLower: ud.tickLower,
                tickUpper: ud.tickUpper,
                liquidityDelta: ud.liquidityDelta,
                salt: _saltFor(ud.tokenId, ud.tickLower, ud.tickUpper)
            });
            return actions;
        }
        if (ud.action == UnlockAction.RemoveLiquidity) {
            LiquidityAction[] memory actions = new LiquidityAction[](1);
            actions[0] = LiquidityAction({
                tickLower: ud.tickLower,
                tickUpper: ud.tickUpper,
                liquidityDelta: ud.liquidityDelta,
                salt: _saltFor(ud.tokenId, ud.tickLower, ud.tickUpper)
            });
            return actions;
        }
        // Rebalance: remove all ranges, then add 80% in ±REBALANCE_TICK_WINDOW, 20% in wider band.
        return _populateRebalanceActions(ud);
    }

    /// @dev Populate actions for rebalance: remove from all ranges, add 80% within ±500 ticks, 20% in wider.
    function _populateRebalanceActions(UnlockData memory ud) internal returns (LiquidityAction[] memory) {
        RedBlackTreeLib.Tree storage tree = _positionTrees[ud.tokenId];
        uint256 n = tree.size();
        if (n == 0) return new LiquidityAction[](0);

        int24 currentTick = ud.currentTick;
        int24 innerLower = currentTick - int24(uint24(REBALANCE_TICK_WINDOW));
        int24 innerUpper = currentTick + int24(uint24(REBALANCE_TICK_WINDOW));

        uint256 totalLiquidity = 0;
        LiquidityAction[] memory removes = new LiquidityAction[](n);
        uint256 removeCount = 0;

        for (bytes32 ptr = tree.first(); !RedBlackTreeLib.isEmpty(ptr); ptr = RedBlackTreeLib.next(ptr)) {
            uint256 encLower = RedBlackTreeLib.value(ptr);
            RangeInfo storage info = _rangeInfo[ud.tokenId][encLower];
            if (info.liquidity <= 0) continue;
            int24 tickLower = _decodeTick(encLower);
            int24 tickUpper = _decodeTick(info.encodedTickUpper);
            totalLiquidity += uint256(int256(info.liquidity));
            removes[removeCount++] = LiquidityAction({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -info.liquidity,
                salt: _saltFor(ud.tokenId, tickLower, tickUpper)
            });
        }

        // Clear in-storage liquidity and tree for this position (we are rebalancing).
        for (uint256 i = 0; i < removeCount; i++) {
            uint256 encLower = _encodeTick(removes[i].tickLower);
            if (_positionTrees[ud.tokenId].exists(encLower)) {
                _positionTrees[ud.tokenId].remove(encLower);
            }
            delete _rangeInfo[ud.tokenId][encLower];
        }

        if (totalLiquidity == 0) return removes;

        uint256 innerLiquidity = (totalLiquidity * REBALANCE_INNER_PERCENT) / 100;
        uint256 outerLiquidity = totalLiquidity - innerLiquidity;
        uint256 outerHalf = outerLiquidity / 2;

        // Inner: ±REBALANCE_TICK_WINDOW (80%). Outer bands: [current-1000, current-500] and [current+500, current+1000] (20% total).
        int24 leftLower = currentTick - int24(uint24(REBALANCE_TICK_WINDOW * 2));
        int24 leftUpper = currentTick - int24(uint24(REBALANCE_TICK_WINDOW));
        int24 rightLower = currentTick + int24(uint24(REBALANCE_TICK_WINDOW));
        int24 rightUpper = currentTick + int24(uint24(REBALANCE_TICK_WINDOW * 2));

        LiquidityAction[] memory actions = new LiquidityAction[](removeCount + 3);
        for (uint256 i = 0; i < removeCount; i++) {
            actions[i] = removes[i];
        }
        actions[removeCount] = LiquidityAction({
            tickLower: innerLower,
            tickUpper: innerUpper,
            liquidityDelta: int256(uint256(innerLiquidity)),
            salt: _saltFor(ud.tokenId, innerLower, innerUpper)
        });
        actions[removeCount + 1] = LiquidityAction({
            tickLower: leftLower,
            tickUpper: leftUpper,
            liquidityDelta: int256(uint256(outerHalf)),
            salt: _saltFor(ud.tokenId, leftLower, leftUpper)
        });
        actions[removeCount + 2] = LiquidityAction({
            tickLower: rightLower,
            tickUpper: rightUpper,
            liquidityDelta: int256(uint256(outerLiquidity - outerHalf)),
            salt: _saltFor(ud.tokenId, rightLower, rightUpper)
        });

        _applyLiquidityChange(ud.tokenId, ud.key, innerLower, innerUpper, int256(uint256(innerLiquidity)), true);
        _applyLiquidityChange(ud.tokenId, ud.key, leftLower, leftUpper, int256(uint256(outerHalf)), true);
        _applyLiquidityChange(ud.tokenId, ud.key, rightLower, rightUpper, int256(uint256(outerLiquidity - outerHalf)), true);

        return actions;
    }

    function _saltFor(uint256 tokenId, int24 tickLower, int24 tickUpper) internal pure returns (bytes32) {
        return keccak256(abi.encode(tokenId, tickLower, tickUpper));
    }

    /// @dev Settle or take for one delta so PoolManager sees zero net delta for this call.
    function _accumulateAndSettle(PoolKey memory key, BalanceDelta delta) internal {
        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();
        if (a0 > 0) {
            poolManager.take(key.currency0, address(this), uint128(a0));
        } else if (a0 < 0) {
            poolManager.sync(key.currency0);
            key.currency0.transfer(address(poolManager), uint128(-a0));
            poolManager.settle();
        }
        if (a1 > 0) {
            poolManager.take(key.currency1, address(this), uint128(a1));
        } else if (a1 < 0) {
            poolManager.sync(key.currency1);
            key.currency1.transfer(address(poolManager), uint128(-a1));
            poolManager.settle();
        }
    }

    /// @dev Mint next token id.
    function _mintNext(address to) internal returns (uint256 id) {
        id = _nextTokenId + 1;
        _nextTokenId = id;
        _mint(to, id);
        return id;
    }

    /// @dev Total number of minted positions.
    function totalSupply() public view returns (uint256) {
        return _nextTokenId;
    }
}

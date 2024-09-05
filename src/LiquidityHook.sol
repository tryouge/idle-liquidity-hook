// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

// import {UniswapV4ERC20} from "v4-periphery/libraries/UniswapV4ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";


contract LiquidityHook is BaseHook {

	using StateLibrary for IPoolManager;
	using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

	error PoolNotInitialized();
    error TickSpacingNotDefault();

	int24 tickBuffer = 20;

	struct PoolInfo {
        bool hasAccruedFees;
        address liquidityToken;
    }

	struct LiquidityState{
        int24 minTickWithLiqidity;
        int24 maxTickWithLiqidity;
        int24 lastTick;
        uint256 liquidity;
    }

	mapping(PoolId => PoolInfo) public poolInfo;
    mapping(PoolId => LiquidityState) public liquidityState;

	mapping(PoolId poolId =>
		mapping(int24 tick =>
			mapping(bool inLendingProtocol => uint256 amount))) public totalLiquidityState;


	constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

	function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterAddLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

	function beforeInitialize(address, PoolKey calldata key, uint160, bytes calldata)
        external
        override
        returns (bytes4)
    {
        if (key.tickSpacing != 60) revert TickSpacingNotDefault();
        PoolId poolId = key.toId();

        // string memory tokenSymbol = string(
        //     abi.encodePacked(
        //         "UniV4",
        //         "-",
        //         IERC20Metadata(Currency.unwrap(key.currency0)).symbol(),
        //         "-",
        //         IERC20Metadata(Currency.unwrap(key.currency1)).symbol(),
        //         "-",
        //         Strings.toString(uint256(key.fee))
        //     )
        // );
        
		// address poolToken = address(new UniswapV4ERC20(tokenSymbol, tokenSymbol));
        // poolInfo[poolId] = PoolInfo({hasAccruedFees: false, liquidityToken: poolToken});
        return this.beforeInitialize.selector;
    }

	function afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24 tick,
        bytes calldata
    ) external override returns (bytes4) {
        //
		liquidityState[key.toId()]= LiquidityState((tick - 60), (tick + 60), tick, 0);
        return this.afterInitialize.selector;
    }

	function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4) {
		PoolId poolId = key.toId();
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

		// Deciding how much has to be removed from Lending Protocol

		if (params.tickLower > currentTick + tickBuffer || params.tickUpper < currentTick - tickBuffer) {
			// withdrawFromLendingProtocol(params.tickLower, params.tickUpper);
		} 
		
		return this.beforeRemoveLiquidity.selector;
	}

	function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override returns (bytes4, BalanceDelta) {

		PoolId poolId = key.toId();
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

		// Deciding what ticks to deposit into Lending Protocol

		// If LP position tickLower > currentTick + tickBuffer 
		// (or) tickUpper < currentTick - tickBuffer
		// Example: current tick buffer = [80, 120] and LP Positition = [60, 70] or [125, 130]
		// LP position has no overlap with current tick buffer range => 
		// deposit all of LP position into Lending Protocol
		if (params.tickLower > currentTick + tickBuffer || params.tickUpper < currentTick - tickBuffer) {
			depositIntoLendingProtocol(params.tickLower, params.tickUpper);
		} 
		
		// Lower end overlap case
		else if (params.tickLower < currentTick - tickBuffer && params.tickUpper > currentTick - tickBuffer) {
			// Example: current tick buffer = [80, 120] and LP Position = [60, 90]
			// deposit [60, 79] into Lending Protocol
			depositIntoLendingProtocol(params.tickLower, currentTick - tickBuffer - 1);
			if (params.tickUpper > currentTick + tickBuffer) {
				// Example: current tick buffer = [80, 120] and LP Position = [60, 130]
				// Also deposit the extra [121, 130] into Lending Protocol
				depositIntoLendingProtocol(currentTick + tickBuffer + 1, params.tickUpper);
			}
		}

		// Upper end overlap case
		else if (params.tickUpper > currentTick + tickBuffer && params.tickLower < currentTick + tickBuffer) {
			// Example: current tick buffer = [80, 120] and LP Position = [90, 130]
			// deposit [121, 130] into Lending Protocol
			depositIntoLendingProtocol(currentTick + tickBuffer + 1, params.tickUpper);
			if (params.tickUpper > currentTick + tickBuffer) {
				// Example: current tick buffer = [80, 120] and LP Position = [60, 130]
				// Also deposit the extra [60, 79] into Lending Protocol
				depositIntoLendingProtocol(params.tickLower, currentTick - tickBuffer - 1);
			}
		}

		// Need someway to track sender's LP position so they can also remove LP position appropriately
		// Access sender's original LP position in beforeRemoveLiquidity and withdraw the
		// the required liquidity from the lending protocol to return back to the user

		return (this.afterAddLiquidity.selector, delta);
	}

	function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, int128) {
		PoolId poolId = key.toId();
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(poolId);
		int24 lastTick = liquidityState[poolId].lastTick;

		// Tick has shifted from lastTick to currentTick (Ex: 100 [80, 120] -> 110 [90, 130])
		// Deposit new idle liquidity into lending protocol i.e [80, 89]
		// Withdraw liquidity from lending protocol corresponding to [121, 130] and deposit into pool
		if (currentTick > lastTick) {
			depositIntoLendingProtocol(lastTick-tickBuffer,currentTick-tickBuffer-1);
			withdrawAllFromLendingProtocol(lastTick+tickBuffer+1,currentTick+tickBuffer+1);
		}
		// Tick has shifted from lastTick to currentTick (Ex: 100 [80, 120] -> 92 [72, 112])
		// Deposit new idle liquidity into lending protocol i.e [113, 120]
		// Withdraw liquidity from lending protocol corresponding to [72, 79] and deposit into pool
		else if (currentTick < lastTick) {
			depositIntoLendingProtocol(currentTick+tickBuffer+1,lastTick+tickBuffer);
			withdrawAllFromLendingProtocol(currentTick-tickBuffer,lastTick-tickBuffer-1);
		}
		
		// Update lastTick to new currentTick
		liquidityState[poolId].lastTick = currentTick;

        return (this.afterSwap.selector, 0);
    }

	// Function that moves liquidity (tickLower, tickUpper) from pool to lending protocol
	function depositIntoLendingProtocol(int24 tickLower, int24 tickUpper) private {
		// TODO
		// Move into lending protocol
		// Update totalLiquidityState mapping
	}

	// Function that withdraws liquidityAmount from lending protocol and deposits to pool (tickLower, tickUpper)
	function withdrawFromLendingProtocol(uint256 liquidityAmount, int24 tickLower, int24 tickUpper) private {
		// TODO
		// Withdraw from lending protocol, deposit into pool
		// Update totalLiquidityState mapping
	}

	// Function that withdraws all liquidity corresponding to tickLower and tickUpper range 
	// from lending protocol and deposits to pool (tickLower, tickUpper)
	function withdrawAllFromLendingProtocol(int24 tickLower, int24 tickUpper) private {
		// TODO
		// Withdraw from lending protocol, deposit into pool
		// Update totalLiquidityState mapping
	}

}
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/console.sol";

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";


import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

contract LiquidityHook is BaseHook, ERC20 {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    error PoolNotInitialized();
    error TickSpacingNotDefault();
    error AddLiquidityThroughHook();

    int24 tickBuffer = 20;

    address lendingProtocolAddress = address(1);

    struct PoolInfo {
        bool hasAccruedFees;
        address liquidityToken;
    }

    struct LiquidityState {
        int24 minTickWithLiqidity;
        int24 maxTickWithLiqidity;
        int24 lastTick;
        uint256 liquidity;
    }

    struct AddLiquidityParams {
        Currency currency0;
        Currency currency1;
        address sender;
        uint256 amount0;
        uint256 amount1;
        int24 tickLower;
        int24 tickUpper;
        PoolKey key;
    }

    mapping(PoolId => PoolInfo) public poolInfo;
    mapping(PoolId => LiquidityState) public liquidityState;

    mapping(int24 tick => mapping(bool inLendingProtocol => uint256 amount)) public
        totalLiquidityState;

    constructor(
        IPoolManager _poolManager, 
        string memory _name,
        string memory _symbol) BaseHook(_poolManager) ERC20(_name, _symbol) {}

    // TODO(tryouge): Change these
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // function beforeInitialize(address, PoolKey calldata key, uint160, bytes calldata)
    //     external
    //     override
    //     returns (bytes4)
    // {
    //     if (key.tickSpacing != 10) revert TickSpacingNotDefault();
    //     PoolId poolId = key.toId();
    //     return this.beforeInitialize.selector;
    // }

    // function afterInitialize(address, PoolKey calldata key, uint160, int24 tick, bytes calldata)
    //     external
    //     override
    //     returns (bytes4)
    // {
    //     // TODO(tryouge): Approve Lending protocol for the right tokens
    //     liquidityState[key.toId()] = LiquidityState((tick - 60), (tick + 60), tick, 0);
    //     return this.afterInitialize.selector;
    // }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert AddLiquidityThroughHook();
    }

    function addLiquidity(AddLiquidityParams calldata params)
        external
    {
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(params.key.toId());
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        
        // Find total liquidity corresponding to the amounts
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(params.tickLower), 
                TickMath.getSqrtPriceAtTick(params.tickUpper),
                params.amount0,
                params.amount1
            );
        
        console.log("\nLiquidity");
        console.logInt(int128(liquidity));
        
        // Finding amounts corresponding to total liquidity
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, TickMath.getSqrtPriceAtTick(params.tickLower), TickMath.getSqrtPriceAtTick(params.tickUpper), liquidity);
        
        console.log("\nAmounts");
        console.logInt(int256(amount0));
        console.logInt(int256(amount1));

        console.log("\nSender Address");
        console.logAddress(msg.sender);
        // Transfer tokens from user to hook contract
        if (amount0 > 0) {
            IERC20(Currency.unwrap(params.key.currency0)).transferFrom(
                params.sender,
                address(this),
                amount0
            );
        }

        if (amount1 > 0) {
            IERC20(Currency.unwrap(params.key.currency1)).transferFrom(
                params.sender,
                address(this),
                amount1
            );
        }
        
        console.log("Transferred Actual Tokens");

        // TODO(tryouge): Currently assumes perfect ticks, can work on handling
        // arbitary ticks
        // int24 totalTicks = _getTotalTicks(params.tickLower, params.tickUpper);
        uint128 totalLendingProtocolLiquidity = 0;
        int24 lendingProtocolTicks = 0;
        uint128 lendingProtocolLiquidity = 0;
        uint256 lpamount0 = 0;
        uint256 lpamount1 = 0;
        

        // Deciding what to deposit into Pool vs Lending Protocol

        // No overlap with current tick buffer
        // Example: current tick buffer = [80, 120] and LP Positition = [60, 70] or [130, 140]
        // LP position has no overlap with current tick buffer range =>
        // deposit all liquidity into Lending Protocol
        if (params.tickLower > currentTick + tickBuffer || params.tickUpper < currentTick - tickBuffer) {
            totalLendingProtocolLiquidity = liquidity;
            addToTotalLiquidityState(totalLendingProtocolLiquidity, params.tickLower, params.tickUpper);
            (lpamount0, lpamount1) = LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, TickMath.getSqrtPriceAtTick(params.tickLower), TickMath.getSqrtPriceAtTick(params.tickUpper), totalLendingProtocolLiquidity);            
            depositIntoLendingProtocol(lpamount0, lpamount1, params.key.currency0, params.key.currency1);
            console.log("Transferred Into Lending Protocol");
        }

        // // Overlap with lower end of current tick buffer
        // if (params.tickLower < currentTick - tickBuffer && params.tickUpper > currentTick - tickBuffer) {
        //     // Example: current tick buffer = [80, 120] and LP Position = [60, 90] or [60, 140]
        //     // deposit [60, 70] into Lending Protocol
        //     // Calculate number of ticks for lending protocol
        //     lendingProtocolTicks = _getTotalTicks(params.tickLower, currentTick - tickBuffer - 1);
        //     // Calculate liquidity to be deposited into lending protocol
        //     lendingProtocolLiquidity = uint128(uint24(lendingProtocolTicks / _getTotalTicks(params.tickLower, params.tickUpper))) * liquidity;
        //     totalLendingProtocolLiquidity += lendingProtocolLiquidity;
        //     addToTotalLiquidityState(totalLendingProtocolLiquidity, params.tickLower, currentTick - tickBuffer - 1);
        //     (lpamount0, lpamount1) = LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, TickMath.getSqrtPriceAtTick(params.tickLower), TickMath.getSqrtPriceAtTick(params.tickUpper), totalLendingProtocolLiquidity);            
        //     depositIntoLendingProtocol(lpamount0, lpamount1, params.key.currency0, params.key.currency1);
        // }

        // // Overlap with upper end of current tick buffer
        // if (params.tickUpper > currentTick + tickBuffer && params.tickLower < currentTick + tickBuffer) {
        //     // Example: current tick buffer = [80, 120] and LP Position = [90, 130] or [60, 130]
        //     // deposit [130] into Lending Protocol
        //     lendingProtocolTicks = _getTotalTicks(currentTick + tickBuffer + 1, params.tickUpper);
        //     lendingProtocolLiquidity = uint128(uint24(lendingProtocolTicks / _getTotalTicks(params.tickLower, params.tickUpper))) * liquidity;
        //     totalLendingProtocolLiquidity += lendingProtocolLiquidity;
        //     addToTotalLiquidityState(totalLendingProtocolLiquidity, currentTick + tickBuffer + 1, params.tickUpper);
        //     (lpamount0, lpamount1) = LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, TickMath.getSqrtPriceAtTick(params.tickLower), TickMath.getSqrtPriceAtTick(params.tickUpper), totalLendingProtocolLiquidity);            
        //     depositIntoLendingProtocol(lpamount0, lpamount1, params.key.currency0, params.key.currency1);
        // }

        // Deposit remaining liquidity into pool
        // liquidity = liquidity - totalLendingProtocolLiquidity;
        // depositIntoPool(liquidity, currentTick - tickBuffer, currentTick + tickBuffer);

        // Mint ERC20 tokens corresponding to liquidity amount to user so they can claim later
        _mint(msg.sender, liquidity);
        console.log("Transferred Liquidity Tokens");
    }

	// TODO(tryouge): Implement this function
    // function beforeRemoveLiquidity(
    //     address sender,
    //     PoolKey calldata key,
    //     IPoolManager.ModifyLiquidityParams calldata params,
    //     bytes calldata hookData
    // ) external override returns (bytes4) {
    //     PoolId poolId = key.toId();
    //     (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(poolId);
    //     if (sqrtPriceX96 == 0) revert PoolNotInitialized();

    //     // Deciding how much has to be removed from Lending Protocol

    //     if (params.tickLower > currentTick + tickBuffer || params.tickUpper < currentTick - tickBuffer) {
    //         // withdrawFromLendingProtocol(params.tickLower, params.tickUpper);
    //     }

    //     return this.beforeRemoveLiquidity.selector;
    // }


    // TODO(tryouge): Implement afterswap
    // function afterSwap(
    //     address sender,
    //     PoolKey calldata key,
    //     IPoolManager.SwapParams calldata params,
    //     BalanceDelta,
    //     bytes calldata
    // ) external override returns (bytes4, int128) {
    //     PoolId poolId = key.toId();
    //     (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(poolId);
    //     int24 lastTick = liquidityState[poolId].lastTick;

    //     // Tick has shifted from lastTick to currentTick (Ex: 100 [80, 120] -> 110 [90, 130])
    //     // Deposit new idle liquidity into lending protocol i.e [80]
    //     // Withdraw liquidity from lending protocol corresponding to [130] and deposit into pool
    //     if (currentTick > lastTick) {
    //         depositIntoLendingProtocol(lastTick - tickBuffer, currentTick - tickBuffer - 1);
    //         withdrawAllFromLendingProtocol(lastTick + tickBuffer + 1, currentTick + tickBuffer + 1);
    //     }
    //     // Tick has shifted from lastTick to currentTick (Ex: 100 [80, 120] -> 92 [72, 112])
    //     // Deposit new idle liquidity into lending protocol i.e [113, 120]
    //     // Withdraw liquidity from lending protocol corresponding to [72, 79] and deposit into pool
    //     else if (currentTick < lastTick) {
    //         depositIntoLendingProtocol(currentTick + tickBuffer + 1, lastTick + tickBuffer);
    //         withdrawAllFromLendingProtocol(currentTick - tickBuffer, lastTick - tickBuffer - 1);
    //     }

    //     // Update lastTick to new currentTick
    //     liquidityState[poolId].lastTick = currentTick;

    //     return (this.afterSwap.selector, 0);
    // }

    function addToTotalLiquidityState(
        uint128 liquidity,
        int24 tickLower,
        int24 tickUpper
    ) private
    {
        // add to totalLiquidityState mapping
        int24 totalTicks = _getTotalTicks(tickLower, tickUpper);
        uint128 eachTickLiquidity = liquidity / uint128(uint24(totalTicks));
        for (int24 tick = tickLower; tick <= tickUpper; tick += 10) {
            if (totalLiquidityState[tick][true] == 0) {totalLiquidityState[tick][true] = eachTickLiquidity;}
            else {totalLiquidityState[tick][true] += eachTickLiquidity;}
        }
    }

    // Function that moves liquidity (tickLower, tickUpper) from pool to lending protocol
    function depositIntoLendingProtocol (
        uint256 amount0,
        uint256 amount1,
        Currency currency0, 
        Currency currency1) private {
        
        
        // Transfer tokens from hook contract to lending protocol
        IERC20(Currency.unwrap(currency0)).transfer(
            lendingProtocolAddress,
            amount0
        );

        IERC20(Currency.unwrap(currency1)).transfer(
            lendingProtocolAddress,
            amount1
        );
    }

    // TODO(gulshan): Function that withdraws liquidityAmount from lending protocol and deposits to pool (tickLower, tickUpper)
    // function withdrawFromLendingProtocol(uint256 liquidityAmount, int24 tickLower, int24 tickUpper) private {
	// 	// Step 1: Withdraw appropriate amount from lending protocol
	// 	// Step 2: update totalLiquidityState mapping

    // }

    // TODO(gulshan): Function that withdraws all liquidity corresponding to tickLower and tickUpper range
    // from lending protocol and deposits to pool (tickLower, tickUpper)
    // function withdrawAllFromLendingProtocol(int24 tickLower, int24 tickUpper) private {
    //     // Step 1: Withdraw from lending protocol, deposit into pool
    //     // Step 2:Update totalLiquidityState mapping
    // }

    function _getTotalTicks(int24 tickLower, int24 tickUpper) internal pure returns (int24 totalTicks) {
        return ((tickUpper - tickLower) / 10) + 1;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {LiquidityHook} from "../src/LiquidityHook.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";

contract TestLiquidityHook is Test, Deployers {
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;

    MockERC20 token0;
    MockERC20 token1;
    Currency currencytoken0;
    Currency currencytoken1;

    LiquidityHook hook;
    address hookAddress;

    function setUp() public {
        deployFreshManagerAndRouters();

        uint160 flags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | 
            Hooks.BEFORE_INITIALIZE_FLAG |
            Hooks.AFTER_INITIALIZE_FLAG |
            Hooks.AFTER_SWAP_FLAG);

        deployCodeTo("LiquidityHook.sol", abi.encode(manager, "Points Token", "TEST_POINTS"), address(flags));

        hook = LiquidityHook(address(flags));

        token0 = new MockERC20("Test Token 0", "TEST0", 18);
        currencytoken0 = Currency.wrap(address(token0));
        token0.mint(address(this), 1000 ether);
        token0.mint(address(hook), 1000 ether);

        token1 = new MockERC20("Test Token 1", "TEST1", 18);
        currencytoken1 = Currency.wrap(address(token1));
        token1.mint(address(this), 1000 ether);
        token1.mint(address(hook), 1000 ether);

        (key,) = initPool(currencytoken0, currencytoken1, hook, 3000, 10, SQRT_PRICE_1_1, ZERO_BYTES);

        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
    }

    function test_addLiquidityOutOfRange() public {
        // Added tick range [60, 100] outside of the current tick buffer [-20, 20]
        // Liquidity generated = 5020289210583797046149
        hook.addLiquidity(
            LiquidityHook.AddLiquidityParams(
                key.currency0,
                key.currency1,
                address(this),
                10 ether,
                10 ether,
                60, // tick lower
                100, // tick upper
                key
            )
        );

        // Added tick range [-100, -60] outside of the current tick buffer [-20, 20]
        // Liquidity generated = 2510144605291898523074
        hook.addLiquidity(
            LiquidityHook.AddLiquidityParams(
                key.currency0,
                key.currency1,
                address(this),
                5 ether,
                5 ether,
                -100, // tick lower
                -60, // tick upper
                key
            )
        );

        // For the tick range to the right of the current tick buffer, all the liquidity
        // would be held as token0 and all of it will go to the lending protocol
        assertApproxEqAbs(token0.balanceOf(address(1)), 10 ether, 0.0001 ether);

        // For the tick range to the left of the current tick buffer, all the liquidity
        // would be held as token1 and all of it will go to the lending protocol
        assertApproxEqAbs(token1.balanceOf(address(1)), 5 ether, 0.0001 ether);

        console.log("Liquidity Balance of User: %d\n", hook.balanceOf(address(this)));
    }

    function test_addLiquidityInRange() public {
        hook.addLiquidity(
            LiquidityHook.AddLiquidityParams(
                key.currency0,
                key.currency1,
                address(this),
                10 ether,
                10 ether,
                -40, // tick lower
                50, // tick upper
                key
            )
        );

        // 5 Inactive ticks i.e [-40, -30, 30, 40, 50]
        // 5 active ticks i.e [-20, -10, 0, 10, 20]
        // Overall Liquidity Position requires 10 eth token 0 and 8 eth token 1
        // Hence, should be split evenly between pool and lending protocol
        
        
        assertApproxEqAbs(token0.balanceOf(address(1)), 5 ether, 0.01 ether);
        assertApproxEqAbs(token1.balanceOf(address(1)), 4 ether, 0.01 ether);

        uint token0ClaimID = CurrencyLibrary.toId(key.currency0);
        uint token1ClaimID = CurrencyLibrary.toId(key.currency1);

        uint token0ClaimsBalance = manager.balanceOf(
            address(hook),
            token0ClaimID
        );

        console.log(token0ClaimsBalance);
        uint token1ClaimsBalance = manager.balanceOf(
            address(hook),
            token1ClaimID
        );

        assertApproxEqAbs(token0ClaimsBalance, 5 ether, 0.01 ether);
        assertApproxEqAbs(token1ClaimsBalance, 4 ether, 0.01 ether);
    }

    function test_addAndRemoveLiquidityInRange() public {
        hook.addLiquidity(
            LiquidityHook.AddLiquidityParams(
                key.currency0,
                key.currency1,
                address(this),
                10 ether,
                10 ether,
                -10, // tick lower
                10, // tick upper
                key
            )
        );

        // 0 Inactive ticks i.e [-40, -30, 30, 40, 50]
        // 3 active ticks i.e [-10, 0, 10]
        // All liquidity should go to Pool
        
        
        assertApproxEqAbs(token0.balanceOf(address(1)), 0 ether, 0.01 ether);
        assertApproxEqAbs(token1.balanceOf(address(1)), 0 ether, 0.01 ether);


        uint token0ClaimID = CurrencyLibrary.toId(key.currency0);
        uint token1ClaimID = CurrencyLibrary.toId(key.currency1);

        uint token0ClaimsBalance = manager.balanceOf(
            address(hook),
            token0ClaimID
        );

        uint token1ClaimsBalance = manager.balanceOf(
            address(hook),
            token1ClaimID
        );

        // All liquidity deposited into active tick range => All of it is in pool
        assertApproxEqAbs(token0ClaimsBalance, 10 ether, 0.01 ether);
        assertApproxEqAbs(token1ClaimsBalance, 10 ether, 0.01 ether);

        uint256 token0BalanceBefore = token0.balanceOf(address(this));
        uint256 token1BalanceBefore = token1.balanceOf(address(this));


        hook.removeLiquidity(
            LiquidityHook.RemoveLiquidityParams(
                key.currency0,
                key.currency1,
                address(this),
                uint128(20006000399979999600159),
                -10, // tick lower
                10, // tick upper
                key
            )
        );

        uint256 token0BalanceAfter = token0.balanceOf(address(this));
        uint256 token1BalanceAfter = token1.balanceOf(address(this));


        assertApproxEqAbs(token0BalanceAfter-token0BalanceBefore, 10 ether, 0.01 ether);
        assertApproxEqAbs(token1BalanceAfter-token1BalanceBefore, 10 ether, 0.01 ether);
            
    }
}

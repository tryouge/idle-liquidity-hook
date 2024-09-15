// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;


import "forge-std/console.sol";

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
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";

contract TestLiquidityHook is Test, Deployers {
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;

    LiquidityHook hook;
    address hookAddress;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        hookAddress = address(
            uint160(
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                    Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                // Hooks.BEFORE_SWAP_FLAG |
                // Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            )
        );
        deployCodeTo(
            "LiquidityHook.sol:LiquidityHook",
            abi.encode(manager),
            hookAddress
        );
        hook = LiquidityHook(hookAddress);

        (key, ) = initPool(
            currency0,
            currency1,
            hook,
            3000,
            SQRT_PRICE_1_1,
            ZERO_BYTES
        );

        // Add some initial liquidity through the custom `addLiquidity` function
        IERC20Minimal(Currency.unwrap(key.currency0)).approve(
            hookAddress,
            1000 ether
        );
        IERC20Minimal(Currency.unwrap(key.currency1)).approve(
            hookAddress,
            1000 ether
        );

        hook.addLiquidity(key, 1e18);

        // hook.removeLiquidity(key, 300000000000000000);

    }

    function test_claimTokenBalances() public  {
        uint token0ClaimID = CurrencyLibrary.toId(currency0);
        uint token1ClaimID = CurrencyLibrary.toId(currency1);

        uint token0ClaimsBalance = manager.balanceOf(
            address(hook),
            token0ClaimID
        );
        uint token1ClaimsBalance = manager.balanceOf(
            address(hook),
            token1ClaimID
        );

        assertEq(token0ClaimsBalance, 5e17);
        assertEq(token1ClaimsBalance, 5e17);

        uint256 balanceOfHookAddress = IERC20Minimal(
            Currency.unwrap(key.currency1)
        ).balanceOf(hookAddress);

        assertEq(balanceOfHookAddress, 497009131119745168);

        hook.removeLiquidity(key, 200000000000000000);

        balanceOfHookAddress = IERC20Minimal(
            Currency.unwrap(key.currency1)
        ).balanceOf(hookAddress);

        console.log(balanceOfHookAddress);
        assertEq(balanceOfHookAddress, 498205478671847100);
    }
}

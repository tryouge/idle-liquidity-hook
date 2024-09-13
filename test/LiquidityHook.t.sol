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
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";

contract TestLiquidityHook is Test, Deployers {
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;

    LiquidityHook hook;
    address hookAddress;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

		uint160 flags = uint160(
        	Hooks.BEFORE_ADD_LIQUIDITY_FLAG
    	);

        hookAddress = address(
            uint160(
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG 
            )
        );

		deployCodeTo(
			"LiquidityHook.sol",
			abi.encode(manager, "Points Token", "TEST_POINTS"),
			address(flags)
   		);
        
        hook = LiquidityHook(address(flags));

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
            type(uint256).max
        );
        IERC20Minimal(Currency.unwrap(key.currency1)).approve(
            hookAddress,
            type(uint256).max
        );

        // hook.addLiquidity(key, 1e18);
    }

    function test_addLiquidityOutOfRange() public {

		hook.addLiquidity(
			LiquidityHook.AddLiquidityParams(
				key.currency0,
				key.currency1,
				10 ether,
				10 ether,
				10, // tick lower
				40, // tick upper
				key
			)
		);
    }
}
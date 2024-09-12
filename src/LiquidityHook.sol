// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/console.sol";

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

// import {UniswapV4ERC20} from "v4-periphery/libraries/UniswapV4ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

contract LiquidityHook is BaseHook {
    using StateLibrary for IPoolManager;
    // using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;

    using PoolIdLibrary for PoolKey;

    error PoolNotInitialized();
    error TickSpacingNotDefault();
    error AddLiquidityThroughHook();

    int24 tickBuffer = 20;

    /// @dev Min tick for full range with tick spacing of 60
    int24 internal constant MIN_TICK = -887220;
    /// @dev Max tick for full range with tick spacing of 60
    int24 internal constant MAX_TICK = -MIN_TICK;

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

    struct CallbackData {
        uint256 amountEach;
        Currency currency0;
        Currency currency1;
        address sender;
        PoolKey key;
    }

    struct ModifyLiquidityCallbackData {
        address sender;
        PoolKey key;
        IPoolManager.ModifyLiquidityParams params;
    }

    mapping(PoolId => PoolInfo) public poolInfo;
    mapping(PoolId => LiquidityState) public liquidityState;
    bytes internal constant ZERO_BYTES = bytes("");

    mapping(PoolId poolId => mapping(int24 tick => mapping(bool inLendingProtocol => uint256 amount)))
        public totalLiquidityState;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
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

    function beforeInitialize(
        address,
        PoolKey calldata key,
        uint160,
        bytes calldata
    ) external override returns (bytes4) {
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
        liquidityState[key.toId()] = LiquidityState(
            (tick - 60),
            (tick + 60),
            tick,
            0
        );
        return this.afterInitialize.selector;
    }

    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4) {
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96, int24 currentTick, , ) = poolManager.getSlot0(
            poolId
        );
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        // Deciding how much has to be removed from Lending Protocol

        if (
            params.tickLower > currentTick + tickBuffer ||
            params.tickUpper < currentTick - tickBuffer
        ) {
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
        (uint160 sqrtPriceX96, int24 currentTick, , ) = poolManager.getSlot0(
            poolId
        );
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        // Deciding what ticks to deposit into Lending Protocol

        // If LP position tickLower > currentTick + tickBuffer
        // (or) tickUpper < currentTick - tickBuffer
        // Example: current tick buffer = [80, 120] and LP Positition = [60, 70] or [125, 130]
        // LP position has no overlap with current tick buffer range =>
        // deposit all of LP position into Lending Protocol
        if (
            params.tickLower > currentTick + tickBuffer ||
            params.tickUpper < currentTick - tickBuffer
        ) {
            depositIntoLendingProtocol(params.tickLower, params.tickUpper);
        }
        // Lower end overlap case
        else if (
            params.tickLower < currentTick - tickBuffer &&
            params.tickUpper > currentTick - tickBuffer
        ) {
            // Example: current tick buffer = [80, 120] and LP Position = [60, 90]
            // deposit [60, 79] into Lending Protocol
            depositIntoLendingProtocol(
                params.tickLower,
                currentTick - tickBuffer - 1
            );
            if (params.tickUpper > currentTick + tickBuffer) {
                // Example: current tick buffer = [80, 120] and LP Position = [60, 130]
                // Also deposit the extra [121, 130] into Lending Protocol
                depositIntoLendingProtocol(
                    currentTick + tickBuffer + 1,
                    params.tickUpper
                );
            }
        }
        // Upper end overlap case
        else if (
            params.tickUpper > currentTick + tickBuffer &&
            params.tickLower < currentTick + tickBuffer
        ) {
            // Example: current tick buffer = [80, 120] and LP Position = [90, 130]
            // deposit [121, 130] into Lending Protocol
            depositIntoLendingProtocol(
                currentTick + tickBuffer + 1,
                params.tickUpper
            );
            if (params.tickUpper > currentTick + tickBuffer) {
                // Example: current tick buffer = [80, 120] and LP Position = [60, 130]
                // Also deposit the extra [60, 79] into Lending Protocol
                depositIntoLendingProtocol(
                    params.tickLower,
                    currentTick - tickBuffer - 1
                );
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
        (uint160 sqrtPriceX96, int24 currentTick, , ) = poolManager.getSlot0(
            poolId
        );
        int24 lastTick = liquidityState[poolId].lastTick;

        // Tick has shifted from lastTick to currentTick (Ex: 100 [80, 120] -> 110 [90, 130])
        // Deposit new idle liquidity into lending protocol i.e [80, 89]
        // Withdraw liquidity from lending protocol corresponding to [121, 130] and deposit into pool
        if (currentTick > lastTick) {
            depositIntoLendingProtocol(
                lastTick - tickBuffer,
                currentTick - tickBuffer - 1
            );
            withdrawAllFromLendingProtocol(
                lastTick + tickBuffer + 1,
                currentTick + tickBuffer + 1
            );
        }
        // Tick has shifted from lastTick to currentTick (Ex: 100 [80, 120] -> 92 [72, 112])
        // Deposit new idle liquidity into lending protocol i.e [113, 120]
        // Withdraw liquidity from lending protocol corresponding to [72, 79] and deposit into pool
        else if (currentTick < lastTick) {
            depositIntoLendingProtocol(
                currentTick + tickBuffer + 1,
                lastTick + tickBuffer
            );
            withdrawAllFromLendingProtocol(
                currentTick - tickBuffer,
                lastTick - tickBuffer - 1
            );
        }

        // Update lastTick to new currentTick
        liquidityState[poolId].lastTick = currentTick;

        return (this.afterSwap.selector, 0);
    }

    // Function that moves liquidity (tickLower, tickUpper) from pool to lending protocol
    function depositIntoLendingProtocol(
        int24 tickLower,
        int24 tickUpper
    ) private {
        // TODO
        // Move into lending protocol
        // Update totalLiquidityState mapping
    }

    // Function that withdraws liquidityAmount from lending protocol and deposits to pool (tickLower, tickUpper)
    function withdrawFromLendingProtocol(
        uint256 liquidityAmount,
        int24 tickLower,
        int24 tickUpper
    ) private {
        // TODO
        // Withdraw from lending protocol, deposit into pool
        // Update totalLiquidityState mapping
    }

    // Function that withdraws all liquidity corresponding to tickLower and tickUpper range
    // from lending protocol and deposits to pool (tickLower, tickUpper)
    function withdrawAllFromLendingProtocol(
        int24 tickLower,
        int24 tickUpper
    ) private {
        // TODO
        // Withdraw from lending protocol, deposit into pool
        // Update totalLiquidityState mapping
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert AddLiquidityThroughHook();
    }

    function addLiquidity(PoolKey calldata key, uint256 amountEach) external {
        poolManager.unlock(
            abi.encode(
                CallbackData(
                    amountEach,
                    key.currency0,
                    key.currency1,
                    msg.sender,
                    key
                )
            )
        );
    }

    function _unlockCallback(
        bytes calldata data
    ) internal override returns (bytes memory) {
        CallbackData memory callbackData = abi.decode(data, (CallbackData));


        // user to hook contract
        IERC20(Currency.unwrap(callbackData.key.currency0)).transferFrom(
            callbackData.sender,
            address(this),
            callbackData.amountEach
        );

        IERC20(Currency.unwrap(callbackData.key.currency1)).transferFrom(
            callbackData.sender,
            address(this),
            callbackData.amountEach
        );

        // hook to pool manager
        callbackData.currency0.settle(
            poolManager,
            address(this),
            callbackData.amountEach - amountToKeepInHook,
            false // `burn` = `false` i.e. we're actually transferring tokens, not burning ERC-6909 Claim Tokens
        );

        callbackData.currency1.settle(
            poolManager,
            address(this),
            callbackData.amountEach - amountToKeepInHook,
            false
        );

        // as modify liquidity is done by us, we need to mint claim tokens from pool manager to hook
        callbackData.currency0.take(
            poolManager,
            address(this),
            callbackData.amountEach - amountToKeepInHook,
            true // true = mint claim tokens for the hook, equivalent to money we just deposited to the PM
        );
        callbackData.currency1.take(
            poolManager,
            address(this),
            callbackData.amountEach - amountToKeepInHook,
            true
        );

        (BalanceDelta balanceDelta, ) = poolManager.modifyLiquidity(
            callbackData.key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: int256(
                    callbackData.amountEach - amountToKeepInHook
                ),
                salt: 0
            }),
            ZERO_BYTES
        );

        int128 amount0 = balanceDelta.amount0();

        console.logInt(amount0);

        int128 amount1 = balanceDelta.amount1();

        console.logInt(amount1);
        // console.logInt(int128(balanceDelta.amount0));
        // console.logI

        // give to pool manager
        callbackData.key.currency0.settle(
            poolManager,
            address(this),
            uint256(int256(-balanceDelta.amount0())),
            false
        );

        callbackData.key.currency1.settle(
            poolManager,
            address(this),
            uint256(int256(-balanceDelta.amount1())),
            false
        );

        return "";
    }

    // TODO: remove this
    uint256 amountToKeepInHook = 500000000000000000; // 0.5 eth

    // function _unlockCallback(
    //     bytes calldata data
    // ) internal override returns (bytes memory) {
    //     CallbackData memory callbackData = abi.decode(data, (CallbackData));

    //     // Settle `amountEach` of each currency from the sender
    //     // i.e. Create a debit of `amountEach` of each currency with the Pool Manager
    //     callbackData.currency0.settle(
    //         poolManager,
    //         callbackData.sender,
    //         callbackData.amountEach,
    //         false // `burn` = `false` i.e. we're actually transferring tokens, not burning ERC-6909 Claim Tokens
    //     );
    //     callbackData.currency1.settle(
    //         poolManager,
    //         callbackData.sender,
    //         callbackData.amountEach,
    //         false
    //     );

    //     // Since we didn't go through the regular "modify liquidity" flow,
    //     // the PM just has a debit of `amountEach` of each currency from us
    //     // We can, in exchange, get back ERC-6909 claim tokens for `amountEach` of each currency
    //     // to create a credit of `amountEach` of each currency to us
    //     // that balances out the debit

    //     // We will store those claim tokens with the hook, so when swaps take place
    //     // liquidity from our CSMM can be used by minting/burning claim tokens the hook owns
    //     callbackData.currency0.take(
    //         poolManager,
    //         address(this),
    //         callbackData.amountEach,
    //         true // true = mint claim tokens for the hook, equivalent to money we just deposited to the PM
    //     );
    //     callbackData.currency1.take(
    //         poolManager,
    //         address(this),
    //         callbackData.amountEach,
    //         true
    //     );

    //     // BalanceDelta addedDelta = modifyLiquidity(
    //     //     callbackData.key,
    //     //     IPoolManager.ModifyLiquidityParams({
    //     //         // Add liquidity to current optimal range
    //     //         tickLower: 100,
    //     //         tickUpper: 120,
    //     //         liquidityDelta: int256(callbackData.amountEach), // TODO: is it needed ??
    //     //         salt: 0
    //     //     })
    //     // );

    //     (BalanceDelta balanceDelta,) = poolManager.modifyLiquidity(
    //         callbackData.key,
    //         IPoolManager.ModifyLiquidityParams({
    //             tickLower: -120,
    //             tickUpper: 120,
    //             liquidityDelta: int256(callbackData.amountEach - amountToKeepInHook),
    //             salt: 0
    //         }),
    //         ZERO_BYTES
    //     );

    //     // give to pool manager
    //     callbackData.key.currency0.settle(poolManager, callbackData.sender, uint256(int256(-balanceDelta.amount0())), false);
    //     callbackData.key.currency1.settle(poolManager, callbackData.sender, uint256(int256(-balanceDelta.amount1())), false);

    //     // callbackData.currency0.take(
    //     //     poolManager,
    //     //     address(this),
    //     //     callbackData.amountEach,
    //     //     true // true = mint claim tokens for the hook, equivalent to money we just deposited to the PM
    //     // );
    //     // callbackData.currency1.take(
    //     //     poolManager,
    //     //     address(this),
    //     //     callbackData.amountEach,
    //     //     true
    //     // );

    //     // callbackData.key.currency0.transfer( address(this), amountToKeepInHook);
    //     // callbackData.key.currency0.transfer( address(this), amountToKeepInHook);

    //     // callbackData.currency0.take(
    //     //     poolManager,
    //     //     address(this),
    //     //     amountToKeepInHook,
    //     //     false // true = mint claim tokens for the hook, equivalent to money we just deposited to the PM
    //     // );

    //     // poolManager.take(callbackData.key.currency0, address(this), amountToKeepInHook);
    //     // poolManager.take(callbackData.key.currency1, address(this), amountToKeepInHook);

    //     // poolManager.settle();
    //     // poolManager.settle(callbackData.key.currency1, address(this), amountToKeepInHook);

    //     return "";
    // }

    //  function modifyLiquidity(PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params)
    //     internal
    //     returns (BalanceDelta delta)
    // {
    //     delta = abi.decode(poolManager.unlock(abi.encode(ModifyLiquidityCallbackData(msg.sender, key, params))), (BalanceDelta));
    // }
}

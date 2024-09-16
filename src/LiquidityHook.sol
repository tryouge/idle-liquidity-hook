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
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
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
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;

    error PoolNotInitialized();
    error TickSpacingNotDefault();
    error AddLiquidityThroughHook();
    error NotEnoughLiquidityTokens();

    int24 tickBuffer = 20;

    address lendingProtocolAddress = address(1);

    uint256 token0AmountLendingProtocol = 0;
    uint256 token1AmountLendingProtocol = 0;
    uint128 overallLiquidityLendingProtocol = 0;

    uint256 token0AmountPool = 0;
    uint256 token1AmountPool = 0;
    uint128 overallLiquidityPool = 0;

    struct PoolInfo {
        bool hasAccruedFees;
        address liquidityToken;
    }

    struct LiquidityState {
        int24 lastTick;
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

    struct CallbackData {
        uint128 liquidity;
        Currency currency0;
        Currency currency1;
        address sender;
        PoolKey key;
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        uint8 methodCall;
    }

    struct RemoveLiquidityParams {
        Currency currency0;
        Currency currency1;
        address sender;
        uint128 liquidity;
        int24 tickLower;
        int24 tickUpper;
        PoolKey key;
    }

    mapping(PoolId => PoolInfo) public poolInfo;
    mapping(PoolId => LiquidityState) public liquidityState;
    bytes internal constant ZERO_BYTES = bytes("");

    mapping(int24 tick => mapping(bool inLendingProtocol => uint128 liquidity)) public totalLiquidityState;

    constructor(
        IPoolManager _poolManager,
        string memory _name,
        // Currently only one flat ERC20 assuming 1 pool only
        string memory _symbol
    ) BaseHook(_poolManager) ERC20(_name, _symbol) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
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
        if (key.tickSpacing != 10) revert TickSpacingNotDefault();
        return this.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick, bytes calldata)
        external
        override
        returns (bytes4)
    {
        liquidityState[key.toId()] = LiquidityState(tick);
        return this.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert AddLiquidityThroughHook();
    }
    
    function addLiquidity(AddLiquidityParams calldata params) external {
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

        console.log("\nOverall Liquidity: %d", liquidity);

        // Finding amounts corresponding to total liquidity
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(params.tickLower),
            TickMath.getSqrtPriceAtTick(params.tickUpper),
            liquidity
        );

        console.log("\nOverall Amounts - Amount0: %d \t Amount1: %d", amount0, amount1);
        console.log("\nSender Address: %s", msg.sender);

        // Transfer tokens from user to hook contract
        if (amount0 > 0) {
            IERC20(Currency.unwrap(params.key.currency0)).transferFrom(params.sender, address(this), amount0);
        }

        if (amount1 > 0) {
            IERC20(Currency.unwrap(params.key.currency1)).transferFrom(params.sender, address(this), amount1);
        }

        console.log("\nTransferred Actual Tokens");

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
            addToTotalLiquidityStateLendingProtocol(totalLendingProtocolLiquidity, params.tickLower, params.tickUpper);
            depositIntoLendingProtocol(amount0, amount1, params.key.currency0, params.key.currency1);
            console.log("Transferring whole Into Lending Protocol\n");
        }





        // Overlap with lower end of current tick buffer
        if (params.tickLower < currentTick - tickBuffer && params.tickUpper > currentTick - tickBuffer) {
            // Example: current tick buffer = [80, 120] and LP Position = [60, 90] or [60, 140]
            // deposit [60, 70] into Lending Protocol
            // Calculate number of ticks for lending protocol
            console.log("\nTransferring partial to Lending Protocol (Lower)");
            lendingProtocolTicks = _getTotalTicks(params.tickLower, currentTick - tickBuffer - 1);
            // Calculate liquidity to be deposited into lending protocol
            lendingProtocolLiquidity = uint128(
                uint24((lendingProtocolTicks * 1000) / _getTotalTicks(params.tickLower, params.tickUpper))
            ) * (liquidity / 1000);
            // Update Liquidity State mapping
            addToTotalLiquidityStateLendingProtocol(lendingProtocolLiquidity, params.tickLower, currentTick - tickBuffer - 1);
            // Calculate amount to be deposited into lending protocol
            (lpamount0, lpamount1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(params.tickLower),
                TickMath.getSqrtPriceAtTick(params.tickUpper),
                lendingProtocolLiquidity
            );
            

            totalLendingProtocolLiquidity += lendingProtocolLiquidity;
            console.log(
                "Lending Protocol Liquidity (Lower): %d \t Amount0: %d \t Amount1: %d",
                lendingProtocolLiquidity,
                lpamount0,
                lpamount1
            );
            console.log("Overall Lending Protocol Liquidity: %d", totalLendingProtocolLiquidity);
            depositIntoLendingProtocol(lpamount0, lpamount1, params.key.currency0, params.key.currency1);
        }

        // Overlap with upper end of current tick buffer
        if (params.tickUpper > currentTick + tickBuffer && params.tickLower < currentTick + tickBuffer) {
            // Example: current tick buffer = [80, 120] and LP Position = [90, 130] or [60, 130]
            // deposit [130] into Lending Protocol
            console.log("\nTransferring partial to Lending Protocol (Upper)");
            lendingProtocolTicks = _getTotalTicks(currentTick + tickBuffer + 1, params.tickUpper);
            lendingProtocolLiquidity = uint128(
                uint24((lendingProtocolTicks * 1000) / _getTotalTicks(params.tickLower, params.tickUpper))
            ) * (liquidity / 1000);
            addToTotalLiquidityStateLendingProtocol(lendingProtocolLiquidity, currentTick + tickBuffer + 1, params.tickUpper);
            (lpamount0, lpamount1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(params.tickLower),
                TickMath.getSqrtPriceAtTick(params.tickUpper),
                lendingProtocolLiquidity
            );
            totalLendingProtocolLiquidity += lendingProtocolLiquidity;
            console.log(
                "Lending Protocol Liquidity (Lower): %d \t Amount0: %d \t Amount1: %d",
                lendingProtocolLiquidity,
                lpamount0,
                lpamount1
            );
            console.log("Overall Lending Protocol Liquidity: %d", totalLendingProtocolLiquidity);
            depositIntoLendingProtocol(lpamount0, lpamount1, params.key.currency0, params.key.currency1);
        }

        liquidity = liquidity - totalLendingProtocolLiquidity;
        // depositIntoPool(liquidity, currentTick - tickBuffer, currentTick + tickBuffer);
        // reference: LiquidityAmounts.getAmountsForLiquidity(liquidity)

        // Deposit rest into pool
        if (liquidity > 0) {
            poolManager.unlock(
                abi.encode(
                    CallbackData(
                        liquidity,
                        params.key.currency0,
                        params.key.currency1,
                        msg.sender,
                        params.key,
                        sqrtPriceX96,
                        params.tickLower,
                        params.tickUpper,
                        1
                    )
                )
            );
        }

        // Mint ERC20 tokens corresponding to liquidity amount to user so they can claim later
        _mint(msg.sender, liquidity);
        console.log("\nTransferred Liquidity Tokens");
    }

    function _unlockCallback(
        bytes calldata data
    ) internal override returns (bytes memory) {
        CallbackData memory callbackData = abi.decode(data, (CallbackData));
        // Deposit into Pool
        if (callbackData.methodCall == 1) {
            uint128 liquidityLeft = callbackData.liquidity;
            (
                uint256 amount0AfterLendingPool,
                uint256 amount1AfterLendingPool
            ) = LiquidityAmounts.getAmountsForLiquidity(
                    callbackData.sqrtPriceX96,
                    TickMath.getSqrtPriceAtTick(callbackData.tickLower),
                    TickMath.getSqrtPriceAtTick(callbackData.tickUpper),
                    liquidityLeft
                );
            console.log("\nPool Liquidity: %d, Pool Amount0: %d, Pool Amount1: %d", callbackData.liquidity, amount0AfterLendingPool, amount1AfterLendingPool);
            // console.log("amount0AfterLendingPool ", amount0AfterLendingPool);
            // console.log("amount1AfterLendingPool ", amount1AfterLendingPool);
            // console.log("params final liquidity left ", callbackData.liquidity);
            callbackData.currency0.settle(
                poolManager,
                address(this),
                amount0AfterLendingPool,
                false
            );

            callbackData.currency1.settle(
                poolManager,
                address(this),
                amount1AfterLendingPool,
                false
            );

            callbackData.currency0.take(
                poolManager,
                address(this),
                amount0AfterLendingPool,
                true // true = mint claim tokens for the hook, equivalent to money we just deposited to the PM
            );

            callbackData.currency1.take(
                poolManager,
                address(this),
                amount1AfterLendingPool,
                true // true = mint claim tokens for the hook, equivalent to money we just deposited to the PM
            );

            (BalanceDelta balanceDelta, ) = poolManager.modifyLiquidity(
                callbackData.key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: callbackData.tickLower,
                    tickUpper: callbackData.tickUpper,
                    liquidityDelta: int256(
                        uint256(liquidityLeft)
                    ), 
                    salt: 0 
                }),
                bytes("")
            );

            int128 amount0 = balanceDelta.amount0();

            // console.logInt(amount0);

            int128 amount1 = balanceDelta.amount1();

            // console.logInt(amount1);

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
        }
        // Withdraw from Pool
        else {
            (uint256 amount0, uint256 amount1) = LiquidityAmounts
                .getAmountsForLiquidity(
                    callbackData.sqrtPriceX96,
                    TickMath.getSqrtPriceAtTick(callbackData.tickLower),
                    TickMath.getSqrtPriceAtTick(callbackData.tickUpper),
                    uint128(callbackData.liquidity)
                );

            (BalanceDelta balanceDelta, ) = poolManager.modifyLiquidity(
                callbackData.key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: callbackData.tickLower,
                    tickUpper: callbackData.tickUpper,
                    liquidityDelta: -int256(uint256(callbackData.liquidity)),
                    salt: 0
                }),
                ZERO_BYTES
            );

            console.log(balanceDelta.amount0());
            console.log(balanceDelta.amount1());
            callbackData.currency0.take(
                poolManager,
                address(this),
                uint256(uint128(balanceDelta.amount0())),
                false // true = mint claim tokens for the hook, equivalent to money we just deposited to the PM
            );

            callbackData.currency1.take(
                poolManager,
                address(this),
                uint256(uint128(balanceDelta.amount1())),
                false
            );

        }
    }

    function removeLiquidity(RemoveLiquidityParams calldata params) external {
        // Burn tokens
        if (balanceOf(params.sender) < params.liquidity) revert NotEnoughLiquidityTokens();

        _burn(msg.sender, params.liquidity);

        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(params.key.toId());

        uint128 totalLendingProtocolLiquidity = 0;
        int24 lendingProtocolTicks = 0;
        uint128 lendingProtocolLiquidity = 0;
        uint256 lpamount0 = 0;
        uint256 lpamount1 = 0;

        // Figure out amounts corresponding to liquidity
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(params.tickLower),
            TickMath.getSqrtPriceAtTick(params.tickUpper),
            params.liquidity
        );

        // Deciding what to withdraw from Pool vs Lending Protocol
        // No overlap with current tick buffer
        // Example: current tick buffer = [80, 120] and LP Positition = [60, 70] or [130, 140]
        // LP position has no overlap with current tick buffer range =>
        // withdraw all liquidity from Lending Protocol
        if (params.tickLower > currentTick + tickBuffer || params.tickUpper < currentTick - tickBuffer) {
            totalLendingProtocolLiquidity = params.liquidity;
            removeFromTotalLiquidityStateLendingProtocol(totalLendingProtocolLiquidity, params.tickLower, params.tickUpper);
            console.log("Amounts to Withdraw: %d \t %d",amount0, amount1);
            withdrawFromLendingProtocol(amount0, amount1, params.key.currency0, params.key.currency1);
            // IERC20(Currency.unwrap(params.key.currency0)).transfer(params.sender, amount0);
            // IERC20(Currency.unwrap(params.key.currency1)).transfer(params.sender, amount1);
            console.log("Withdrawing whole from Lending Protocol\n");
        }

        // Overlap with lower end of current tick buffer
        if (params.tickLower < currentTick - tickBuffer && params.tickUpper > currentTick - tickBuffer) {
            // Example: current tick buffer = [80, 120] and LP Position = [60, 90] or [60, 140]
            // withdraw [60, 70] from Lending Protocol
            // Calculate number of ticks for lending protocol
            console.log("\nTransferring partial to Lending Protocol (Lower)");
            lendingProtocolTicks = _getTotalTicks(params.tickLower, currentTick - tickBuffer - 1);
            // Calculate liquidity to be deposited into lending protocol
            lendingProtocolLiquidity = uint128(
                uint24((lendingProtocolTicks * 1000) / _getTotalTicks(params.tickLower, params.tickUpper))
            ) * (params.liquidity / 1000);
            // Update Liquidity State mapping
            removeFromTotalLiquidityStateLendingProtocol(lendingProtocolLiquidity, params.tickLower, currentTick - tickBuffer - 1);
            // Calculate amount to be withdrawn from lending protocol
            (lpamount0, lpamount1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(params.tickLower),
                TickMath.getSqrtPriceAtTick(params.tickUpper),
                lendingProtocolLiquidity
            );
            totalLendingProtocolLiquidity += lendingProtocolLiquidity;
            console.log(
                "Lending Protocol Liquidity (Lower): %d \t Amount0: %d \t Amount1: %d",
                lendingProtocolLiquidity,
                lpamount0,
                lpamount1
            );
            console.log("Total Lending Protocol Liquidity: %d", totalLendingProtocolLiquidity);
            withdrawFromLendingProtocol(lpamount0, lpamount1, params.key.currency0, params.key.currency1);
            IERC20(Currency.unwrap(params.key.currency0)).transfer(params.sender, lpamount0);
            IERC20(Currency.unwrap(params.key.currency1)).transfer(params.sender, lpamount1);
        }

        // Overlap with upper end of current tick buffer
        if (params.tickUpper > currentTick + tickBuffer && params.tickLower < currentTick + tickBuffer) {
            // Example: current tick buffer = [80, 120] and LP Position = [90, 130] or [60, 130]
            // deposit [130] into Lending Protocol
            console.log("\nTransferring partial to Lending Protocol (Lower)");
            lendingProtocolTicks = _getTotalTicks(currentTick + tickBuffer + 1, params.tickUpper);
            lendingProtocolLiquidity = uint128(
                uint24((lendingProtocolTicks * 1000) / _getTotalTicks(params.tickLower, params.tickUpper))
            ) * (params.liquidity / 1000);
            removeFromTotalLiquidityStateLendingProtocol(lendingProtocolLiquidity, currentTick + tickBuffer + 1, params.tickUpper);
            (lpamount0, lpamount1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(params.tickLower),
                TickMath.getSqrtPriceAtTick(params.tickUpper),
                lendingProtocolLiquidity
            );
            totalLendingProtocolLiquidity += lendingProtocolLiquidity;
            console.log(
                "Lending Protocol Liquidity (Lower): %d \t Amount0: %d \t Amount1: %d",
                lendingProtocolLiquidity,
                lpamount0,
                lpamount1
            );
            console.log("Overall Lending Protocol Liquidity: %d", totalLendingProtocolLiquidity);
            withdrawFromLendingProtocol(lpamount0, lpamount1, params.key.currency0, params.key.currency1);
            IERC20(Currency.unwrap(params.key.currency0)).transfer(params.sender, lpamount0);
            IERC20(Currency.unwrap(params.key.currency1)).transfer(params.sender, lpamount1);
        }

        // Withdraw rest from pool
        poolManager.unlock(
            abi.encode(
                CallbackData(
                    params.liquidity-totalLendingProtocolLiquidity,
                    params.key.currency0,
                    params.key.currency1,
                    msg.sender,
                    params.key,
                    sqrtPriceX96,
                    params.tickLower,
                    params.tickUpper,
                    2
                )
            )
        );
        
        (lpamount0, lpamount1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(params.tickLower),
                TickMath.getSqrtPriceAtTick(params.tickUpper),
                params.liquidity-totalLendingProtocolLiquidity
            );
        // console.log("Amounts to Withdraw: %d \t %d", lpamount0, lpamount1);
        IERC20(Currency.unwrap(params.key.currency0)).transfer(params.sender, lpamount0);
        IERC20(Currency.unwrap(params.key.currency1)).transfer(params.sender, lpamount1);
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

        // Tick cannot shift to a new tick beyond the last known tick's buffer since there is no liquidity outside
        // i.e cannot have tick shifts like 100 [80, 120] --> 130, it can only move between 80 and 120

        // Tick has shifted from lastTick to currentTick (Ex: 100 [80, 120] -> 110 [90, 130])
        // Deposit new idle liquidity into lending protocol i.e [80] (80 to 89)
        // Withdraw liquidity from lending protocol corresponding to [130] (121 to 130) and deposit into pool
        if (currentTick > lastTick) {
            moveAllFromPoolToLendingProtocol(
                key, key.currency0, key.currency1, sqrtPriceX96, lastTick - tickBuffer, currentTick - tickBuffer - 1
            );
            moveAllFromLendingProtocolToPool(
                key, key.currency0, key.currency1, sqrtPriceX96, lastTick + tickBuffer + 1, currentTick + tickBuffer
            );
        }
        // Tick has shifted from lastTick to currentTick (Ex: 100 [80, 120] -> 90 [70, 110])
        // Deposit new idle liquidity into lending protocol i.e [120] (111 to 120)
        // Withdraw liquidity from lending protocol corresponding to [70] (70 to 79) and deposit into pool
        else if (currentTick < lastTick) {
            moveAllFromPoolToLendingProtocol(
                key, key.currency0, key.currency1, sqrtPriceX96, currentTick + tickBuffer + 1, lastTick + tickBuffer
            );
            moveAllFromLendingProtocolToPool(
                key, key.currency0, key.currency1, sqrtPriceX96, currentTick - tickBuffer, lastTick - tickBuffer - 1
            );
        }

        // Update lastTick to new currentTick
        liquidityState[poolId].lastTick = currentTick;
        return (this.afterSwap.selector, 0);
    }

    function addToTotalLiquidityStateLendingProtocol(uint128 liquidity, int24 tickLower, int24 tickUpper) private {
        // add to totalLiquidityState mapping
        int24 totalTicks = _getTotalTicks(tickLower, tickUpper);
        uint128 eachTickLiquidity = liquidity / uint128(uint24(totalTicks));
        console.log("Updating Liquidity State Mapping");
        int24 modifiedTickLower;
        if (tickLower % 10 == 0) modifiedTickLower = tickLower;
        else modifiedTickLower = ((tickLower) / 10) * 10 + 10;
        for (int24 tick = modifiedTickLower; tick <= tickUpper; tick += 10) {
            overallLiquidityLendingProtocol += eachTickLiquidity;
            console.log("Tick: %d", tick);
            if (totalLiquidityState[tick][true] == 0) totalLiquidityState[tick][true] = eachTickLiquidity;
            else totalLiquidityState[tick][true] += eachTickLiquidity;
        }
    }

    function removeFromTotalLiquidityStateLendingProtocol(uint128 liquidity, int24 tickLower, int24 tickUpper) private {
        // add to totalLiquidityState mapping
        int24 totalTicks = _getTotalTicks(tickLower, tickUpper);
        uint128 eachTickLiquidity = liquidity / uint128(uint24(totalTicks));
        console.log("Updating Liquidity State Mapping");
        int24 modifiedTickLower;
        if (tickLower % 10 == 0) modifiedTickLower = tickLower;
        else modifiedTickLower = ((tickLower) / 10) * 10 + 10;
        for (int24 tick = modifiedTickLower; tick <= tickUpper; tick += 10) {
            overallLiquidityLendingProtocol -= eachTickLiquidity;
            console.log("Tick: %d", tick);
            totalLiquidityState[tick][true] -= eachTickLiquidity;
        }
    }

    // Function that transfer tokens from hook into Lending Protocol
    function depositIntoLendingProtocol(uint256 amount0, uint256 amount1, Currency currency0, Currency currency1)
        private
    {
        // Transfer tokens from hook contract to lending protocol
        IERC20(Currency.unwrap(currency0)).transfer(lendingProtocolAddress, amount0);

        token0AmountLendingProtocol += amount0;

        IERC20(Currency.unwrap(currency1)).transfer(lendingProtocolAddress, amount1);

        token1AmountLendingProtocol += amount1;
    }

    // Function that transfers tokens from Lending Protocol into hook
    function withdrawFromLendingProtocol(uint256 amount0, uint256 amount1, Currency currency0, Currency currency1)
        private
    {
        // Transfer tokens from hook contract to lending protocol
        IERC20(Currency.unwrap(currency0)).transferFrom(lendingProtocolAddress, address(this), amount0);

        token0AmountLendingProtocol -= amount0;

        IERC20(Currency.unwrap(currency1)).transferFrom(lendingProtocolAddress, address(this), amount1);

        token1AmountLendingProtocol -= amount1;
    }

    // Function that moves all liquidity from ticks corresponding to tickLower and tickUpper range
    // from pool to lending protocol
    function moveAllFromPoolToLendingProtocol(
        PoolKey calldata key,
        Currency currency0,
        Currency currency1,
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper
    ) private {
        int24 modifiedTickLower;

        // Round up to the highest usable tick (i.e 21 => 30)
        if (tickLower % 10 == 0) modifiedTickLower = tickLower;
        else modifiedTickLower = ((tickLower) / 10) * 10 + 10;
        for (int24 tick = modifiedTickLower; tick <= tickUpper; tick += 10) {
            // Liquidity corresponding to tick in the pool
            uint128 liquidity = totalLiquidityState[tick][false];
            poolManager.unlock(
            abi.encode(
                CallbackData(
                    liquidity,
                    currency0,
                    currency1,
                    msg.sender,
                    key,
                    sqrtPriceX96,
                    tick,
                    tick,
                    2
                )));
            (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, TickMath.getSqrtPriceAtTick(tick), TickMath.getSqrtPriceAtTick(tick), liquidity);
            depositIntoLendingProtocol(amount0, amount1, currency0, currency1);
            totalLiquidityState[tick][false] = 0;
            totalLiquidityState[tick][true] += liquidity;
        }
    }

    // Function that moves all liquidity from ticks corresponding to tickLower and tickUpper range
    // from lending protocol to pool
    function moveAllFromLendingProtocolToPool(
        PoolKey calldata key,
        Currency currency0,
        Currency currency1,
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper
    ) private {
        int24 modifiedTickLower;

        if (tickLower % 10 == 0) modifiedTickLower = tickLower;
        else modifiedTickLower = ((tickLower) / 10) * 10 + 10;
        for (int24 tick = modifiedTickLower; tick <= tickUpper; tick += 10) {
            uint128 liquidity = totalLiquidityState[tick][true];
            // Finding amounts for particular tick liquidity
            (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96, TickMath.getSqrtPriceAtTick(tick), TickMath.getSqrtPriceAtTick(tick), liquidity
            );
            withdrawFromLendingProtocol(amount0, amount1, currency0, currency1);
            poolManager.unlock(
            abi.encode(
                CallbackData(
                    liquidity,
                    currency0,
                    currency1,
                    msg.sender,
                    key,
                    sqrtPriceX96,
                    tick,
                    tick,
                    1
                )));
            totalLiquidityState[tick][true] = 0;
            totalLiquidityState[tick][false] += liquidity;
        }
    }

    function _getTotalTicks(int24 tickLower, int24 tickUpper) internal pure returns (int24 totalTicks) {
        return ((tickUpper - tickLower) / 10) + 1;
    }
}

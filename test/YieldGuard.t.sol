// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BaseTest} from "./utils/BaseTest.sol";

import {YieldGuard} from "../src/YieldGuard.sol";
import {MockYieldVault} from "../src/mocks/MockYieldVault.sol";
import {ReactiveVolatilityMonitor} from "../src/reactive/ReactiveVolatilityMonitor.sol";

contract YieldGuardTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // ─── State Variables ────────────────────────────────────────────────
    Currency currency0;
    Currency currency1;

    PoolKey poolKey;
    YieldGuard hook;
    PoolId poolId;

    MockYieldVault vault0;
    MockYieldVault vault1;

    address reactiveRelayer;
    address unauthorized;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    // ─── Setup ──────────────────────────────────────────────────────────

    function setUp() public {
        // Deploy all V4 infrastructure
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        // Set up actors
        reactiveRelayer = makeAddr("ReactiveRelayer");
        unauthorized = makeAddr("Unauthorized");

        // Deploy the hook with correct flag permissions
        address flags = address(
            uint160(
                Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            ) ^ (0x5555 << 144) // Namespace the hook to avoid collisions
        );
        bytes memory constructorArgs = abi.encode(poolManager, reactiveRelayer);
        deployCodeTo("YieldGuard.sol:YieldGuard", constructorArgs, flags);
        hook = YieldGuard(flags);

        // Deploy mock yield vaults for each token
        vault0 = new MockYieldVault(Currency.unwrap(currency0));
        vault1 = new MockYieldVault(Currency.unwrap(currency1));

        // Configure vaults on the hook
        hook.setYieldVault(Currency.unwrap(currency0), vault0);
        hook.setYieldVault(Currency.unwrap(currency1), vault1);

        // Create the pool with DYNAMIC_FEE flag
        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        // Provide full-range liquidity
        tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        uint128 liquidityAmount = 100e18;
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        (tokenId,) = positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    //  SUCCESS FLOWS (Happy Path)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Test that the hook initializes with correct default state
    function test_InitialState() public view {
        assertEq(hook.isVolatile(), false, "Should start in CALM state");
        assertEq(hook.reactiveRelayer(), reactiveRelayer, "Relayer should be set");
        assertEq(hook.CALM_FEE(), 500, "Calm fee should be 0.05%");
        assertEq(hook.VOLATILE_FEE(), 30000, "Volatile fee should be 3.0%");
    }

    /// @notice Test that the Reactive relayer can set volatility state to VOLATILE
    function test_SetVolatilityState_Volatile() public {
        vm.prank(reactiveRelayer);
        hook.setVolatilityState(true);

        assertEq(hook.isVolatile(), true, "Should be VOLATILE after relayer update");
    }

    /// @notice Test that the Reactive relayer can set volatility state back to CALM
    function test_SetVolatilityState_CalmAfterVolatile() public {
        vm.prank(reactiveRelayer);
        hook.setVolatilityState(true);
        assertEq(hook.isVolatile(), true);

        vm.prank(reactiveRelayer);
        hook.setVolatilityState(false);
        assertEq(hook.isVolatile(), false, "Should be CALM after relayer reset");
    }

    /// @notice Test swap in CALM state applies the low 0.05% fee
    function test_SwapInCalmState_LowFee() public {
        // Ensure state is CALM (default)
        assertEq(hook.isVolatile(), false);

        uint256 amountIn = 1e18;
        BalanceDelta swapDelta = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // Swap should have executed successfully
        assertEq(int256(swapDelta.amount0()), -int256(amountIn), "Should consume exact input");
        assertTrue(swapDelta.amount1() > 0, "Should receive output tokens");
    }

    /// @notice Test swap in VOLATILE state applies the high 3.0% fee
    function test_SwapInVolatileState_HighFee() public {
        // Set state to VOLATILE
        vm.prank(reactiveRelayer);
        hook.setVolatilityState(true);

        uint256 amountIn = 1e18;
        BalanceDelta swapDelta = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        assertEq(int256(swapDelta.amount0()), -int256(amountIn), "Should consume exact input");
        assertTrue(swapDelta.amount1() > 0, "Should receive output tokens in volatile mode");
    }

    /// @notice Test that volatile fees are higher than calm fees (MEV protection)
    function test_VolatileFeeHigherThanCalm() public {
        uint256 amountIn = 1e18;

        // Swap in CALM state
        BalanceDelta calmDelta = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // Set to VOLATILE and swap again
        vm.prank(reactiveRelayer);
        hook.setVolatilityState(true);

        BalanceDelta volatileDelta = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // In volatile mode, user should receive LESS output (higher fee)
        assertTrue(
            volatileDelta.amount1() < calmDelta.amount1(),
            "Volatile swap output should be less than calm swap (higher fee)"
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    //  FAILURE FLOWS (Reverts & Access Control)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Test that unauthorized addresses cannot update volatility state
    function test_RevertWhen_UnauthorizedSetsVolatility() public {
        vm.prank(unauthorized);
        vm.expectRevert(YieldGuard.OnlyReactiveRelayer.selector);
        hook.setVolatilityState(true);
    }

    /// @notice Test that random EOAs cannot call setVolatilityState
    function test_RevertWhen_RandomEOASetsVolatility() public {
        address randomUser = makeAddr("RandomUser");
        vm.prank(randomUser);
        vm.expectRevert(YieldGuard.OnlyReactiveRelayer.selector);
        hook.setVolatilityState(false);
    }

    /// @notice Test that the hook contract itself cannot call setVolatilityState
    function test_RevertWhen_HookSelfCallsVolatility() public {
        vm.prank(address(hook));
        vm.expectRevert(YieldGuard.OnlyReactiveRelayer.selector);
        hook.setVolatilityState(true);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  REACTIVE NETWORK CONTRACT TESTS
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Test ReactiveVolatilityMonitor initial state
    function test_ReactiveMonitor_InitialState() public {
        ReactiveVolatilityMonitor monitor = new ReactiveVolatilityMonitor(
            1, // destinationChainId
            address(hook),
            address(0xBEEF), // mock oracle
            1000e18 // initial reference price
        );

        assertEq(monitor.destinationChainId(), 1);
        assertEq(monitor.yieldGuardHook(), address(hook));
        assertEq(monitor.referencePrice(), 1000e18);
        assertEq(monitor.currentVolatileState(), false);
    }

    /// @notice Test ReactiveVolatilityMonitor detects volatility on large price deviation
    function test_ReactiveMonitor_DetectsVolatility() public {
        ReactiveVolatilityMonitor monitor = new ReactiveVolatilityMonitor(
            1,
            address(hook),
            address(0xBEEF),
            1000e18 // reference price = 1000
        );

        // Check: 5% deviation should trigger volatile (threshold is 2%)
        (bool isVol, uint256 deviation) = monitor.checkVolatility(1050e18);
        assertTrue(isVol, "5% up deviation should be volatile");
        assertEq(deviation, 500, "Deviation should be 500 bps (5%)");

        // Check: 1% deviation should NOT trigger
        (isVol, deviation) = monitor.checkVolatility(1010e18);
        assertFalse(isVol, "1% deviation should NOT be volatile");
        assertEq(deviation, 100, "Deviation should be 100 bps (1%)");
    }

    /// @notice Test ReactiveVolatilityMonitor detects downward volatility (crash)
    function test_ReactiveMonitor_DetectsCrash() public {
        ReactiveVolatilityMonitor monitor = new ReactiveVolatilityMonitor(
            1,
            address(hook),
            address(0xBEEF),
            1000e18
        );

        // 3% crash should trigger volatile
        (bool isVol, uint256 deviation) = monitor.checkVolatility(970e18);
        assertTrue(isVol, "3% down deviation should be volatile");
        assertEq(deviation, 300, "Deviation should be 300 bps (3%)");
    }

    /// @notice Test ReactiveVolatilityMonitor react() emits callback on state change
    function test_ReactiveMonitor_ReactEmitsCallback() public {
        ReactiveVolatilityMonitor monitor = new ReactiveVolatilityMonitor(
            1,
            address(hook),
            address(0xBEEF),
            1000e18
        );

        // Advance time past MIN_UPDATE_INTERVAL (12s) so the rate limiter allows the update
        vm.warp(100);

        // React with a price that triggers volatility (5% spike)
        bytes memory payload = abi.encode(uint256(1050e18));

        vm.expectEmit(true, true, false, true);
        emit ReactiveVolatilityMonitor.Callback(
            1,
            address(hook),
            abi.encodeWithSignature("setVolatilityState(bool)", true)
        );

        monitor.react(1, address(0xBEEF), payload);

        assertEq(monitor.currentVolatileState(), true, "State should be volatile after react");
    }

    /// @notice Test ReactiveVolatilityMonitor updates reference price with EMA
    function test_ReactiveMonitor_EMAUpdate() public {
        ReactiveVolatilityMonitor monitor = new ReactiveVolatilityMonitor(
            1,
            address(hook),
            address(0xBEEF),
            1000e18
        );

        // React with a calm price (1% move, below 2% threshold)
        bytes memory payload = abi.encode(uint256(1010e18));
        monitor.react(1, address(0xBEEF), payload);

        // EMA: (1000 * 9 + 1010) / 10 = 901
        uint256 expectedRef = (1000e18 * 9 + 1010e18) / 10;
        assertEq(monitor.referencePrice(), expectedRef, "Reference price should update via EMA");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  FUZZ TESTS
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Fuzz: any swap amount should execute without reverting in CALM state
    function testFuzz_SwapInCalmState(uint256 amountIn) public {
        // Bound to reasonable range: 0.001 ETH to 10 ETH (pool has 100e18 liquidity)
        amountIn = bound(amountIn, 1e15, 10e18);

        BalanceDelta swapDelta = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        assertEq(int256(swapDelta.amount0()), -int256(amountIn), "Input should match");
        assertTrue(swapDelta.amount1() > 0, "Should receive output");
    }

    /// @notice Fuzz: any swap amount should execute without reverting in VOLATILE state
    function testFuzz_SwapInVolatileState(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e15, 10e18);

        vm.prank(reactiveRelayer);
        hook.setVolatilityState(true);

        BalanceDelta swapDelta = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        assertEq(int256(swapDelta.amount0()), -int256(amountIn), "Input should match");
        assertTrue(swapDelta.amount1() > 0, "Should receive output in volatile mode");
    }

    /// @notice Fuzz: ReactiveVolatilityMonitor deviation calculation is correct
    function testFuzz_ReactiveMonitor_DeviationCalculation(uint256 refPrice, uint256 curPrice) public {
        refPrice = bound(refPrice, 1e18, 100_000e18);
        curPrice = bound(curPrice, 1e18, 100_000e18);

        ReactiveVolatilityMonitor monitor = new ReactiveVolatilityMonitor(
            1, address(hook), address(0xBEEF), refPrice
        );

        (bool isVol, uint256 deviation) = monitor.checkVolatility(curPrice);

        // Manually calculate expected deviation
        uint256 expectedDeviation;
        if (curPrice >= refPrice) {
            expectedDeviation = ((curPrice - refPrice) * 10000) / refPrice;
        } else {
            expectedDeviation = ((refPrice - curPrice) * 10000) / refPrice;
        }

        assertEq(deviation, expectedDeviation, "Deviation should match manual calculation");
        assertEq(isVol, deviation >= 200, "Volatility flag should match threshold check");
    }

    /// @notice Fuzz: unauthorized address can never set volatility state
    function testFuzz_UnauthorizedCannotSetVolatility(address caller) public {
        vm.assume(caller != reactiveRelayer);
        vm.prank(caller);
        vm.expectRevert(YieldGuard.OnlyReactiveRelayer.selector);
        hook.setVolatilityState(true);
    }
}

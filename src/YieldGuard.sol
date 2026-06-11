// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockYieldVault} from "./mocks/MockYieldVault.sol";

/// @title YieldGuard
/// @notice A Uniswap v4 Hook that provides:
///   1. MEV Protection via dynamic fees controlled by Reactive Network volatility signals
///   2. Capital Efficiency by routing idle LP liquidity to a yield-bearing vault (Aave mock)
///
/// @dev The Reactive Network acts as an off-chain brain that monitors market volatility
///      and calls `setVolatilityState()` to flip the hook between CALM and VOLATILE modes.
///
///      In CALM mode:  swap fee = 0.05% (500 bps)  — competitive, attracts volume
///      In VOLATILE mode: swap fee = 3.0% (30000 bps) — taxes toxic MEV arbitrage
///
///      Idle capital is routed to MockYieldVault (simulating Aave) to earn continuous yield,
///      and pulled back Just-In-Time (JIT) when swaps require liquidity.
contract YieldGuard is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using LPFeeLibrary for uint24;

    // ─── Constants ──────────────────────────────────────────────────────
    /// @notice Fee charged during calm market conditions (0.05% = 500 bps)
    uint24 public constant CALM_FEE = 500;

    /// @notice Fee charged during volatile market conditions (3.0% = 30000 bps)
    uint24 public constant VOLATILE_FEE = 30000;

    /// @notice Percentage of idle liquidity routed to the yield vault (90%)
    uint256 public constant YIELD_ALLOCATION_BPS = 9000;

    /// @notice BPS denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    // ─── State ──────────────────────────────────────────────────────────
    /// @notice The address authorized to update volatility state (Reactive Network relayer)
    address public immutable reactiveRelayer;

    /// @notice Current volatility state — true = VOLATILE, false = CALM
    bool public isVolatile;

    /// @notice Yield vaults for each token in supported pools
    /// @dev Maps token address → MockYieldVault
    mapping(address => MockYieldVault) public yieldVaults;

    /// @notice Tracks total deposited to vault per pool per token for accounting
    mapping(PoolId => mapping(address => uint256)) public vaultDeposits;

    // ─── Events ─────────────────────────────────────────────────────────
    event VolatilityStateUpdated(bool isVolatile, uint256 timestamp);
    event LiquidityDepositedToVault(PoolId indexed poolId, address indexed token, uint256 amount);
    event LiquidityWithdrawnFromVault(PoolId indexed poolId, address indexed token, uint256 amount);
    event DynamicFeeApplied(PoolId indexed poolId, uint24 fee, bool isVolatile);

    // ─── Errors ─────────────────────────────────────────────────────────
    error OnlyReactiveRelayer();
    error VaultNotConfigured(address token);

    // ─── Constructor ────────────────────────────────────────────────────
    constructor(IPoolManager _poolManager, address _reactiveRelayer) BaseHook(_poolManager) {
        reactiveRelayer = _reactiveRelayer;
    }

    // ─── Modifiers ──────────────────────────────────────────────────────
    modifier onlyReactiveRelayer() {
        if (msg.sender != reactiveRelayer) revert OnlyReactiveRelayer();
        _;
    }

    // ─── Hook Permissions ───────────────────────────────────────────────
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,       // Route idle capital to yield vault
            beforeRemoveLiquidity: true,   // Pull capital from yield vault before removal
            afterRemoveLiquidity: false,
            beforeSwap: true,              // Set dynamic fee + JIT pull from vault
            afterSwap: true,               // Re-deposit excess to vault
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─── Admin Functions ────────────────────────────────────────────────

    /// @notice Configure a yield vault for a specific token
    /// @param token The ERC20 token address
    /// @param vault The MockYieldVault address for that token
    function setYieldVault(address token, MockYieldVault vault) external {
        yieldVaults[token] = vault;
    }

    /// @notice Called by the Reactive Network relayer to update the volatility state
    /// @param _isVolatile True if the market is volatile (MEV protection ON)
    function setVolatilityState(bool _isVolatile) external onlyReactiveRelayer {
        isVolatile = _isVolatile;
        emit VolatilityStateUpdated(_isVolatile, block.timestamp);
    }

    // ─── Hook Implementations ───────────────────────────────────────────

    /// @notice After liquidity is added, route a portion to the yield vault
    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();

        // Route token0 idle capital to vault
        _depositToVault(poolId, Currency.unwrap(key.currency0), _abs(delta.amount0()));

        // Route token1 idle capital to vault
        _depositToVault(poolId, Currency.unwrap(key.currency1), _abs(delta.amount1()));

        return (BaseHook.afterAddLiquidity.selector, delta);
    }

    /// @notice Before liquidity is removed, ensure we have enough by pulling from vault
    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();

        // Pull all deposited capital back from vault for both tokens
        _withdrawAllFromVault(poolId, Currency.unwrap(key.currency0));
        _withdrawAllFromVault(poolId, Currency.unwrap(key.currency1));

        return BaseHook.beforeRemoveLiquidity.selector;
    }

    /// @notice Before a swap: set the dynamic fee and pull JIT liquidity from the vault
    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();

        // Determine the dynamic fee based on volatility state
        uint24 fee;
        if (isVolatile) {
            fee = VOLATILE_FEE;
        } else {
            fee = CALM_FEE;
        }

        emit DynamicFeeApplied(poolId, fee, isVolatile);

        // JIT: Pull liquidity from vault to ensure the pool has enough to execute
        _withdrawAllFromVault(poolId, Currency.unwrap(key.currency0));
        _withdrawAllFromVault(poolId, Currency.unwrap(key.currency1));

        // Return the fee with the OVERRIDE flag so PoolManager uses our dynamic fee
        return (
            BaseHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            fee | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    /// @notice After a swap: re-deposit idle liquidity back to the yield vault
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();

        // Re-deposit idle capital back to vault
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        if (balance0 > 0) {
            _depositToVault(poolId, token0, balance0);
        }
        if (balance1 > 0) {
            _depositToVault(poolId, token1, balance1);
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    // ─── Internal Helpers ───────────────────────────────────────────────

    /// @notice Deposit a portion of tokens to the yield vault
    /// @param poolId The pool identifier
    /// @param token The token to deposit
    /// @param totalAmount The total amount available — only YIELD_ALLOCATION_BPS % is deposited
    function _depositToVault(PoolId poolId, address token, uint256 totalAmount) internal {
        MockYieldVault vault = yieldVaults[token];
        if (address(vault) == address(0)) return; // No vault configured, skip silently

        uint256 depositAmount = (totalAmount * YIELD_ALLOCATION_BPS) / BPS_DENOMINATOR;
        if (depositAmount == 0) return;

        // Check we actually have the balance
        uint256 available = IERC20(token).balanceOf(address(this));
        if (available < depositAmount) {
            depositAmount = available;
        }
        if (depositAmount == 0) return;

        IERC20(token).approve(address(vault), depositAmount);
        vault.deposit(depositAmount, address(this));

        vaultDeposits[poolId][token] += depositAmount;

        emit LiquidityDepositedToVault(poolId, token, depositAmount);
    }

    /// @notice Withdraw all deposited tokens from the yield vault for a given pool + token
    /// @param poolId The pool identifier
    /// @param token The token to withdraw
    function _withdrawAllFromVault(PoolId poolId, address token) internal {
        MockYieldVault vault = yieldVaults[token];
        if (address(vault) == address(0)) return;

        uint256 shares = vault.sharesOf(address(this));
        if (shares == 0) return;

        uint256 assetsReturned = vault.redeem(shares, address(this));

        // Reset accounting
        vaultDeposits[poolId][token] = 0;

        emit LiquidityWithdrawnFromVault(poolId, token, assetsReturned);
    }

    /// @notice Convert int128 to uint256 (absolute value)
    function _abs(int128 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(int256(x)) : uint256(int256(-x));
    }
}

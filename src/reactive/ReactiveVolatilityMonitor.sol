// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IReactiveCallback
/// @notice Interface for Reactive Network callback contracts.
///         Reactive Smart Contracts (RSCs) subscribe to on-chain events and
///         emit reactions that get relayed to destination chains.
interface IReactiveCallback {
    function react(
        uint256 chainId,
        address origin,
        bytes calldata payload
    ) external;
}

/// @title ReactiveVolatilityMonitor
/// @notice A Reactive Smart Contract (RSC) deployed on the Reactive Network.
///         It monitors oracle price deviation events on an origin chain and triggers
///         a callback to the YieldGuard hook on the destination chain to update
///         the volatility state.
///
/// @dev Architecture:
///      ┌──────────────────────┐       ┌───────────────────────┐       ┌──────────────────┐
///      │   Origin Chain       │       │   Reactive Network    │       │  Destination Chain│
///      │   (Oracle Events)    │ ───►  │   (This Contract)     │ ───►  │  (YieldGuard Hook)│
///      │                      │       │   Monitors + Decides  │       │  setVolatilityState│
///      └──────────────────────┘       └───────────────────────┘       └──────────────────┘
///
///      The RSC subscribes to price update events from an on-chain oracle.
///      When price deviation exceeds VOLATILITY_THRESHOLD_BPS, it emits a
///      reaction payload that triggers `setVolatilityState(true)` on the hook.
///      When the deviation returns to normal, it triggers `setVolatilityState(false)`.
///
/// @custom:reactive-network This contract follows Reactive Network's RSC pattern.
///         See: https://docs.reactive.network/
contract ReactiveVolatilityMonitor {
    // ─── Configuration ──────────────────────────────────────────────────

    /// @notice The chain ID of the destination chain where YieldGuard is deployed
    uint256 public immutable destinationChainId;

    /// @notice The address of the YieldGuard hook on the destination chain
    address public immutable yieldGuardHook;

    /// @notice The address of the oracle contract on the origin chain to monitor
    address public immutable oracleSource;

    /// @notice Price deviation threshold in basis points to trigger VOLATILE state
    /// @dev 200 = 2.0% deviation triggers volatility protection
    uint256 public constant VOLATILITY_THRESHOLD_BPS = 200;

    /// @notice BPS denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    // ─── State ──────────────────────────────────────────────────────────

    /// @notice The last known "reference" price from the oracle (scaled to 18 decimals)
    uint256 public referencePrice;

    /// @notice Current volatility state being signaled to the hook
    bool public currentVolatileState;

    /// @notice Timestamp of the last state update sent
    uint256 public lastUpdateTimestamp;

    /// @notice Minimum time between state updates to prevent spamming (in seconds)
    uint256 public constant MIN_UPDATE_INTERVAL = 12; // ~1 block on Ethereum

    // ─── Events ─────────────────────────────────────────────────────────

    /// @notice Emitted when the RSC detects a volatility state change and sends a reaction
    event VolatilityReaction(
        bool isVolatile,
        uint256 priceDeviation,
        uint256 referencePrice,
        uint256 currentPrice,
        uint256 timestamp
    );

    /// @notice Emitted when reference price is updated
    event ReferencePriceUpdated(uint256 oldPrice, uint256 newPrice);

    // ─── Reactive Network Callback Event ────────────────────────────────
    /// @notice This event is picked up by the Reactive Network relay to execute
    ///         the cross-chain callback on the destination chain.
    /// @dev The Reactive Network listens for this event and submits the `payload`
    ///      as a transaction to `target` on `chainId`.
    event Callback(
        uint256 indexed chainId,
        address indexed target,
        bytes payload
    );

    // ─── Constructor ────────────────────────────────────────────────────

    constructor(
        uint256 _destinationChainId,
        address _yieldGuardHook,
        address _oracleSource,
        uint256 _initialReferencePrice
    ) {
        destinationChainId = _destinationChainId;
        yieldGuardHook = _yieldGuardHook;
        oracleSource = _oracleSource;
        referencePrice = _initialReferencePrice;
        currentVolatileState = false;
    }

    // ─── Core Reactive Logic ────────────────────────────────────────────

    /// @notice Called by the Reactive Network when a subscribed oracle event is detected.
    ///         Evaluates the price deviation and triggers a state change if needed.
    /// @param payload ABI-encoded price data from the oracle event
    function react(
        uint256, /* chainId */
        address, /* origin */
        bytes calldata payload
    ) external {
        // Decode the current price from the oracle event payload
        // Expected format: abi.encode(uint256 currentPrice)
        uint256 currentPrice = abi.decode(payload, (uint256));

        // Calculate price deviation in BPS
        uint256 deviation = _calculateDeviation(referencePrice, currentPrice);

        // Determine if market is volatile
        bool shouldBeVolatile = deviation >= VOLATILITY_THRESHOLD_BPS;

        // Only send a reaction if state has changed AND enough time has passed
        if (
            shouldBeVolatile != currentVolatileState &&
            block.timestamp >= lastUpdateTimestamp + MIN_UPDATE_INTERVAL
        ) {
            currentVolatileState = shouldBeVolatile;
            lastUpdateTimestamp = block.timestamp;

            // Encode the callback payload for the destination chain
            bytes memory callbackPayload = abi.encodeWithSignature(
                "setVolatilityState(bool)",
                shouldBeVolatile
            );

            // Emit the Callback event — the Reactive Network relay picks this up
            // and submits it as a transaction to yieldGuardHook on destinationChainId
            emit Callback(destinationChainId, yieldGuardHook, callbackPayload);

            emit VolatilityReaction(
                shouldBeVolatile,
                deviation,
                referencePrice,
                currentPrice,
                block.timestamp
            );
        }

        // Update reference price with exponential moving average (EMA)
        // New ref = 90% old + 10% current — smooths out noise
        uint256 oldRef = referencePrice;
        referencePrice = (referencePrice * 9 + currentPrice) / 10;

        if (referencePrice != oldRef) {
            emit ReferencePriceUpdated(oldRef, referencePrice);
        }
    }

    // ─── View Functions ─────────────────────────────────────────────────

    /// @notice Check if a given price would trigger a volatile state
    /// @param currentPrice The price to check against the reference
    /// @return isVolatile Whether this price exceeds the volatility threshold
    /// @return deviation The calculated deviation in BPS
    function checkVolatility(uint256 currentPrice)
        external
        view
        returns (bool isVolatile, uint256 deviation)
    {
        deviation = _calculateDeviation(referencePrice, currentPrice);
        isVolatile = deviation >= VOLATILITY_THRESHOLD_BPS;
    }

    // ─── Internal Helpers ───────────────────────────────────────────────

    /// @notice Calculate the absolute deviation between two prices in BPS
    /// @param refPrice The reference price
    /// @param curPrice The current price
    /// @return deviation The absolute deviation in basis points
    function _calculateDeviation(uint256 refPrice, uint256 curPrice)
        internal
        pure
        returns (uint256 deviation)
    {
        if (refPrice == 0) return 0;

        if (curPrice >= refPrice) {
            deviation = ((curPrice - refPrice) * BPS_DENOMINATOR) / refPrice;
        } else {
            deviation = ((refPrice - curPrice) * BPS_DENOMINATOR) / refPrice;
        }
    }
}

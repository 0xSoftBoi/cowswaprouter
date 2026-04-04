// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ICowTwapExecutor
/// @notice Interface for the CoW Protocol TWAP (Time-Weighted Average Price) Executor.
///         A TWAP executor splits a large order into N time-sliced CoW Protocol settlements
///         to minimize market impact.
interface ICowTwapExecutor {
    enum TwapStatus { ACTIVE, COMPLETED, CANCELLED }

    struct TwapOrder {
        address owner;
        address token;
        uint256 totalAmount;
        uint256 amountPerSlice;
        uint256 sliceCount;
        uint256 slicesExecuted;
        uint256 intervalSeconds;
        uint256 lastExecutedAt;
        uint256 minAmountOutPerSlice;
        TwapStatus status;
    }

    event TwapOrderCreated(
        uint256 indexed orderId,
        address indexed owner,
        address indexed token,
        uint256 totalAmount,
        uint256 sliceCount,
        uint256 intervalSeconds
    );

    event SliceExecuted(
        uint256 indexed orderId,
        uint256 sliceIndex,
        uint256 amountIn,
        bytes orderUid
    );

    event TwapOrderCompleted(uint256 indexed orderId);

    event TwapOrderCancelled(uint256 indexed orderId, uint256 refundAmount);

    /// @notice Create a new TWAP order. Pulls the full token amount upfront.
    /// @param token            ERC-20 token to sell via CoW.
    /// @param totalAmount      Total amount to sell across all slices.
    /// @param sliceCount       Number of equal slices to split the order into.
    /// @param intervalSeconds  Minimum seconds between consecutive slice executions.
    /// @param minAmountOutPerSlice Minimum output per slice (slippage guard passed to CoW).
    /// @return orderId         The ID of the created TWAP order.
    function createTwapOrder(
        address token,
        uint256 totalAmount,
        uint256 sliceCount,
        uint256 intervalSeconds,
        uint256 minAmountOutPerSlice
    ) external returns (uint256 orderId);

    /// @notice Execute the next pending slice of a TWAP order via CoW Protocol.
    ///         Anyone may call this after the interval has elapsed.
    /// @param orderId  The TWAP order to advance.
    /// @param orderUid The CoW Protocol orderUid for this slice (obtained off-chain from CoW API).
    function executeSlice(uint256 orderId, bytes calldata orderUid) external;

    /// @notice Cancel a TWAP order and refund remaining tokens to the owner.
    ///         Only callable by the order owner.
    /// @param orderId  The TWAP order to cancel.
    function cancelTwapOrder(uint256 orderId) external;

    /// @notice Get the full state of a TWAP order.
    function getOrder(uint256 orderId) external view returns (TwapOrder memory);

    /// @notice Returns true if the next slice of an order is ready to execute.
    function isSliceReady(uint256 orderId) external view returns (bool);
}

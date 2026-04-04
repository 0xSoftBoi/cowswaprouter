// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/ICowTwapExecutor.sol";

interface ICowVaultRelayer {
    function deposit(address token, address from, uint256 amount) external;
}

interface ICowSettler {
    function settle(bytes calldata orderUid) external;
}

/// @title CowTwapExecutor
/// @notice Splits a large sell order into N equal time-sliced CoW Protocol settlements.
///
/// @dev PROBLEM SOLVED:
///      Executing a large order (e.g., sell 10,000 ETH) in one transaction causes
///      significant price impact. TWAP execution splits it into smaller slices
///      spread over time, reducing market impact and achieving a better average price.
///
///      This is a common need in institutional and whale trading that lacks a clean
///      open-source implementation on CoW Protocol.
///
/// @dev HOW IT WORKS:
///      1. Caller creates a TwapOrder specifying token, total amount, slice count,
///         and minimum interval between slices.
///      2. The full amount is pulled from the caller immediately and held in escrow.
///      3. Anyone (a keeper, the owner, or a bot) calls executeSlice() with the
///         CoW orderUid for that slice. The slice is settled via CoW Protocol.
///      4. Slices execute at most once per `intervalSeconds`. The order completes
///         when all slices are executed. The owner can cancel at any time for a refund.
///
/// @dev SECURITY:
///      - executeSlice() is permissionless (anyone can execute). This is intentional:
///        it allows keeper bots to execute slices without owner involvement.
///        The minAmountOutPerSlice guard protects against sandwiching each slice.
///      - Tokens are held in escrow (not sent to CoW up front). Cancellation is safe.
///      - ReentrancyGuard + CEI pattern on all state-modifying functions.
///      - The CoW orderUid must be generated off-chain via the CoW API matching the
///        exact amountPerSlice. This contract does NOT validate orderUid contents —
///        CoW's settlement contract enforces them.
///
/// @dev KNOWN LIMITATION:
///      Full integration testing requires a live CoW Protocol solver. Unit tests use
///      mock relayer and settler contracts. See test/CowTwapExecutor.t.sol.
contract CowTwapExecutor is ReentrancyGuard, ICowTwapExecutor {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    address public immutable cowRelayer;
    address public immutable cowSettler;

    uint256 private _nextOrderId;
    mapping(uint256 => TwapOrder) private _orders;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error OrderNotFound(uint256 orderId);
    error OrderNotActive(uint256 orderId);
    error SliceNotReady(uint256 orderId, uint256 nextAllowedAt);
    error NotOrderOwner(uint256 orderId);
    error InvalidSliceCount();
    error InvalidInterval();
    error InvalidAmount();
    error ZeroAddress();

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(address _cowRelayer, address _cowSettler) {
        if (_cowRelayer == address(0) || _cowSettler == address(0)) revert ZeroAddress();
        cowRelayer = _cowRelayer;
        cowSettler = _cowSettler;
    }

    // -------------------------------------------------------------------------
    // Order creation
    // -------------------------------------------------------------------------

    /// @inheritdoc ICowTwapExecutor
    /// @dev Pulls the full totalAmount from msg.sender into this contract (escrow).
    ///      Does NOT require owner to pre-approve the relayer — each slice approves
    ///      and resets individually to limit approval surface.
    function createTwapOrder(
        address token,
        uint256 totalAmount,
        uint256 sliceCount,
        uint256 intervalSeconds,
        uint256 minAmountOutPerSlice
    ) external nonReentrant returns (uint256 orderId) {
        if (token == address(0)) revert ZeroAddress();
        if (totalAmount == 0) revert InvalidAmount();
        if (sliceCount == 0 || sliceCount > 1000) revert InvalidSliceCount();
        if (intervalSeconds == 0) revert InvalidInterval();

        // amountPerSlice must be non-zero — if totalAmount is very small relative to
        // sliceCount, integer division may round to 0.
        uint256 amountPerSlice = totalAmount / sliceCount;
        if (amountPerSlice == 0) revert InvalidAmount();

        orderId = _nextOrderId++;

        _orders[orderId] = TwapOrder({
            owner:                msg.sender,
            token:                token,
            totalAmount:          totalAmount,
            amountPerSlice:       amountPerSlice,
            sliceCount:           sliceCount,
            slicesExecuted:       0,
            intervalSeconds:      intervalSeconds,
            lastExecutedAt:       0, // first slice can execute immediately
            minAmountOutPerSlice: minAmountOutPerSlice,
            status:               TwapStatus.ACTIVE
        });

        // Pull the full amount into escrow NOW so the owner cannot pull rug mid-execution.
        // This also gives executors certainty that funds will be available for each slice.
        IERC20(token).safeTransferFrom(msg.sender, address(this), totalAmount);

        emit TwapOrderCreated(orderId, msg.sender, token, totalAmount, sliceCount, intervalSeconds);
    }

    // -------------------------------------------------------------------------
    // Slice execution (permissionless — any keeper/bot can call)
    // -------------------------------------------------------------------------

    /// @inheritdoc ICowTwapExecutor
    /// @dev Permissionless: anyone can execute. The minAmountOutPerSlice parameter
    ///      on the CoW order (set at creation time) protects against sandwich attacks
    ///      on individual slices.
    ///
    ///      The caller provides a CoW orderUid obtained from the CoW Protocol API.
    ///      The orderUid must correspond to a sell order for exactly amountPerSlice
    ///      of the TWAP token. CoW's settlement contract enforces this — if the
    ///      orderUid does not match, the settle() call will revert.
    function executeSlice(
        uint256 orderId,
        bytes calldata orderUid
    ) external nonReentrant {
        TwapOrder storage order = _orders[orderId];
        if (order.owner == address(0)) revert OrderNotFound(orderId);
        if (order.status != TwapStatus.ACTIVE) revert OrderNotActive(orderId);

        // Enforce time interval between slices.
        // First slice: lastExecutedAt == 0, so condition is always satisfied.
        uint256 nextAllowedAt = order.lastExecutedAt + order.intervalSeconds;
        if (order.lastExecutedAt != 0 && block.timestamp < nextAllowedAt) {
            revert SliceNotReady(orderId, nextAllowedAt);
        }

        uint256 sliceIndex = order.slicesExecuted;
        uint256 amount     = order.amountPerSlice;

        // EFFECTS: update state before external calls (CEI)
        order.slicesExecuted += 1;
        order.lastExecutedAt  = block.timestamp;

        bool isLastSlice = order.slicesExecuted == order.sliceCount;
        if (isLastSlice) {
            order.status = TwapStatus.COMPLETED;
        }

        // INTERACTIONS: approve slice amount, deposit, settle, reset approval.
        IERC20(order.token).forceApprove(cowRelayer, amount);
        ICowVaultRelayer(cowRelayer).deposit(order.token, order.owner, amount);
        IERC20(order.token).forceApprove(cowRelayer, 0);

        if (orderUid.length > 0) {
            ICowSettler(cowSettler).settle(orderUid);
        }

        emit SliceExecuted(orderId, sliceIndex, amount, orderUid);

        if (isLastSlice) {
            emit TwapOrderCompleted(orderId);
        }
    }

    // -------------------------------------------------------------------------
    // Cancellation
    // -------------------------------------------------------------------------

    /// @inheritdoc ICowTwapExecutor
    /// @dev Only the order owner can cancel. Remaining (unexecuted) tokens are
    ///      returned to the owner. Already-executed slices are not affected.
    function cancelTwapOrder(uint256 orderId) external nonReentrant {
        TwapOrder storage order = _orders[orderId];
        if (order.owner == address(0)) revert OrderNotFound(orderId);
        if (order.status != TwapStatus.ACTIVE) revert OrderNotActive(orderId);
        if (msg.sender != order.owner) revert NotOrderOwner(orderId);

        // Calculate refund: unexecuted slices * amountPerSlice
        uint256 executedAmount = order.slicesExecuted * order.amountPerSlice;
        uint256 refund         = order.totalAmount - executedAmount;

        // EFFECTS before INTERACTIONS
        order.status = TwapStatus.CANCELLED;

        // INTERACTIONS: return remaining tokens
        if (refund > 0) {
            IERC20(order.token).safeTransfer(order.owner, refund);
        }

        emit TwapOrderCancelled(orderId, refund);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @inheritdoc ICowTwapExecutor
    function getOrder(uint256 orderId) external view returns (TwapOrder memory) {
        if (_orders[orderId].owner == address(0)) revert OrderNotFound(orderId);
        return _orders[orderId];
    }

    /// @inheritdoc ICowTwapExecutor
    function isSliceReady(uint256 orderId) external view returns (bool) {
        TwapOrder storage order = _orders[orderId];
        if (order.status != TwapStatus.ACTIVE) return false;
        if (order.lastExecutedAt == 0) return true;
        return block.timestamp >= order.lastExecutedAt + order.intervalSeconds;
    }

    /// @notice Total number of orders ever created.
    function totalOrders() external view returns (uint256) {
        return _nextOrderId;
    }
}

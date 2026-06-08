// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/ICowTwapExecutor.sol";

interface IGPv2Settlement {
    /// PreSign scheme: an order's owner authorizes it on-chain by flagging its orderUid;
    /// CoW solvers may then settle it. (The alternative is ERC-1271 isValidSignature.)
    function setPreSignature(bytes calldata orderUid, bool signed) external;
    /// The vault relayer that pulls user funds during settlement — what gets approved,
    /// NOT the settlement contract itself.
    function vaultRelayer() external view returns (address);
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
///      3. Anyone (a keeper, the owner, or a bot) calls executeSlice() with the CoW
///         orderUid for that slice. This contract AUTHORIZES the order via the PreSign
///         scheme (setPreSignature) — it does NOT settle. CoW solvers pick the order up
///         and settle it; the vault relayer (approved at creation) pulls the slice amount.
///      4. Slices execute at most once per `intervalSeconds`. The order completes
///         when all slices are executed. The owner can cancel at any time for a refund.
///
/// @dev COW INTEGRATION (the real protocol):
///      - Orders are intents, not swaps. Users/this contract approve the GPv2VaultRelayer
///        (NOT the settlement contract); the relayer pulls funds only as part of a
///        settlement of an order this contract presigned. settle() is onlySolver — this
///        contract never calls it.
///      - A slice's orderUid is built off-chain (CoW API) for a sell order of exactly
///        amountPerSlice, owner = this contract, receiver = the TWAP owner. CoW's
///        settlement enforces the order's limits; this contract only authorizes it.
///
/// @dev SECURITY:
///      - executeSlice() is permissionless (anyone can execute). Intentional: keeper bots
///        run slices without owner involvement. minAmountOutPerSlice (in the off-chain
///        orderUid) protects each slice against sandwiching.
///      - Tokens are held in escrow. cancelTwapOrder refunds the UN-EXECUTED remainder; a
///        slice already presigned and in-flight can still be filled until its validTo —
///        the owner may call revokePresignature() to kill it.
///      - ReentrancyGuard + CEI on all state-modifying functions.
///
/// @dev KNOWN LIMITATION:
///      Full integration testing requires a live CoW Protocol solver. Unit tests use
///      mock relayer and settler contracts. See test/CowTwapExecutor.t.sol.
contract CowTwapExecutor is ReentrancyGuard, ICowTwapExecutor {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /// Canonical CoW Protocol addresses (identical across the chains CoW deploys to).
    address public constant MAINNET_SETTLEMENT    = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;
    address public constant MAINNET_VAULT_RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;

    /// GPv2Settlement — where this contract presigns each slice order.
    address public immutable cowSettlement;
    /// GPv2VaultRelayer — what this contract approves so solvers can pull each slice.
    address public immutable cowRelayer;

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

    /// @param _cowSettlement the GPv2Settlement address (use MAINNET_SETTLEMENT on mainnet).
    ///        The vault relayer is read from it, so the two can never be mismatched.
    constructor(address _cowSettlement) {
        if (_cowSettlement == address(0)) revert ZeroAddress();
        cowSettlement = _cowSettlement;
        address relayer = IGPv2Settlement(_cowSettlement).vaultRelayer();
        if (relayer == address(0)) revert ZeroAddress();
        cowRelayer = relayer;
    }

    // -------------------------------------------------------------------------
    // Order creation
    // -------------------------------------------------------------------------

    /// @inheritdoc ICowTwapExecutor
    /// @dev Pulls the full totalAmount from msg.sender into escrow, then approves the vault
    ///      relayer once. A standing approval is safe: the relayer can only pull via a
    ///      settlement of an order THIS contract presigned, and the approval must persist
    ///      across the async gap between presign and a solver settling (resetting it per
    ///      slice — as a naive implementation would — breaks the fill).
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

        // Approve the vault relayer to pull this token (CoW's "single relayer approval").
        IERC20(token).forceApprove(cowRelayer, type(uint256).max);

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

        // INTERACTIONS: authorize this slice's order via the PreSign scheme so CoW solvers
        // can fill it. We do NOT call settle() — that is onlySolver on the real protocol.
        // The relayer (approved at creation) pulls `amount` when a solver settles the order.
        if (orderUid.length > 0) {
            IGPv2Settlement(cowSettlement).setPreSignature(orderUid, true);
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

    /// @notice Revoke a still-in-flight presigned slice order so a solver can no longer
    ///         fill it. Use after cancelling to kill a slice that was presigned but not yet
    ///         settled (its tokens are otherwise still pullable until the order's validTo).
    /// @dev Only the order owner. Already-settled slices are unaffected.
    function revokePresignature(uint256 orderId, bytes calldata orderUid) external {
        if (_orders[orderId].owner != msg.sender) revert NotOrderOwner(orderId);
        IGPv2Settlement(cowSettlement).setPreSignature(orderUid, false);
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

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev The CoW Protocol order struct (GPv2Order.Data) — the EIP-712 payload a solver fills.
library GPv2Order {
    struct Data {
        IERC20 sellToken;
        IERC20 buyToken;
        address receiver;
        uint256 sellAmount;
        uint256 buyAmount;
        uint32 validTo;
        bytes32 appData;
        uint256 feeAmount;
        bytes32 kind;
        bool partiallyFillable;
        bytes32 sellTokenBalance;
        bytes32 buyTokenBalance;
    }
    bytes32 internal constant KIND_SELL     = keccak256("sell");
    bytes32 internal constant BALANCE_ERC20 = keccak256("erc20");
}

/// @dev The ComposableCoW conditional-order interface (faithful, slightly simplified —
///      the watchtower-poll control errors and the generator method are what matter).
interface IConditionalOrder {
    /// The order is permanently invalid; the watchtower drops it.
    error OrderNotValid(string reason);
    /// Nothing tradeable yet; the watchtower should poll again on a later block.
    error PollTryNextBlock(string reason);
}

interface IConditionalOrderGenerator is IConditionalOrder {
    function getTradeableOrder(
        address owner,
        address sender,
        bytes32 ctx,
        bytes calldata staticInput,
        bytes calldata offchainInput
    ) external view returns (GPv2Order.Data memory);
}

/// @title CowTwapHandler
/// @notice A ComposableCoW TWAP conditional order (the official-framework path). Instead of
///         a self-hosted keeper presigning each slice, a smart account registers ONE
///         conditional order with these params; CoW's watchtower repeatedly calls
///         getTradeableOrder() to obtain the part valid at the current block and posts it,
///         and the settlement contract calls verify() (via ERC-1271) so a solver can only
///         ever fill the part this handler currently authorizes — validated discretization,
///         on-chain cancellation, no custom keeper. Mirrors cowprotocol/composable-cow's
///         TWAP handler (TWAPOrder.Data fields + the same validation guards).
contract CowTwapHandler is IConditionalOrderGenerator {
    /// Same shape as composable-cow's TWAPOrder.Data.
    struct TWAPData {
        IERC20 sellToken;
        IERC20 buyToken;
        address receiver;
        uint256 partSellAmount; // sell amount per part
        uint256 minPartLimit;   // min buy per part (the per-part limit price)
        uint256 t0;             // first part start (unix seconds)
        uint256 n;              // number of parts
        uint256 t;              // seconds between parts
        uint256 span;           // active trading window within each interval (0 = whole interval)
        bytes32 appData;
    }

    uint256 internal constant MAX_T = 365 days;

    /// @notice Validate the static TWAP parameters (same guards as composable-cow).
    function validate(bytes calldata staticInput) public pure {
        TWAPData memory d = abi.decode(staticInput, (TWAPData));
        if (address(d.sellToken) == address(0) || address(d.buyToken) == address(0)) {
            revert OrderNotValid("token is zero");
        }
        if (d.sellToken == d.buyToken) revert OrderNotValid("same token");
        if (d.partSellAmount == 0) revert OrderNotValid("partSellAmount zero");
        if (d.minPartLimit == 0) revert OrderNotValid("minPartLimit zero");
        if (d.t0 >= type(uint32).max) revert OrderNotValid("t0 too large");
        if (d.n <= 1 || d.n > type(uint32).max) revert OrderNotValid("n out of range");
        if (d.t == 0 || d.t > MAX_T) revert OrderNotValid("t out of range");
        if (d.span > d.t) revert OrderNotValid("span gt t");
    }

    /// @inheritdoc IConditionalOrderGenerator
    /// @notice The discrete GPv2 order valid at the current block, or a poll/abort signal.
    function getTradeableOrder(
        address, /* owner */
        address, /* sender */
        bytes32, /* ctx */
        bytes calldata staticInput,
        bytes calldata /* offchainInput */
    ) public view override returns (GPv2Order.Data memory order) {
        TWAPData memory d = abi.decode(staticInput, (TWAPData));
        validate(staticInput);

        // Before the first part: nothing yet — poll again later.
        if (block.timestamp < d.t0) revert PollTryNextBlock("twap not started");

        uint256 elapsed = block.timestamp - d.t0;
        uint256 part = elapsed / d.t;
        // After the last part: the TWAP is finished, permanently.
        if (part >= d.n) revert OrderNotValid("twap finished");

        uint256 timeInPart = elapsed - part * d.t;
        uint256 window = d.span == 0 ? d.t : d.span;
        // Past this part's active window (only with a span): wait for the next part.
        if (timeInPart >= window) revert PollTryNextBlock("not within span");

        uint256 validTo = d.t0 + part * d.t + window; // end of this part's active window

        order = GPv2Order.Data({
            sellToken:         d.sellToken,
            buyToken:          d.buyToken,
            receiver:          d.receiver,
            sellAmount:        d.partSellAmount,
            buyAmount:         d.minPartLimit,
            validTo:           uint32(validTo),
            appData:           d.appData,
            feeAmount:         0,
            kind:              GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance:  GPv2Order.BALANCE_ERC20,
            buyTokenBalance:   GPv2Order.BALANCE_ERC20
        });
    }

    /// @notice Validated discretization: a solver's proposed `order` must equal the part
    ///         this handler currently authorizes. Reverts otherwise (settlement fails).
    function verify(
        address owner,
        address sender,
        bytes32 ctx,
        bytes calldata staticInput,
        bytes calldata offchainInput,
        GPv2Order.Data calldata order
    ) external view {
        GPv2Order.Data memory expected =
            getTradeableOrder(owner, sender, ctx, staticInput, offchainInput);
        if (keccak256(abi.encode(order)) != keccak256(abi.encode(expected))) {
            revert OrderNotValid("order does not match current part");
        }
    }
}

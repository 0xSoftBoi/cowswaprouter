// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ICowVaultRelayer {
    function deposit(address token, address from, uint256 amount) external;
}

interface ICowSettler {
    function settle(bytes calldata orderUid) external;
}

contract CowSwapRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable cowRelayer;
    address public immutable cowSettler;
    address public immutable owner;

    error Unauthorized();
    error SettlementFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(address _cowRelayer, address _cowSettler) {
        cowRelayer = _cowRelayer;
        cowSettler = _cowSettler;
        owner = msg.sender;
    }

    function depositAndSettle(
        address from,
        address token,
        uint256 amount,
        bytes calldata orderUid
    ) external nonReentrant onlyOwner {
        // 1. pull tokens from the user
        IERC20(token).safeTransferFrom(from, address(this), amount);

        // 2. approve(0) then approve(amount) — safe pattern for non-standard tokens
        IERC20(token).forceApprove(cowRelayer, amount);

        // 3. deposit into CoW's vault relayer
        ICowVaultRelayer(cowRelayer).deposit(token, from, amount);

        // 4. reset approval to zero — prevents cumulative approval accumulation
        IERC20(token).forceApprove(cowRelayer, 0);

        // 5. settle the order; require it succeeds if an orderUid was provided
        if (orderUid.length > 0) {
            ICowSettler(cowSettler).settle(orderUid);
        }
    }
}

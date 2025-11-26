// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface ICowVaultRelayer {
    function deposit(address token, address from, uint256 amount) external;
}

interface ICowSettler {
    function settle(bytes calldata orderUid) external;
}

contract CowSwapRouter {
    address public immutable cowRelayer;
    address public immutable cowSettler;

    constructor(address _cowRelayer, address _cowSettler) {
        cowRelayer = _cowRelayer;
        cowSettler = _cowSettler;
    }

    function depositAndSettle(
        address owner,
        address token,
        uint256 amount,
        bytes calldata orderUid
    ) external {
        // 1. take the tokens from the owner
        require(
            IERC20(token).transferFrom(owner, address(this), amount),
            "TRANSFER_FROM_FAILED"
        );

        // 2. approve relayer
        IERC20(token).approve(cowRelayer, amount);

        // 3. deposit into CoW's vault relayer
        ICowVaultRelayer(cowRelayer).deposit(token, owner, amount);

        // 4. optionally settle the order
        if (orderUid.length > 0) {
            ICowSettler(cowSettler).settle(orderUid);
        }
    }
}

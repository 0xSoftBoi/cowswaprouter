// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/CowSwapRouter.sol";

contract MockERC20 is IERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        require(balanceOf[from] >= amt, "BAL");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function approve(address spender, uint256 amt) external returns (bool) { return true; }
}

contract MockRelayer is ICowVaultRelayer {
    event Deposited(address token, address from, uint256 amount);

    function deposit(address token, address from, uint256 amount) external {
        emit Deposited(token, from, amount);
    }
}

contract MockSettler is ICowSettler {
    event Settled(bytes uid);
    function settle(bytes calldata orderUid) external {
        emit Settled(orderUid);
    }
}

contract CowSwapRouterTest is Test {
    CowSwapRouter router;
    MockERC20 token;
    MockRelayer relayer;
    MockSettler settler;

    address owner = address(1);

    function setUp() public {
        token = new MockERC20();
        relayer = new MockRelayer();
        settler = new MockSettler();
        router = new CowSwapRouter(address(relayer), address(settler));

        vm.prank(owner);
        token.mint(owner, 1e18);
    }

    function testDepositAndSettle() public {
        vm.prank(owner);
        token.transferFrom(owner, address(router), 0); // placeholder approve simulation

        bytes memory orderUid = bytes("UID123");

        vm.prank(owner);
        router.depositAndSettle(owner, address(token), 1e18, orderUid);

        assertEq(token.balanceOf(owner), 0);
    }
}

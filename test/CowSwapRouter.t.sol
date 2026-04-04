// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {CowSwapRouter, ICowVaultRelayer, ICowSettler} from "../src/CowSwapRouter.sol";

// ---------------------------------------------------------------------------
// Mock ERC20 — tracks allowances so approval-reset tests work correctly
// ---------------------------------------------------------------------------
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        require(balanceOf[from] >= amt, "BAL");
        require(allowance[from][msg.sender] >= amt, "ALLOWANCE");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        allowance[from][msg.sender] -= amt;
        return true;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "BAL");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

// ---------------------------------------------------------------------------
// Normal mock relayer
// ---------------------------------------------------------------------------
contract MockRelayer is ICowVaultRelayer {
    event Deposited(address token, address from, uint256 amount);

    function deposit(address token, address from, uint256 amount) external {
        emit Deposited(token, from, amount);
    }
}

// ---------------------------------------------------------------------------
// Malicious relayer — attempts reentrancy into depositAndSettle on deposit()
// ---------------------------------------------------------------------------
contract MockMaliciousRelayer is ICowVaultRelayer {
    CowSwapRouter public router;
    address public token;
    address public from;
    uint256 public amount;
    bytes public orderUid;
    bool public attacked;

    function setup(
        CowSwapRouter _router,
        address _token,
        address _from,
        uint256 _amount,
        bytes calldata _orderUid
    ) external {
        router = _router;
        token = _token;
        from = _from;
        amount = _amount;
        orderUid = _orderUid;
    }

    function deposit(address, address, uint256) external {
        if (!attacked) {
            attacked = true;
            // attempt reentrance — should revert with ReentrancyGuardReentrantCall
            router.depositAndSettle(from, token, amount, orderUid);
        }
    }
}

// ---------------------------------------------------------------------------
// Normal mock settler
// ---------------------------------------------------------------------------
contract MockSettler is ICowSettler {
    event Settled(bytes uid);

    function settle(bytes calldata orderUid) external {
        emit Settled(orderUid);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
contract CowSwapRouterTest is Test {
    CowSwapRouter router;
    MockERC20 token;
    MockRelayer relayer;
    MockSettler settler;

    address routerOwner;
    address user;

    function setUp() public {
        routerOwner = address(this); // deployer is owner
        user = address(0xBEEF);

        token = new MockERC20();
        relayer = new MockRelayer();
        settler = new MockSettler();
        router = new CowSwapRouter(address(relayer), address(settler));
    }

    // -----------------------------------------------------------------------
    // Helper: give user tokens and approval to router
    // -----------------------------------------------------------------------
    function _fundUser(uint256 amt) internal {
        token.mint(user, amt);
        vm.prank(user);
        token.approve(address(router), amt);
    }

    // -----------------------------------------------------------------------
    // Baseline: happy-path deposit + settle
    // -----------------------------------------------------------------------
    function testDepositAndSettle() public {
        _fundUser(1e18);

        bytes memory orderUid = bytes("UID123");
        router.depositAndSettle(user, address(token), 1e18, orderUid);

        assertEq(token.balanceOf(user), 0);
    }

    // -----------------------------------------------------------------------
    // Access control: non-owner reverts
    // -----------------------------------------------------------------------
    function testNonOwnerReverts() public {
        _fundUser(1e18);

        address attacker = address(0xDEAD);
        vm.prank(attacker);
        vm.expectRevert(CowSwapRouter.Unauthorized.selector);
        router.depositAndSettle(user, address(token), 1e18, bytes(""));
    }

    // -----------------------------------------------------------------------
    // Approval reset: allowance(router, relayer) == 0 after call
    // -----------------------------------------------------------------------
    function testApprovalResetAfterDeposit() public {
        _fundUser(1e18);

        router.depositAndSettle(user, address(token), 1e18, bytes(""));

        uint256 remaining = token.allowance(address(router), address(relayer));
        assertEq(remaining, 0, "approval not reset to zero");
    }

    // -----------------------------------------------------------------------
    // Reentrancy: malicious relayer reenters depositAndSettle → must revert
    // -----------------------------------------------------------------------
    function testReentrancyBlocked() public {
        // Deploy with a malicious relayer
        MockMaliciousRelayer malRelayer = new MockMaliciousRelayer();
        CowSwapRouter malRouter = new CowSwapRouter(address(malRelayer), address(settler));

        // Fund user with enough for two deposits (reentrancy would try a second)
        token.mint(user, 2e18);
        vm.prank(user);
        token.approve(address(malRouter), 2e18);

        malRelayer.setup(malRouter, address(token), user, 1e18, bytes(""));

        vm.expectRevert();
        malRouter.depositAndSettle(user, address(token), 1e18, bytes(""));
    }

    // -----------------------------------------------------------------------
    // No orderUid: settle is skipped — should not revert
    // -----------------------------------------------------------------------
    function testDepositWithoutSettle() public {
        _fundUser(1e18);
        router.depositAndSettle(user, address(token), 1e18, bytes(""));
        assertEq(token.balanceOf(user), 0);
    }
}

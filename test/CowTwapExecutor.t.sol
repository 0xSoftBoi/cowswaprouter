// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/CowTwapExecutor.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Mocks
// ─────────────────────────────────────────────────────────────────────────────

contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "BAL");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        require(balanceOf[from] >= amt, "BAL");
        require(allowance[from][msg.sender] >= amt, "ALLOW");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        allowance[from][msg.sender] -= amt;
        return true;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }
}

/// Mimics GPv2VaultRelayer: a solver settlement pulls the sell token from the executor's
/// escrow via the standing approval. (Real relayer is called by GPv2Settlement; here a
/// test acts as the "solver" and calls pull directly.)
contract MockRelayer {
    function pull(address token, address from, address to, uint256 amount) external {
        MockToken(token).transferFrom(from, to, amount);
    }
}

/// Mimics GPv2Settlement's PreSign + vaultRelayer surface (what a contract actually uses).
contract MockSettlement {
    address public vaultRelayer;
    mapping(bytes32 => bool) public presigned;
    uint256 public presignCount;

    constructor() { vaultRelayer = address(new MockRelayer()); }

    function setPreSignature(bytes calldata uid, bool signed) external {
        bytes32 k = keccak256(uid);
        bool was = presigned[k];
        presigned[k] = signed;
        if (signed && !was) presignCount++;
        if (!signed && was) presignCount--;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

contract CowTwapExecutorTest is Test {
    CowTwapExecutor public executor;
    MockToken       public token;
    MockSettlement  public settlement;

    address constant OWNER   = address(0xAA01);
    address constant KEEPER  = address(0xAA02);
    address constant STRANGER = address(0xAA03);

    uint256 constant TOTAL    = 1_000e18;
    uint256 constant SLICES   = 4;
    uint256 constant INTERVAL = 1 hours;

    function setUp() public {
        settlement = new MockSettlement();
        executor   = new CowTwapExecutor(address(settlement));
        token      = new MockToken();

        token.mint(OWNER, TOTAL * 10);
        vm.prank(OWNER);
        token.approve(address(executor), type(uint256).max);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 1: Create order
    // ─────────────────────────────────────────────────────────────────────────

    function testCreateOrder() public {
        vm.prank(OWNER);
        uint256 id = executor.createTwapOrder(address(token), TOTAL, SLICES, INTERVAL, 0);

        assertEq(id, 0, "First order should have id 0");

        ICowTwapExecutor.TwapOrder memory o = executor.getOrder(0);
        assertEq(o.owner, OWNER);
        assertEq(o.token, address(token));
        assertEq(o.totalAmount, TOTAL);
        assertEq(o.amountPerSlice, TOTAL / SLICES);
        assertEq(o.sliceCount, SLICES);
        assertEq(o.slicesExecuted, 0);
        assertEq(o.intervalSeconds, INTERVAL);
        assertEq(uint8(o.status), uint8(ICowTwapExecutor.TwapStatus.ACTIVE));

        // Full amount pulled into escrow
        assertEq(token.balanceOf(address(executor)), TOTAL);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 2: Full lifecycle — execute all slices
    // ─────────────────────────────────────────────────────────────────────────

    function testFullLifecycleExecuteAllSlices() public {
        vm.prank(OWNER);
        uint256 id = executor.createTwapOrder(address(token), TOTAL, SLICES, INTERVAL, 0);

        // Each slice has its own orderUid (distinct validTo windows), as on real CoW.
        for (uint256 i = 0; i < SLICES; i++) {
            assertTrue(executor.isSliceReady(id), "Slice should be ready");
            bytes memory uid = abi.encodePacked("slice", i);
            vm.prank(KEEPER);
            executor.executeSlice(id, uid);
            assertTrue(settlement.presigned(keccak256(uid)), "slice presigned");

            ICowTwapExecutor.TwapOrder memory o = executor.getOrder(id);
            assertEq(o.slicesExecuted, i + 1);

            if (i < SLICES - 1) {
                assertEq(uint8(o.status), uint8(ICowTwapExecutor.TwapStatus.ACTIVE));
                vm.warp(block.timestamp + INTERVAL + 1);
            } else {
                assertEq(uint8(o.status), uint8(ICowTwapExecutor.TwapStatus.COMPLETED));
            }
        }

        // One presignature authorized per slice (the contract authorizes, solvers settle).
        assertEq(settlement.presignCount(), SLICES);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 2b: a simulated solver settlement pulls exactly one slice from escrow
    // ─────────────────────────────────────────────────────────────────────────

    function testSolverFillPullsOneSlice() public {
        vm.prank(OWNER);
        uint256 id = executor.createTwapOrder(address(token), TOTAL, SLICES, INTERVAL, 0);

        bytes memory uid = hex"deadbeef";
        vm.prank(KEEPER);
        executor.executeSlice(id, uid);
        assertTrue(settlement.presigned(keccak256(uid)), "slice must be presigned");

        // The relayer (approved at creation) pulls one slice to the solver — escrow drops.
        uint256 perSlice = TOTAL / SLICES;
        uint256 escrowBefore = token.balanceOf(address(executor));
        address relayer = settlement.vaultRelayer();
        MockRelayer(relayer).pull(address(token), address(executor), address(0x5050), perSlice);

        assertEq(escrowBefore - token.balanceOf(address(executor)), perSlice, "one slice pulled");
        assertEq(token.balanceOf(address(0x5050)), perSlice);
    }

    function testRevokePresignature() public {
        vm.prank(OWNER);
        uint256 id = executor.createTwapOrder(address(token), TOTAL, SLICES, INTERVAL, 0);
        bytes memory uid = hex"deadbeef";
        vm.prank(KEEPER);
        executor.executeSlice(id, uid);
        assertTrue(settlement.presigned(keccak256(uid)));

        // Only owner can revoke; revoking un-authorizes the in-flight slice.
        vm.expectRevert();
        vm.prank(STRANGER);
        executor.revokePresignature(id, uid);

        vm.prank(OWNER);
        executor.revokePresignature(id, uid);
        assertFalse(settlement.presigned(keccak256(uid)), "slice no longer fillable");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 3: Time interval enforced
    // ─────────────────────────────────────────────────────────────────────────

    function testSliceNotReadyBeforeInterval() public {
        vm.prank(OWNER);
        uint256 id = executor.createTwapOrder(address(token), TOTAL, SLICES, INTERVAL, 0);

        // Execute first slice
        vm.prank(KEEPER);
        executor.executeSlice(id, hex"");

        // Immediately try to execute again — should fail
        assertFalse(executor.isSliceReady(id));
        vm.expectRevert();
        vm.prank(KEEPER);
        executor.executeSlice(id, hex"");

        // After interval, it should work
        vm.warp(block.timestamp + INTERVAL);
        assertTrue(executor.isSliceReady(id));
        vm.prank(KEEPER);
        executor.executeSlice(id, hex"");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 4: Anyone can execute (permissionless)
    // ─────────────────────────────────────────────────────────────────────────

    function testAnyoneCanExecuteSlice() public {
        vm.prank(OWNER);
        uint256 id = executor.createTwapOrder(address(token), TOTAL, SLICES, INTERVAL, 0);

        // STRANGER (not owner) can execute
        vm.prank(STRANGER);
        executor.executeSlice(id, hex"aabb");

        ICowTwapExecutor.TwapOrder memory o = executor.getOrder(id);
        assertEq(o.slicesExecuted, 1, "Slice should have been executed by stranger");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 5: Cancellation mid-way
    // ─────────────────────────────────────────────────────────────────────────

    function testCancelMidway() public {
        vm.prank(OWNER);
        uint256 id = executor.createTwapOrder(address(token), TOTAL, SLICES, INTERVAL, 0);

        // Execute 1 slice
        vm.prank(KEEPER);
        executor.executeSlice(id, hex"");
        vm.warp(block.timestamp + INTERVAL + 1);

        // Cancel after 1 slice — should get back 3/4 of tokens
        uint256 ownerBefore = token.balanceOf(OWNER);
        vm.prank(OWNER);
        executor.cancelTwapOrder(id);

        uint256 expectedRefund = (TOTAL / SLICES) * (SLICES - 1); // 3 slices unexecuted
        assertEq(token.balanceOf(OWNER) - ownerBefore, expectedRefund, "Refund should be 3/4 of total");
        assertEq(uint8(executor.getOrder(id).status), uint8(ICowTwapExecutor.TwapStatus.CANCELLED));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 6: Only owner can cancel
    // ─────────────────────────────────────────────────────────────────────────

    function testOnlyOwnerCanCancel() public {
        vm.prank(OWNER);
        uint256 id = executor.createTwapOrder(address(token), TOTAL, SLICES, INTERVAL, 0);

        vm.expectRevert();
        vm.prank(STRANGER);
        executor.cancelTwapOrder(id);

        // Owner can cancel
        vm.prank(OWNER);
        executor.cancelTwapOrder(id);
        assertEq(uint8(executor.getOrder(id).status), uint8(ICowTwapExecutor.TwapStatus.CANCELLED));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 7: Cannot execute on cancelled or completed order
    // ─────────────────────────────────────────────────────────────────────────

    function testCannotExecuteOnInactiveOrder() public {
        vm.prank(OWNER);
        uint256 id = executor.createTwapOrder(address(token), TOTAL, SLICES, INTERVAL, 0);

        vm.prank(OWNER);
        executor.cancelTwapOrder(id);

        vm.expectRevert();
        vm.prank(KEEPER);
        executor.executeSlice(id, hex"");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 8: Multiple independent orders
    // ─────────────────────────────────────────────────────────────────────────

    function testMultipleOrders() public {
        vm.startPrank(OWNER);
        uint256 id0 = executor.createTwapOrder(address(token), TOTAL, 2, INTERVAL, 0);
        uint256 id1 = executor.createTwapOrder(address(token), TOTAL, 3, INTERVAL * 2, 0);
        vm.stopPrank();

        assertEq(id0, 0);
        assertEq(id1, 1);
        assertEq(executor.totalOrders(), 2);

        // Execute id0 first slice
        vm.prank(KEEPER);
        executor.executeSlice(id0, hex"");
        assertEq(executor.getOrder(id0).slicesExecuted, 1);
        assertEq(executor.getOrder(id1).slicesExecuted, 0); // id1 unaffected
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 9: Validation — bad inputs revert
    // ─────────────────────────────────────────────────────────────────────────

    function testRevertOnZeroSlices() public {
        vm.prank(OWNER);
        vm.expectRevert();
        executor.createTwapOrder(address(token), TOTAL, 0, INTERVAL, 0);
    }

    function testRevertOnZeroInterval() public {
        vm.prank(OWNER);
        vm.expectRevert();
        executor.createTwapOrder(address(token), TOTAL, SLICES, 0, 0);
    }

    function testRevertOnZeroAmount() public {
        vm.prank(OWNER);
        vm.expectRevert();
        executor.createTwapOrder(address(token), 0, SLICES, INTERVAL, 0);
    }

    function testRevertOnAmountSmallerThanSlices() public {
        // 3 tokens split into 10 slices = 0 per slice
        vm.prank(OWNER);
        vm.expectRevert();
        executor.createTwapOrder(address(token), 3, 10, INTERVAL, 0);
    }
}

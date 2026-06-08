// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/CowTwapHandler.sol";

contract CowTwapHandlerTest is Test {
    CowTwapHandler h;
    IERC20  constant SELL = IERC20(address(0x5e11));
    IERC20  constant BUY  = IERC20(address(0xB111));
    address constant RECV = address(0xBEEF);

    uint256 constant T0   = 1_000_000;
    uint256 constant T    = 1 hours;
    uint256 constant PART = 100e18;
    uint256 constant LIMIT = 95e18;

    function setUp() public {
        h = new CowTwapHandler();
        vm.warp(T0);
    }

    function _data(uint256 n, uint256 t, uint256 span) internal pure returns (bytes memory) {
        return abi.encode(CowTwapHandler.TWAPData({
            sellToken: SELL, buyToken: BUY, receiver: RECV,
            partSellAmount: PART, minPartLimit: LIMIT,
            t0: T0, n: n, t: t, span: span, appData: bytes32(0)
        }));
    }

    function _order(bytes memory d) internal view returns (GPv2Order.Data memory) {
        return h.getTradeableOrder(address(0), address(0), bytes32(0), d, "");
    }

    function test_part0_atStart() public view {
        GPv2Order.Data memory o = _order(_data(4, T, 0));
        assertEq(o.sellAmount, PART);
        assertEq(o.buyAmount, LIMIT);
        assertEq(o.validTo, uint32(T0 + T));            // end of part 0's window
        assertEq(o.kind, GPv2Order.KIND_SELL);
        assertEq(address(o.sellToken), address(SELL));
        assertEq(o.receiver, RECV);
        assertFalse(o.partiallyFillable);
    }

    function test_part1_afterInterval() public {
        vm.warp(T0 + T);
        GPv2Order.Data memory o = _order(_data(4, T, 0));
        assertEq(o.validTo, uint32(T0 + 2 * T));        // moved to part 1
    }

    function test_revertBeforeStart() public {
        // a TWAP whose t0 is in the future → poll again later
        bytes memory d = abi.encode(CowTwapHandler.TWAPData({
            sellToken: SELL, buyToken: BUY, receiver: RECV,
            partSellAmount: PART, minPartLimit: LIMIT,
            t0: T0 + 5000, n: 4, t: T, span: 0, appData: bytes32(0)
        }));
        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.PollTryNextBlock.selector, "twap not started"));
        _order(d);
    }

    function test_revertAfterAllParts() public {
        vm.warp(T0 + 4 * T);                            // part index 4, n = 4 → finished
        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.OrderNotValid.selector, "twap finished"));
        _order(_data(4, T, 0));
    }

    function test_span_inAndOutOfWindow() public {
        uint256 span = 600; // 10 min trading window each hour
        // inside the window (start of part 0)
        GPv2Order.Data memory o = _order(_data(4, T, span));
        assertEq(o.validTo, uint32(T0 + span));
        // past the window within the same interval → poll next part
        vm.warp(T0 + span + 1);
        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.PollTryNextBlock.selector, "not within span"));
        _order(_data(4, T, span));
        // start of the next interval → tradeable again
        vm.warp(T0 + T);
        GPv2Order.Data memory o2 = _order(_data(4, T, span));
        assertEq(o2.validTo, uint32(T0 + T + span));
    }

    function test_validate_rejectsBadParams() public {
        // same token
        vm.expectRevert();
        h.validate(abi.encode(CowTwapHandler.TWAPData(SELL, SELL, RECV, PART, LIMIT, T0, 4, T, 0, bytes32(0))));
        // zero part amount
        vm.expectRevert();
        h.validate(abi.encode(CowTwapHandler.TWAPData(SELL, BUY, RECV, 0, LIMIT, T0, 4, T, 0, bytes32(0))));
        // n <= 1
        vm.expectRevert();
        h.validate(abi.encode(CowTwapHandler.TWAPData(SELL, BUY, RECV, PART, LIMIT, T0, 1, T, 0, bytes32(0))));
        // t == 0
        vm.expectRevert();
        h.validate(abi.encode(CowTwapHandler.TWAPData(SELL, BUY, RECV, PART, LIMIT, T0, 4, 0, 0, bytes32(0))));
        // t > 365d
        vm.expectRevert();
        h.validate(abi.encode(CowTwapHandler.TWAPData(SELL, BUY, RECV, PART, LIMIT, T0, 4, 366 days, 0, bytes32(0))));
        // span > t
        vm.expectRevert();
        h.validate(abi.encode(CowTwapHandler.TWAPData(SELL, BUY, RECV, PART, LIMIT, T0, 4, T, T + 1, bytes32(0))));
    }

    function test_verify_matchAndMismatch() public view {
        bytes memory d = _data(4, T, 0);
        GPv2Order.Data memory o = _order(d);
        // the current part verifies
        h.verify(address(0), address(0), bytes32(0), d, "", o);
        // a tampered order (extra sell amount) does not
        o.sellAmount = PART + 1;
        bool reverted;
        try h.verify(address(0), address(0), bytes32(0), d, "", o) {
            reverted = false;
        } catch {
            reverted = true;
        }
        assertTrue(reverted, "tampered order must fail verify");
    }
}

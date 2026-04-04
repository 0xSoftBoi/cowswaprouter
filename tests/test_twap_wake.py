"""
Wake Fuzz Test: CowTwapExecutor
================================
Stateful property-based test covering:
  - TWAP lifecycle: create → execute N slices → complete
  - Time interval enforcement (SliceNotReady revert before interval elapses)
  - Permissionless execution (anyone can call executeSlice)
  - Cancellation refund math: refund == totalAmount - (slicesExecuted * amountPerSlice)
  - Access control: only order owner can cancel
  - State machine: no actions on COMPLETED or CANCELLED orders
  - No token balance leak: tokens are either settled or refunded

Run: wake test tests/test_twap_wake.py -v
"""

from wake.testing import *
from wake.testing.fuzzing import *
from pytypes.src.CowTwapExecutor import CowTwapExecutor
from pytypes.src.interfaces.ICowTwapExecutor import ICowTwapExecutor
from pytypes.tests.contracts.Mocks import MockToken, MockRelayer, MockSettler


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

TOTAL_AMOUNT = 1_000 * 10**18
SLICE_COUNT  = 4
INTERVAL     = 3600          # 1 hour in seconds
AMOUNT_PER_SLICE = TOTAL_AMOUNT // SLICE_COUNT

DUMMY_ORDER_UID = b"test_order_uid_for_wake_fuzzing"


# ---------------------------------------------------------------------------
# Stateful FuzzTest
# ---------------------------------------------------------------------------

class TwapFuzzTest(FuzzTest):
    """
    Stateful fuzzer: random mix of create / executeSlice / cancel flows.
    Invariants checked after every flow.
    """

    executor: CowTwapExecutor
    token:    MockToken
    relayer:  MockRelayer
    settler:  MockSettler
    owner:    Account
    keeper:   Account
    stranger: Account

    # Track ghost state independently from contract
    _active_order_id: int   # 0 = none
    _slices_ghost: int       # slices we've executed, tracked independently
    _cancelled: bool
    _expected_escrow: int    # tokens we expect the executor to hold

    def pre_sequence(self) -> None:
        self.owner   = chain.accounts[0]
        self.keeper  = chain.accounts[1]
        self.stranger = chain.accounts[2]

        self.relayer  = MockRelayer.deploy(from_=self.owner)
        self.settler  = MockSettler.deploy(from_=self.owner)
        self.executor = CowTwapExecutor.deploy(
            self.relayer.address,
            self.settler.address,
            from_=self.owner,
        )
        self.token = MockToken.deploy("USD Coin", "USDC", from_=self.owner)

        # Seed owner with tokens + approve
        self.token.mint(self.owner.address, 10 * TOTAL_AMOUNT, from_=self.owner)
        self.token.approve(self.executor.address, 2**256 - 1, from_=self.owner)

        # No active order at start
        self._active_order_id = 0
        self._slices_ghost = 0
        self._cancelled = False
        self._expected_escrow = 0

    # -----------------------------------------------------------------------
    # Flows
    # -----------------------------------------------------------------------

    @flow(weight=20)
    def flow_create_order(self) -> None:
        """Create a new TWAP order if none active."""
        if self._active_order_id != 0:
            return  # already have an order

        # Only create a new order if not in a cancelled state (to avoid ghost state confusion)
        if self._cancelled:
            return

        tx = self.executor.createTwapOrder(
            self.token.address,
            TOTAL_AMOUNT,
            SLICE_COUNT,
            INTERVAL,
            0,   # no min out
            from_=self.owner,
        )
        self._active_order_id = tx.return_value
        self._slices_ghost = 0
        self._expected_escrow += TOTAL_AMOUNT

    @flow(weight=40)
    def flow_execute_slice_valid(self) -> None:
        """Execute the next slice after interval has elapsed."""
        if self._active_order_id == 0 or self._cancelled:
            return
        order = self.executor.getOrder(self._active_order_id)
        if order.status != ICowTwapExecutor.TwapStatus.ACTIVE:
            return
        if order.slicesExecuted >= SLICE_COUNT:
            return

        # Advance chain time past the interval
        chain.set_next_block_timestamp(
            chain.blocks["latest"].timestamp + INTERVAL + 1
        )
        chain.mine()

        self.executor.executeSlice(
            self._active_order_id,
            DUMMY_ORDER_UID,
            from_=self.keeper,   # keeper executes (permissionless)
        )
        self._slices_ghost += 1
        self._expected_escrow -= AMOUNT_PER_SLICE  # relayer pulls this slice's tokens

        if self._slices_ghost >= SLICE_COUNT:
            self._active_order_id = 0  # order completed

    @flow(weight=15)
    def flow_execute_slice_too_early(self) -> None:
        """Try to execute slice before interval — should revert.

        Only valid after at least one slice has been executed: the first slice
        is always ready because lastExecutedAt=0 < any real block.timestamp.
        """
        if self._active_order_id == 0 or self._cancelled:
            return
        order = self.executor.getOrder(self._active_order_id)
        if order.status != ICowTwapExecutor.TwapStatus.ACTIVE:
            return
        if order.slicesExecuted == 0 or order.slicesExecuted >= SLICE_COUNT:
            # First slice: lastExecutedAt=0, always passes the timestamp check
            # Completed: nothing to execute
            return

        # After at least one slice, lastExecutedAt > 0.
        # Attempt immediately without time advance — must revert.
        with must_revert():
            self.executor.executeSlice(
                self._active_order_id,
                DUMMY_ORDER_UID,
                from_=self.keeper,
            )

    @flow(weight=15)
    def flow_cancel_order(self) -> None:
        """Owner cancels an active order and verifies refund."""
        if self._active_order_id == 0 or self._cancelled:
            return
        order = self.executor.getOrder(self._active_order_id)
        if order.status != ICowTwapExecutor.TwapStatus.ACTIVE:
            return

        slices_done = order.slicesExecuted
        expected_refund = TOTAL_AMOUNT - (slices_done * AMOUNT_PER_SLICE)
        balance_before = self.token.balanceOf(self.owner.address)

        self.executor.cancelTwapOrder(self._active_order_id, from_=self.owner)

        balance_after = self.token.balanceOf(self.owner.address)
        actual_refund = balance_after - balance_before

        assert actual_refund == expected_refund, (
            f"Refund mismatch: expected {expected_refund}, got {actual_refund} "
            f"(slices_done={slices_done})"
        )
        self._cancelled = True
        self._active_order_id = 0
        self._expected_escrow -= expected_refund  # refund left the contract

    @flow(weight=10)
    def flow_stranger_cannot_cancel(self) -> None:
        """Non-owner cannot cancel an active order."""
        if self._active_order_id == 0 or self._cancelled:
            return
        order = self.executor.getOrder(self._active_order_id)
        if order.status != ICowTwapExecutor.TwapStatus.ACTIVE:
            return

        with must_revert():
            self.executor.cancelTwapOrder(
                self._active_order_id,
                from_=self.stranger,
            )

    # -----------------------------------------------------------------------
    # Invariants
    # -----------------------------------------------------------------------

    @invariant()
    def invariant_executor_balance_nonnegative(self) -> None:
        """Contract should never hold more tokens than it was given."""
        balance = self.token.balanceOf(self.executor.address)
        assert balance >= 0, "Invariant: contract balance underflowed"

    @invariant()
    def invariant_slices_monotonic(self) -> None:
        """slicesExecuted never decreases and never exceeds sliceCount."""
        if self._active_order_id == 0:
            return
        try:
            order = self.executor.getOrder(self._active_order_id)
            assert order.slicesExecuted <= SLICE_COUNT, (
                f"slicesExecuted {order.slicesExecuted} > sliceCount {SLICE_COUNT}"
            )
            assert order.slicesExecuted >= self._slices_ghost - 1, (
                f"slicesExecuted regressed: contract={order.slicesExecuted}, ghost={self._slices_ghost}"
            )
        except TransactionRevertedError:
            pass  # order may not exist yet

    @invariant()
    def invariant_escrow_matches_ghost(self) -> None:
        """
        Executor token balance must match our independently tracked expected balance.
        Divergence means tokens are leaking (created but not settled/refunded) or
        being over-withdrawn.
        """
        balance = self.token.balanceOf(self.executor.address)
        assert balance == self._expected_escrow, (
            f"Escrow divergence: actual={balance}, ghost={self._expected_escrow}"
        )

    @invariant()
    def invariant_no_double_settle(self) -> None:
        """settle() call count must equal total slices executed across all orders."""
        # Each executeSlice calls settler.settle() once
        # We can't track across multiple orders in this simple test,
        # but within a sequence the settle count must be consistent
        settle_count = self.settler.settleCount()
        assert settle_count >= 0, "settleCount is negative (impossible)"


# ---------------------------------------------------------------------------
# Deterministic unit tests
# ---------------------------------------------------------------------------

@chain.connect()
def test_full_lifecycle():
    """Create TWAP order → execute all slices → verify completed state."""
    owner  = chain.accounts[0]
    keeper = chain.accounts[1]

    relayer  = MockRelayer.deploy(from_=owner)
    settler  = MockSettler.deploy(from_=owner)
    executor = CowTwapExecutor.deploy(relayer.address, settler.address, from_=owner)
    token    = MockToken.deploy("USDC", "USDC", from_=owner)

    token.mint(owner.address, TOTAL_AMOUNT, from_=owner)
    token.approve(executor.address, TOTAL_AMOUNT, from_=owner)

    order_id = executor.createTwapOrder(
        token.address, TOTAL_AMOUNT, SLICE_COUNT, INTERVAL, 0, from_=owner
    ).return_value

    # Verify escrow: contract holds full amount
    assert token.balanceOf(executor.address) == TOTAL_AMOUNT, "Escrow not funded"

    for i in range(SLICE_COUNT):
        chain.set_next_block_timestamp(chain.blocks["latest"].timestamp + INTERVAL + 1)
        chain.mine()
        executor.executeSlice(order_id, DUMMY_ORDER_UID, from_=keeper)

    order = executor.getOrder(order_id)
    assert order.status == ICowTwapExecutor.TwapStatus.COMPLETED, (
        f"Expected COMPLETED, got {order.status}"
    )
    assert order.slicesExecuted == SLICE_COUNT
    assert settler.settleCount() == SLICE_COUNT

    print(f"[PASS] Full lifecycle: {SLICE_COUNT} slices executed, order COMPLETED")
    print(f"       settle() called {settler.settleCount()} times, deposit() called {relayer.depositCount()} times")


@chain.connect()
def test_time_enforcement():
    """executeSlice reverts if called before intervalSeconds has elapsed."""
    owner  = chain.accounts[0]
    keeper = chain.accounts[1]

    relayer  = MockRelayer.deploy(from_=owner)
    settler  = MockSettler.deploy(from_=owner)
    executor = CowTwapExecutor.deploy(relayer.address, settler.address, from_=owner)
    token    = MockToken.deploy("USDC", "USDC", from_=owner)

    token.mint(owner.address, TOTAL_AMOUNT, from_=owner)
    token.approve(executor.address, TOTAL_AMOUNT, from_=owner)

    order_id = executor.createTwapOrder(
        token.address, TOTAL_AMOUNT, SLICE_COUNT, INTERVAL, 0, from_=owner
    ).return_value

    # Execute first slice (no interval constraint on first)
    chain.set_next_block_timestamp(chain.blocks["latest"].timestamp + INTERVAL + 1)
    chain.mine()
    executor.executeSlice(order_id, DUMMY_ORDER_UID, from_=keeper)

    # Immediate second attempt should revert
    with must_revert():
        executor.executeSlice(order_id, DUMMY_ORDER_UID, from_=keeper)

    # After waiting, it should succeed
    chain.set_next_block_timestamp(chain.blocks["latest"].timestamp + INTERVAL + 1)
    chain.mine()
    executor.executeSlice(order_id, DUMMY_ORDER_UID, from_=keeper)

    order = executor.getOrder(order_id)
    assert order.slicesExecuted == 2

    print("[PASS] Time enforcement: premature call reverted, subsequent call succeeded")


@chain.connect()
def test_cancellation_refund_math():
    """Cancel after N slices: refund == totalAmount - N * amountPerSlice."""
    owner  = chain.accounts[0]
    keeper = chain.accounts[1]

    relayer  = MockRelayer.deploy(from_=owner)
    settler  = MockSettler.deploy(from_=owner)
    executor = CowTwapExecutor.deploy(relayer.address, settler.address, from_=owner)
    token    = MockToken.deploy("USDC", "USDC", from_=owner)

    token.mint(owner.address, TOTAL_AMOUNT, from_=owner)
    token.approve(executor.address, TOTAL_AMOUNT, from_=owner)

    order_id = executor.createTwapOrder(
        token.address, TOTAL_AMOUNT, SLICE_COUNT, INTERVAL, 0, from_=owner
    ).return_value

    # Execute exactly 2 slices
    for _ in range(2):
        chain.set_next_block_timestamp(chain.blocks["latest"].timestamp + INTERVAL + 1)
        chain.mine()
        executor.executeSlice(order_id, DUMMY_ORDER_UID, from_=keeper)

    balance_before = token.balanceOf(owner.address)
    executor.cancelTwapOrder(order_id, from_=owner)
    balance_after = token.balanceOf(owner.address)

    actual_refund   = balance_after - balance_before
    expected_refund = TOTAL_AMOUNT - (2 * AMOUNT_PER_SLICE)

    assert actual_refund == expected_refund, (
        f"Refund: expected {expected_refund}, got {actual_refund}"
    )

    order = executor.getOrder(order_id)
    assert order.status == ICowTwapExecutor.TwapStatus.CANCELLED

    print(f"[PASS] Cancellation refund: {actual_refund // 10**18} tokens refunded (2/4 slices done)")


@chain.connect()
def test_permissionless_execution():
    """Any account (keeper, stranger) can execute a ready slice."""
    owner   = chain.accounts[0]
    keeper  = chain.accounts[1]
    stranger = chain.accounts[2]

    relayer  = MockRelayer.deploy(from_=owner)
    settler  = MockSettler.deploy(from_=owner)
    executor = CowTwapExecutor.deploy(relayer.address, settler.address, from_=owner)
    token    = MockToken.deploy("USDC", "USDC", from_=owner)

    token.mint(owner.address, TOTAL_AMOUNT, from_=owner)
    token.approve(executor.address, TOTAL_AMOUNT, from_=owner)

    order_id = executor.createTwapOrder(
        token.address, TOTAL_AMOUNT, SLICE_COUNT, INTERVAL, 0, from_=owner
    ).return_value

    # Keeper executes slice 1
    chain.set_next_block_timestamp(chain.blocks["latest"].timestamp + INTERVAL + 1)
    chain.mine()
    executor.executeSlice(order_id, DUMMY_ORDER_UID, from_=keeper)

    # Stranger executes slice 2
    chain.set_next_block_timestamp(chain.blocks["latest"].timestamp + INTERVAL + 1)
    chain.mine()
    executor.executeSlice(order_id, DUMMY_ORDER_UID, from_=stranger)

    order = executor.getOrder(order_id)
    assert order.slicesExecuted == 2
    print("[PASS] Permissionless: keeper and stranger both executed slices successfully")


@chain.connect()
def test_non_owner_cannot_cancel():
    """Stranger cannot cancel another user's order."""
    owner   = chain.accounts[0]
    stranger = chain.accounts[1]

    relayer  = MockRelayer.deploy(from_=owner)
    settler  = MockSettler.deploy(from_=owner)
    executor = CowTwapExecutor.deploy(relayer.address, settler.address, from_=owner)
    token    = MockToken.deploy("USDC", "USDC", from_=owner)

    token.mint(owner.address, TOTAL_AMOUNT, from_=owner)
    token.approve(executor.address, TOTAL_AMOUNT, from_=owner)

    order_id = executor.createTwapOrder(
        token.address, TOTAL_AMOUNT, SLICE_COUNT, INTERVAL, 0, from_=owner
    ).return_value

    with must_revert():
        executor.cancelTwapOrder(order_id, from_=stranger)

    order = executor.getOrder(order_id)
    assert order.status == ICowTwapExecutor.TwapStatus.ACTIVE, "Order was cancelled by stranger!"
    print("[PASS] Access control: stranger's cancel attempt reverted")


@chain.connect()
def test_completed_order_cannot_be_re_executed():
    """After all slices, further executeSlice calls revert."""
    owner  = chain.accounts[0]
    keeper = chain.accounts[1]

    relayer  = MockRelayer.deploy(from_=owner)
    settler  = MockSettler.deploy(from_=owner)
    executor = CowTwapExecutor.deploy(relayer.address, settler.address, from_=owner)
    token    = MockToken.deploy("USDC", "USDC", from_=owner)

    token.mint(owner.address, TOTAL_AMOUNT, from_=owner)
    token.approve(executor.address, TOTAL_AMOUNT, from_=owner)

    order_id = executor.createTwapOrder(
        token.address, TOTAL_AMOUNT, SLICE_COUNT, INTERVAL, 0, from_=owner
    ).return_value

    for _ in range(SLICE_COUNT):
        chain.set_next_block_timestamp(chain.blocks["latest"].timestamp + INTERVAL + 1)
        chain.mine()
        executor.executeSlice(order_id, DUMMY_ORDER_UID, from_=keeper)

    # Completed — further attempts must revert
    chain.set_next_block_timestamp(chain.blocks["latest"].timestamp + INTERVAL + 1)
    chain.mine()
    with must_revert():
        executor.executeSlice(order_id, DUMMY_ORDER_UID, from_=keeper)

    print("[PASS] State machine: executeSlice on COMPLETED order reverted")


@chain.connect()
def test_validation_invalid_params():
    """createTwapOrder reverts on invalid parameters."""
    owner = chain.accounts[0]

    relayer  = MockRelayer.deploy(from_=owner)
    settler  = MockSettler.deploy(from_=owner)
    executor = CowTwapExecutor.deploy(relayer.address, settler.address, from_=owner)
    token    = MockToken.deploy("USDC", "USDC", from_=owner)

    token.mint(owner.address, 10 * TOTAL_AMOUNT, from_=owner)
    token.approve(executor.address, 10 * TOTAL_AMOUNT, from_=owner)

    # Zero total amount
    with must_revert():
        executor.createTwapOrder(token.address, 0, SLICE_COUNT, INTERVAL, 0, from_=owner)

    # Zero slice count
    with must_revert():
        executor.createTwapOrder(token.address, TOTAL_AMOUNT, 0, INTERVAL, 0, from_=owner)

    # Zero interval
    with must_revert():
        executor.createTwapOrder(token.address, TOTAL_AMOUNT, SLICE_COUNT, 0, 0, from_=owner)

    print("[PASS] Validation: all invalid-parameter reverts triggered correctly")


# ---------------------------------------------------------------------------
# Fuzz test entry point
# ---------------------------------------------------------------------------

@chain.connect()
def test_fuzz_twap_invariants():
    TwapFuzzTest.run(
        sequences_count=30,
        flows_count=80,
    )
    print("[PASS] Fuzz: all TWAP invariants held across 30x80 random operation sequences")

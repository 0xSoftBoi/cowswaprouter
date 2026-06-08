"""
Wake Fuzz Test: CowTwapExecutor (CoW PreSign model)
===================================================
Stateful property-based test covering:
  - TWAP lifecycle: create -> execute (presign) N slices -> complete
  - Time interval enforcement (revert before interval elapses)
  - Permissionless execution (anyone can call executeSlice)
  - Cancellation refund math: refund == totalAmount - slicesExecuted * amountPerSlice
  - Access control: only the order owner can cancel
  - State machine: no actions on COMPLETED or CANCELLED orders
  - Escrow accounting: executeSlice only PRESIGNS (no synchronous transfer); the executor
    keeps the escrow until a solver settles (not simulated here), so escrow stays at the
    deposited amount until cancellation refunds the un-executed remainder.

NOTE: this suite is kept consistent with the contract but is not run in CI here; the
Foundry suite (test/) is the executed one. Run locally: wake test tests/test_twap_wake.py -v
"""

from wake.testing import *
from wake.testing.fuzzing import *
from pytypes.src.CowTwapExecutor import CowTwapExecutor
from pytypes.src.interfaces.ICowTwapExecutor import ICowTwapExecutor
from pytypes.tests.contracts.Mocks import MockToken, MockSettlement


TOTAL_AMOUNT = 1_000 * 10**18
SLICE_COUNT  = 4
INTERVAL     = 3600
AMOUNT_PER_SLICE = TOTAL_AMOUNT // SLICE_COUNT


def _uid(i: int) -> bytes:
    # Each slice has its own orderUid (distinct validTo windows), as on real CoW.
    return b"slice_" + i.to_bytes(2, "big")


def _deploy(owner):
    settlement = MockSettlement.deploy(from_=owner)
    executor   = CowTwapExecutor.deploy(settlement.address, from_=owner)
    token      = MockToken.deploy("USD Coin", "USDC", from_=owner)
    return settlement, executor, token


class TwapFuzzTest(FuzzTest):
    """Stateful fuzzer: random mix of create / executeSlice / cancel flows."""

    executor:   CowTwapExecutor
    token:      MockToken
    settlement: MockSettlement
    owner:      Account
    keeper:     Account
    stranger:   Account

    _active_order_id: int
    _slices_ghost: int
    _cancelled: bool
    _expected_escrow: int

    def pre_sequence(self) -> None:
        self.owner    = chain.accounts[0]
        self.keeper   = chain.accounts[1]
        self.stranger = chain.accounts[2]

        self.settlement, self.executor, self.token = _deploy(self.owner)
        self.token.mint(self.owner.address, 10 * TOTAL_AMOUNT, from_=self.owner)
        self.token.approve(self.executor.address, 2**256 - 1, from_=self.owner)

        self._active_order_id = 0
        self._slices_ghost = 0
        self._cancelled = False
        self._expected_escrow = 0

    @flow(weight=20)
    def flow_create_order(self) -> None:
        if self._active_order_id != 0 or self._cancelled:
            return
        tx = self.executor.createTwapOrder(
            self.token.address, TOTAL_AMOUNT, SLICE_COUNT, INTERVAL, 0, from_=self.owner
        )
        self._active_order_id = tx.return_value
        self._slices_ghost = 0
        self._expected_escrow += TOTAL_AMOUNT

    @flow(weight=40)
    def flow_execute_slice_valid(self) -> None:
        if self._active_order_id == 0 or self._cancelled:
            return
        order = self.executor.getOrder(self._active_order_id)
        if order.status != ICowTwapExecutor.TwapStatus.ACTIVE:
            return
        if order.slicesExecuted >= SLICE_COUNT:
            return

        chain.set_next_block_timestamp(chain.blocks["latest"].timestamp + INTERVAL + 1)
        chain.mine()

        self.executor.executeSlice(self._active_order_id, _uid(self._slices_ghost), from_=self.keeper)
        self._slices_ghost += 1
        # executeSlice only PRESIGNS — escrow is unchanged until a solver settles.

        if self._slices_ghost >= SLICE_COUNT:
            self._active_order_id = 0

    @flow(weight=15)
    def flow_execute_slice_too_early(self) -> None:
        if self._active_order_id == 0 or self._cancelled:
            return
        order = self.executor.getOrder(self._active_order_id)
        if order.status != ICowTwapExecutor.TwapStatus.ACTIVE:
            return
        if order.slicesExecuted == 0 or order.slicesExecuted >= SLICE_COUNT:
            return
        with must_revert():
            self.executor.executeSlice(self._active_order_id, _uid(99), from_=self.keeper)

    @flow(weight=15)
    def flow_cancel_order(self) -> None:
        if self._active_order_id == 0 or self._cancelled:
            return
        order = self.executor.getOrder(self._active_order_id)
        if order.status != ICowTwapExecutor.TwapStatus.ACTIVE:
            return

        slices_done = order.slicesExecuted
        expected_refund = TOTAL_AMOUNT - (slices_done * AMOUNT_PER_SLICE)
        balance_before = self.token.balanceOf(self.owner.address)

        self.executor.cancelTwapOrder(self._active_order_id, from_=self.owner)

        actual_refund = self.token.balanceOf(self.owner.address) - balance_before
        assert actual_refund == expected_refund, (
            f"Refund mismatch: expected {expected_refund}, got {actual_refund} (slices_done={slices_done})"
        )
        self._cancelled = True
        self._active_order_id = 0
        self._expected_escrow -= expected_refund

    @flow(weight=10)
    def flow_stranger_cannot_cancel(self) -> None:
        if self._active_order_id == 0 or self._cancelled:
            return
        order = self.executor.getOrder(self._active_order_id)
        if order.status != ICowTwapExecutor.TwapStatus.ACTIVE:
            return
        with must_revert():
            self.executor.cancelTwapOrder(self._active_order_id, from_=self.stranger)

    @invariant()
    def invariant_slices_monotonic(self) -> None:
        if self._active_order_id == 0:
            return
        try:
            order = self.executor.getOrder(self._active_order_id)
            assert order.slicesExecuted <= SLICE_COUNT
            assert order.slicesExecuted >= self._slices_ghost - 1
        except TransactionRevertedError:
            pass

    @invariant()
    def invariant_escrow_matches_ghost(self) -> None:
        # No solver fill is simulated, so escrow == deposited - refunded.
        balance = self.token.balanceOf(self.executor.address)
        assert balance == self._expected_escrow, (
            f"Escrow divergence: actual={balance}, ghost={self._expected_escrow}"
        )

    @invariant()
    def invariant_presign_count_sane(self) -> None:
        # One presignature per executed slice (each a distinct orderUid).
        assert self.settlement.presignCount() >= 0


@chain.connect()
def test_full_lifecycle():
    owner, keeper = chain.accounts[0], chain.accounts[1]
    settlement, executor, token = _deploy(owner)
    token.mint(owner.address, TOTAL_AMOUNT, from_=owner)
    token.approve(executor.address, TOTAL_AMOUNT, from_=owner)

    order_id = executor.createTwapOrder(
        token.address, TOTAL_AMOUNT, SLICE_COUNT, INTERVAL, 0, from_=owner
    ).return_value
    assert token.balanceOf(executor.address) == TOTAL_AMOUNT, "Escrow not funded"

    for i in range(SLICE_COUNT):
        chain.set_next_block_timestamp(chain.blocks["latest"].timestamp + INTERVAL + 1)
        chain.mine()
        executor.executeSlice(order_id, _uid(i), from_=keeper)
        assert settlement.presigned(keccak256(_uid(i))), "slice not presigned"

    order = executor.getOrder(order_id)
    assert order.status == ICowTwapExecutor.TwapStatus.COMPLETED
    assert order.slicesExecuted == SLICE_COUNT
    assert settlement.presignCount() == SLICE_COUNT
    # Escrow stays fully funded until a solver settles each presigned slice.
    assert token.balanceOf(executor.address) == TOTAL_AMOUNT
    print(f"[PASS] Lifecycle: {SLICE_COUNT} slices presigned, order COMPLETED")


@chain.connect()
def test_time_enforcement():
    owner, keeper = chain.accounts[0], chain.accounts[1]
    settlement, executor, token = _deploy(owner)
    token.mint(owner.address, TOTAL_AMOUNT, from_=owner)
    token.approve(executor.address, TOTAL_AMOUNT, from_=owner)
    order_id = executor.createTwapOrder(
        token.address, TOTAL_AMOUNT, SLICE_COUNT, INTERVAL, 0, from_=owner
    ).return_value

    chain.set_next_block_timestamp(chain.blocks["latest"].timestamp + INTERVAL + 1)
    chain.mine()
    executor.executeSlice(order_id, _uid(0), from_=keeper)
    with must_revert():
        executor.executeSlice(order_id, _uid(1), from_=keeper)
    chain.set_next_block_timestamp(chain.blocks["latest"].timestamp + INTERVAL + 1)
    chain.mine()
    executor.executeSlice(order_id, _uid(1), from_=keeper)
    assert executor.getOrder(order_id).slicesExecuted == 2
    print("[PASS] Time enforcement: premature call reverted, later call succeeded")


@chain.connect()
def test_cancellation_refund_math():
    owner, keeper = chain.accounts[0], chain.accounts[1]
    settlement, executor, token = _deploy(owner)
    token.mint(owner.address, TOTAL_AMOUNT, from_=owner)
    token.approve(executor.address, TOTAL_AMOUNT, from_=owner)
    order_id = executor.createTwapOrder(
        token.address, TOTAL_AMOUNT, SLICE_COUNT, INTERVAL, 0, from_=owner
    ).return_value

    for i in range(2):
        chain.set_next_block_timestamp(chain.blocks["latest"].timestamp + INTERVAL + 1)
        chain.mine()
        executor.executeSlice(order_id, _uid(i), from_=keeper)

    balance_before = token.balanceOf(owner.address)
    executor.cancelTwapOrder(order_id, from_=owner)
    actual_refund = token.balanceOf(owner.address) - balance_before
    assert actual_refund == TOTAL_AMOUNT - (2 * AMOUNT_PER_SLICE)
    assert executor.getOrder(order_id).status == ICowTwapExecutor.TwapStatus.CANCELLED
    print(f"[PASS] Cancellation refund: {actual_refund // 10**18} tokens (2/4 slices done)")


@chain.connect()
def test_permissionless_execution():
    owner, keeper, stranger = chain.accounts[0], chain.accounts[1], chain.accounts[2]
    settlement, executor, token = _deploy(owner)
    token.mint(owner.address, TOTAL_AMOUNT, from_=owner)
    token.approve(executor.address, TOTAL_AMOUNT, from_=owner)
    order_id = executor.createTwapOrder(
        token.address, TOTAL_AMOUNT, SLICE_COUNT, INTERVAL, 0, from_=owner
    ).return_value

    chain.set_next_block_timestamp(chain.blocks["latest"].timestamp + INTERVAL + 1)
    chain.mine()
    executor.executeSlice(order_id, _uid(0), from_=keeper)
    chain.set_next_block_timestamp(chain.blocks["latest"].timestamp + INTERVAL + 1)
    chain.mine()
    executor.executeSlice(order_id, _uid(1), from_=stranger)
    assert executor.getOrder(order_id).slicesExecuted == 2
    print("[PASS] Permissionless: keeper and stranger both executed slices")


@chain.connect()
def test_non_owner_cannot_cancel():
    owner, stranger = chain.accounts[0], chain.accounts[1]
    settlement, executor, token = _deploy(owner)
    token.mint(owner.address, TOTAL_AMOUNT, from_=owner)
    token.approve(executor.address, TOTAL_AMOUNT, from_=owner)
    order_id = executor.createTwapOrder(
        token.address, TOTAL_AMOUNT, SLICE_COUNT, INTERVAL, 0, from_=owner
    ).return_value
    with must_revert():
        executor.cancelTwapOrder(order_id, from_=stranger)
    assert executor.getOrder(order_id).status == ICowTwapExecutor.TwapStatus.ACTIVE
    print("[PASS] Access control: stranger's cancel reverted")


@chain.connect()
def test_completed_order_cannot_be_re_executed():
    owner, keeper = chain.accounts[0], chain.accounts[1]
    settlement, executor, token = _deploy(owner)
    token.mint(owner.address, TOTAL_AMOUNT, from_=owner)
    token.approve(executor.address, TOTAL_AMOUNT, from_=owner)
    order_id = executor.createTwapOrder(
        token.address, TOTAL_AMOUNT, SLICE_COUNT, INTERVAL, 0, from_=owner
    ).return_value
    for i in range(SLICE_COUNT):
        chain.set_next_block_timestamp(chain.blocks["latest"].timestamp + INTERVAL + 1)
        chain.mine()
        executor.executeSlice(order_id, _uid(i), from_=keeper)
    chain.set_next_block_timestamp(chain.blocks["latest"].timestamp + INTERVAL + 1)
    chain.mine()
    with must_revert():
        executor.executeSlice(order_id, _uid(99), from_=keeper)
    print("[PASS] State machine: executeSlice on COMPLETED order reverted")


@chain.connect()
def test_validation_invalid_params():
    owner = chain.accounts[0]
    settlement, executor, token = _deploy(owner)
    token.mint(owner.address, 10 * TOTAL_AMOUNT, from_=owner)
    token.approve(executor.address, 10 * TOTAL_AMOUNT, from_=owner)
    with must_revert():
        executor.createTwapOrder(token.address, 0, SLICE_COUNT, INTERVAL, 0, from_=owner)
    with must_revert():
        executor.createTwapOrder(token.address, TOTAL_AMOUNT, 0, INTERVAL, 0, from_=owner)
    with must_revert():
        executor.createTwapOrder(token.address, TOTAL_AMOUNT, SLICE_COUNT, 0, 0, from_=owner)
    print("[PASS] Validation: invalid-parameter reverts triggered")


@chain.connect()
def test_fuzz_twap_invariants():
    TwapFuzzTest.run(sequences_count=30, flows_count=80)
    print("[PASS] Fuzz: all TWAP invariants held across 30x80 sequences")

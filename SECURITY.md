# cowswaprouter Security Notes

## Architecture

`CowTwapExecutor` is an escrow contract that holds tokens and submits them to CoW Protocol in time-sliced batches. The threat model has two layers:

1. **This contract's security** — can an attacker steal escrowed funds, execute out of order, or grief users?
2. **CoW Protocol's security** — the executor inherits CoW's trust assumptions

---

## Threat Model

### 1. Keeper Front-running `executeSlice()`

`executeSlice()` is intentionally permissionless — any address can execute the next slice once the interval has elapsed. This enables keeper bots.

**Attack:** A malicious keeper could observe a pending `executeSlice()` call and front-run it with their own call containing a different (adversarial) `orderUid`.

**Mitigation:** The `orderUid` is validated by CoW's `GPv2Settlement.settle()` contract — it must correspond to a valid signed order for exactly `amountPerSlice` of `token`. A keeper cannot substitute a different order because:
- The order must be signed by the trade owner
- The amount, token, and receiver are encoded in the orderUid
- CoW's settlement contract verifies the signature

**Mechanism:** `executeSlice` authorizes the slice's order via `setPreSignature(orderUid, true)` — it does **not** call `settle` (that is `onlySolver`). A solver later fills the presigned order; the relayer pulls `amountPerSlice` from escrow, and the order's `receiver` (the TWAP owner) gets the proceeds. A keeper cannot substitute a different order: the relayer can only pull via a settlement of an order this contract presigned.

**Residual risk:** A keeper could pass an empty `orderUid`, advancing the slice counter without presigning anything — a wasted slice (no funds move). Consider requiring a non-empty `orderUid` in production.

---

### 2. TWAP Sandwich

An attacker can observe the interval pattern and sandwich each individual slice.

**Attack:** Attacker front-runs slice execution → price moves unfavorably for the slice → slice settles at bad price → attacker back-runs.

**Mitigation:** `minAmountOutPerSlice` — set this at order creation time to the minimum acceptable output per slice (e.g., 98% of current market price). CoW Protocol's solver enforces this. Empty value (0) means no protection.

**Additional mitigation from CoW:** CoW's batch auction mechanism itself reduces sandwich profitability compared to direct AMM swaps — the off-chain solver competition ensures competitive execution prices.

---

### 3. Escrow Risk

All tokens are held in the executor contract for the full order duration.

**Attack surface:** A bug in `cancelTwapOrder()` could allow unauthorized refunds or incorrect amounts.

**Mitigation:**
- `cancelTwapOrder()` is `onlyOwner` (order owner, not contract deployer)
- Refund amount is calculated as `totalAmount - (slicesExecuted * amountPerSlice)` — verified by `testCancelMidway()`
- CEI pattern: order status set to CANCELLED before token transfer

**Note:** Integer division means `amountPerSlice = totalAmount / sliceCount` floors. Dust (up to `sliceCount - 1` wei) stays in the contract indefinitely. This is a known minor issue — use `totalAmount` divisible by `sliceCount` to avoid.

**In-flight presign caveat:** `executeSlice` moves no funds — it only presigns. `cancelTwapOrder` refunds the **un-executed** remainder (`totalAmount - slicesExecuted * amountPerSlice`); the executed portion stays in escrow to back slices that were presigned and may still be filled by a solver until their order's `validTo`. To kill an in-flight slice on cancel, the owner calls `revokePresignature(orderId, orderUid)`.

---

### 4. Interval Manipulation (Time Bandit)

**Attack:** A miner/validator could manipulate `block.timestamp` to skip the interval enforcement.

**Mitigation:** `block.timestamp` manipulation is limited to ~15 seconds by Ethereum consensus rules. An interval of `>= 60 seconds` cannot be meaningfully bypassed. Intervals of 1 hour or more (typical TWAP use case) are safe.

---

### 5. CoW Protocol Trust Model

This contract trusts the canonical CoW contracts (immutable; the relayer is read from the
settlement at construction, so the two can't be mismatched):
- `GPv2VaultRelayer` (the approval target) to pull `token` only as part of a settlement of
  an order this contract presigned;
- `GPv2Settlement` to enforce each presigned `orderUid`'s terms and to keep `settle`
  `onlySolver`.

If they are malicious or compromised, this contract's guarantees are void. Official addresses:
- `GPv2Settlement`: `0x9008D19f58AAbD9eD0D60971565AA8510560ab41`
- `GPv2VaultRelayer`: `0xC92E8bdf79f0507f65a392b0ab4667716BFE0110` (same on all supported networks)

---

## Integration Testing Limitation

Full end-to-end testing requires a live CoW Protocol solver. The Foundry suite (`test/`,
the executed one) uses a mock `GPv2Settlement` (records presignatures, exposes
`vaultRelayer`) plus a **simulated solver fill** that pulls one slice from escrow via the
standing approval. It verifies: presign-per-slice, the solver-fill pulling exactly
`amountPerSlice`, state transitions, interval enforcement, access control, refund math,
`revokePresignature`, and the ComposableCoW handler's part scheduling / span / `validate` /
`verify`.

It does NOT verify (no live solver): that a CoW solver accepts/settles the order, that
`minAmountOutPerSlice` is enforced by the real settlement, or mainnet gas. The integration
*shape* now matches real CoW (correct function signatures + canonical addresses); the
prior version called mainnet-nonexistent `deposit`/`settle`.

---

## Static analysis

A prior `wake detect` run on the original contract reported no findings in
`src/CowTwapExecutor.sol` (it uses OpenZeppelin `SafeERC20` throughout). That run
**predates the PreSign rewrite** and has not been re-executed here — treat the Foundry
suite as the current source of truth.

CEI is strictly followed:
- `createTwapOrder`: records the order (effects) before pulling tokens IN + approving the relayer (interactions).
- `executeSlice`: updates all state (effects) before `setPreSignature` (interaction).
- `cancelTwapOrder`: sets status = CANCELLED (effect) before transferring the refund out (interaction).

---

## Known Limitations

| Issue | Impact | Workaround |
|---|---|---|
| Dust from integer division | Up to `sliceCount-1` wei stuck in contract | Use `totalAmount` divisible by `sliceCount` |
| `orderUid` not validated on-chain | Keeper can pass empty uid, skipping settlement | Add non-empty check if needed |
| No fee refund to keeper | Keepers pay gas with no direct reward | Run your own keeper or use a keeper network |
| No partial slice support | Slices must be equal size | Pre-calculate optimal `totalAmount` |

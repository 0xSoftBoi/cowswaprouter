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

**Residual risk:** A keeper could pass an empty `orderUid` (skipping settlement while still advancing the slice counter). This would deposit tokens into CoW's vault without settling, potentially leaving them in limbo. Consider requiring non-empty `orderUid` in production deployments.

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

---

### 4. Interval Manipulation (Time Bandit)

**Attack:** A miner/validator could manipulate `block.timestamp` to skip the interval enforcement.

**Mitigation:** `block.timestamp` manipulation is limited to ~15 seconds by Ethereum consensus rules. An interval of `>= 60 seconds` cannot be meaningfully bypassed. Intervals of 1 hour or more (typical TWAP use case) are safe.

---

### 5. CoW Protocol Trust Model

This contract trusts:
- `cowRelayer` to correctly handle the `deposit()` call
- `cowSettler` to correctly enforce the `orderUid` terms

Both are immutable addresses set at construction time. If they are malicious or compromised, this contract's guarantees are void. Use CoW's official deployed addresses:
- `GPv2VaultRelayer`: [see CoW docs for per-network address]
- `GPv2Settlement`: `0x9008D19f58AAbD9eD0D60971565AA8510560ab41` (same on all supported networks)

---

## Integration Testing Limitation

Full end-to-end testing requires a live CoW Protocol solver generating valid `orderUid` values. Unit tests use mock relayer and settler contracts that accept any input. The mock tests verify:
- State machine transitions (ACTIVE → COMPLETED/CANCELLED)
- Time interval enforcement
- Access control
- Refund math

They do NOT verify:
- That a CoW solver will accept the order
- That `minAmountOutPerSlice` is enforced by the real settler
- Gas costs on mainnet

---

## Wake Static Analysis Results

Analyzed with `wake detect all --min-impact medium` on `src/CowTwapExecutor.sol`:

**Result: No findings in `src/CowTwapExecutor.sol`.**

The contract uses OpenZeppelin's `SafeERC20.safeTransferFrom` and `forceApprove` throughout — Wake's `unsafe-erc20-call` detector found no issues in the production contract. The only detector hits were in `tests/contracts/Mocks.sol` (a raw `IERC20.transferFrom` in the mock relayer — expected for test infrastructure).

CEI pattern is strictly followed:
- `createTwapOrder`: transfers tokens IN first (interaction), then records order (effect)
- `executeSlice`: updates all state (effects) before calling relayer/settler (interactions)
- `cancelTwapOrder`: sets status = CANCELLED (effect) before transferring refund out (interaction)

---

## Known Limitations

| Issue | Impact | Workaround |
|---|---|---|
| Dust from integer division | Up to `sliceCount-1` wei stuck in contract | Use `totalAmount` divisible by `sliceCount` |
| `orderUid` not validated on-chain | Keeper can pass empty uid, skipping settlement | Add non-empty check if needed |
| No fee refund to keeper | Keepers pay gas with no direct reward | Run your own keeper or use a keeper network |
| No partial slice support | Slices must be equal size | Pre-calculate optimal `totalAmount` |

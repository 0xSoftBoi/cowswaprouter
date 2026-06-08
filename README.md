# cowswaprouter

TWAP order execution on [CoW Protocol](https://docs.cow.fi/), in Solidity. Split a large
sell order into N time-sliced parts to reduce price impact — settled through CoW's batch
auction, where solvers compete and every order in a batch clears at a **uniform price**.

Two ways to do it, both here:

- **`CowTwapExecutor`** — a self-hosted executor. Escrow the full amount, then on a timer
  authorize each slice's CoW order via the **PreSign** scheme (`setPreSignature`). Solvers
  fill the slices; the vault relayer pulls funds during settlement.
- **`CowTwapHandler`** — the official-framework path: a [ComposableCoW](https://docs.cow.fi/cow-protocol/reference/contracts/periphery/composable-cow)
  `IConditionalOrder`. Register one conditional order; CoW's *watchtower* calls
  `getTradeableOrder()` each block to get the part valid now, and the settlement contract
  calls `verify()` so a solver can only fill the part the handler currently authorizes —
  **validated discretization**, on-chain cancellation, no custom keeper.

How they relate, and why I rewrote the executor's CoW integration (it previously called
mainnet-nonexistent `deposit`/`settle` functions): [the write-up](https://0xsoftboi.github.io/blog/how-cow-protocol-settles/).

## How CoW actually settles (the model these contracts target)

- Orders are **intents**, not swaps. You sign/authorize "sell ≤ X for ≥ Y by time T"; a
  solver settles a whole batch. There is no on-chain swap to front-run within a batch —
  everyone trading a pair clears at the same price (uniform clearing price = MEV protection
  at the batch level; each slice still sets `minAmountOutPerSlice` for its own limit).
- You approve the **`GPv2VaultRelayer`** (`0xC92E…0110`), not the settlement contract; the
  relayer pulls funds only as part of a settlement of an order you authorized.
- A contract authorizes an order via **`setPreSignature(orderUid, true)`** or ERC-1271 —
  `settle()` is `onlySolver`, so a normal contract never calls it. `CowTwapExecutor`
  presigns; it does not (and cannot) settle.

## Stack

- Solidity `^0.8.20`, [Foundry](https://book.getfoundry.sh/).
- Optional: a [Wake](https://getwake.io/) stateful fuzz suite under `tests/`
  (kept consistent with the contracts; the Foundry suite in `test/` is the executed one).

## Build & test

```bash
forge build
forge test -vv     # 26 tests: executor (presign + simulated solver fill), handler, legacy
```

## Deploy

```bash
# TWAP executor — pass the GPv2Settlement address; the vault relayer is read from it.
forge create src/CowTwapExecutor.sol:CowTwapExecutor \
  --constructor-args 0x9008D19f58AAbD9eD0D60971565AA8510560ab41   # mainnet GPv2Settlement

# ComposableCoW TWAP handler — stateless; register it as a conditional-order handler.
forge create src/CowTwapHandler.sol:CowTwapHandler
```

`src/legacy/CowSwapRouter.sol` is a **deprecated** single-shot deposit-and-settle sketch
kept for reference (it targets a simplified interface, not the real protocol).

## Security

Not audited; educational. The presign/handler logic is verified on-chain against faithful
mocks (no live solver). See [SECURITY.md](SECURITY.md) for the threat model, the dust /
in-flight-presign caveats, and the MEV protection's exact scope.

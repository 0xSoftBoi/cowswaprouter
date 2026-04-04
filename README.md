# cowswaprouter

CoW Protocol order routing in Solidity. Deposits tokens into the CoW vault relayer, approves the relayer to pull funds, and triggers batch auction settlement — all in a single transaction. MEV-protected by design: orders settle through CoW Protocol's batch auction rather than directly through an AMM, so there's no on-chain price exposure for front-runners to exploit.

## Stack

- Solidity `^0.8.20`
- [Foundry](https://book.getfoundry.sh/)

## Build

```bash
forge build
```

## Test

```bash
forge test -vv
```

## Deploy

```bash
forge create src/cowrouter.sol:CowSwapRouter \
  --constructor-args <relayer_address> <settler_address>
```

- `<relayer_address>` — CoW Protocol vault relayer (`GPv2VaultRelayer`)
- `<settler_address>` — CoW Protocol settlement contract (`GPv2Settlement`)

## How it works

`depositAndSettle(owner, token, amount, orderUid)` does four things in sequence:

1. **Pull tokens** — calls `transferFrom(owner, router, amount)` to bring the tokens on-chain into the router.
2. **Approve relayer** — calls `approve(cowRelayer, amount)` so the CoW vault relayer can move the tokens.
3. **Deposit** — calls `ICowVaultRelayer.deposit(token, owner, amount)`, registering the funds with CoW's settlement infrastructure.
4. **Settle** — if `orderUid` is non-empty, calls `ICowSettler.settle(orderUid)` to finalize the batch auction order.

The `orderUid` parameter is optional — pass an empty bytes value to skip settlement and leave the order pending in the CoW batch queue.

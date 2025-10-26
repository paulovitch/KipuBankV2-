# KipuBankV2

A production-leaning, multi-asset vault (ETH + ERC-20) with USD(6)-denominated accounting using Chainlink price feeds. Applies secure Solidity patterns (CEI, ReentrancyGuard, SafeERC20, AccessControl), custom errors, and clear eventing.

---

## 1) High-level Overview

- **Why**: Enforce vault limits in USD terms and provide safer accounting for ETH/ERC-20 deposits/withdrawals.
- **What**: Users can deposit/withdraw ETH or ERC-20; the contract converts amounts to USD(6) via Chainlink to enforce:
  - Global bank cap (`bankCapUsd6`)
  - Per-transaction withdraw cap (`withdrawPerTxCapUsd6`)
- **How**: Chainlink Aggregator feeds (ETH and per-token), nested mappings for balances, CEI pattern, `nonReentrant`, and `SafeERC20`.

---

## 2) Feature Checklist (course requirements)

- **Access Control** using OpenZeppelin:
  - Roles: `DEFAULT_ADMIN_ROLE`, `ADMIN_ROLE`
- **Type Declarations**:
  - Custom errors, events, typed storage
- **Chainlink Oracle Instance**:
  - `ETH_USD_FEED` (immutable) for ETH/USD
  - `tokenUsdFeed[token]` (mapping) for ERC-20/USD
- **Constant Variables**:
  - `USD_DECIMALS = 6`
  - `MAX_STALE_SECONDS = 0`
- **Nested Mappings**:
  - `balanceOf[user][token]` (token units)
  - `totalPerToken[token]`
- **Decimal/Value Conversion**:
  - `_decimals(token)` (default 18 if not implemented)
  - `_toUsd6(token, amount)` + `toUsd6(...)`

---

## 3) Contract

- Path: `./src/KipuBank.sol`
- Solidity: `^0.8.21`
- License: MIT

---

## 4) Deploy (example: Sepolia)

**Constructor arguments:**
- `admin`: your EOA (MetaMask)
- `bankCapUsd6_`: e.g. `1000000000` (= 1,000.000000 USD)
- `perTxCapUsd6_`: e.g. `100000000` (= 100.000000 USD)
- `ethUsdFeed`: Sepolia ETH/USD Chainlink feed `0x694AA1769357215DE4FAC081bf1f309aDC325306`

**Remix steps**
1. Environment: Injected Provider (MetaMask) on Sepolia.
2. Compile with `0.8.21` (optimizer ON or OFF — must match verification settings).
3. Deploy with the 4 constructor params (above).

---

## 5) Interaction

**ETH**
- Deposit: `depositETH()` payable (send ETH)
- Withdraw: `withdrawETH(amount)`

**ERC-20**
1. From token: `approve(KipuBank, amount)`
2. Vault: `depositERC20(token, amount)`
- Withdraw: `withdrawERC20(token, amount)`

**Admin**
- `pause()` / `unpause()`
- `setBankCapUsd6(newCap)`
- `setWithdrawPerTxCapUsd6(newCap)`
- `setTokenUsdFeed(token, feed)`

---

## 6) Design Notes / Trade-offs

- **Price freshness**: `MAX_STALE_SECONDS = 0` (no staleness enforcement yet — easy to enable later).
- **Decimals**: `_decimals(token)` tries `IERC20Metadata.decimals()` else defaults to 18.
- **ETH toggle**: if constructor sets `ETH_USD_FEED = address(0)`, ETH deposits are disabled.
- **Security**: CEI pattern, `nonReentrant`, safe ETH transfer via `call()`, and `SafeERC20` for tokens.
- **Observability**: `Deposited` and `Withdrawn` events include both token and USD6 amounts.

---

## 7) Addresses (Sepolia)

- **KipuBankV2**: `0x6325851C72cB8B7778F4e065B3c6B0123a4BA10D`
- **ETH/USD Feed**: `0x694AA1769357215DE4FAC081bf1f309aDC325306`

---

## 8) Verification (Etherscan)

- **Compiler**: `v0.8.21+commit.d9974bed`
- **Optimization**: `false` (match your deployment)
- **License**: MIT
- **Method**: “Standard JSON Input” (only `language`, `sources`, `settings`)
- **Constructor**: enable “Auto-detect” or paste ABI-encoded args

---

## 9) Security Notes

- Role-restricted admin operations (caps, feeds, pause).
- Safe transfers and nonReentrancy applied.
- Custom errors reduce gas and clarify failure reasons.

# Decentralized Stablecoin Protocol

*A Foundry-powered implementation by Varun Chauhan*

## Table of Contents

1. [Introduction](#introduction)
2. [Architecture](#architecture)
3. [Contracts](#contracts)
4. [Health Factor \& Liquidations](#health-factor--liquidations)
5. [Getting Started](#getting-started)
6. [Foundry Commands](#foundry-commands)
7. [Risk Considerations](#risk-considerations)
8. [License](#license)
9. [Author](#author)

## Introduction

This repository contains an **over-collateralized, algorithmic stablecoin protocol** designed to maintain a soft peg of **1 DSC = 1 USD**.

### Key Characteristics

- **Exogenously collateralized**: Backed by external crypto assets (e.g., WETH, WBTC)
- **200% collateral requirement**: Enforced via a 50% liquidation threshold
- **Fully on-chain \& permissionless**: No governance token, no fees
- **Built with Foundry**: For blazing-fast compilation, testing, and deployment


## Architecture

```
users deposit collateral → mint/burn DSC ← price feeds
                ↓                           ↑
        DSCEngine.sol ←→ Chainlink Oracles
        (core logic:                        
         - deposits                         
         - mint/burn    ←→ DecentralizedStableCoin.sol
         - liquidations)    (ERC20)
            ↑
        onlyOwner
```


## Contracts

### 1. DecentralizedStableCoin.sol

- **ERC-20 token contract** for DSC
- Extends OpenZeppelin's `ERC20Burnable`
- Minting/burning only callable by `DSCEngine`


### 2. DSCEngine.sol

- **Core protocol logic**
- Deposit/withdraw whitelisted collateral
- Mint/burn DSC
- Health-factor checks and liquidations


#### Constants

- `LIQUIDATION_THRESHOLD`: 50% (200% collateral requirement)
- `LIQUIDATION_BONUS`: 10% (10% discount for liquidators)
- `MIN_HEALTH_FACTOR`: 1e18 (1.0 is healthy)


## Health Factor \& Liquidations

### Health Factor Calculation

```
healthFactor = (collateralUSD * LIQUIDATION_THRESHOLD) / DSCminted
```

- **healthFactor ≥ 1**: Position is safe
- **healthFactor < 1**: Position can be liquidated


### Liquidation Process

1. **Burn** `debtToCover` amount of DSC
2. **Receive** equivalent collateral + 10% bonus
3. User's position becomes safer, protocol stays solvent

## Getting Started

### Prerequisites

- [Foundry](https://foundry.paradigm.xyz/): `curl -L https://foundry.paradigm.xyz | bash`
- Node.js 16+ (for scripts, if any)
- An RPC provider (e.g., Anvil, Hardhat node, Goerli)


### Installation

```bash
git clone https://github.com/chauhan-varun/foundry-defi-stablecoin
cd foundry-defi-stablecoin
forge install
```


### Environment Setup

Create `.env` file (see `.env.example`):

```
MAINNET_RPC_URL=
PRIVATE_KEY=
ETHERSCAN_API_KEY=
```


## Foundry Commands

### Compile

```bash
forge build
```


### Run Tests

```bash
forge test -vv
```


### Deploy Locally

```bash
# Start Anvil
anvil

# Deploy (in another terminal)
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast -vvvv
```


### Verify on Etherscan

```bash
forge verify-contract --chain-id 5 <address> src/DSCEngine.sol:DSCEngine
```


## Risk Considerations

1. **Oracle risk**: Price feed manipulation/outages
2. **Smart-contract risk**: Undetected bugs
3. **Collateral volatility**: Sharp price drops may trigger mass liquidations
4. **Liquidity risk**: Ability to swap DSC/collateral on secondary markets

**⚠️ Important**: Users should maintain health factor well above 1.0 and monitor collateral prices.

## License

MIT © 2025 Varun Chauhan

## Author

**Varun Chauhan**

- Twitter: [@varunchauhanx](https://twitter.com/varunchauhanx)
- LinkedIn: [chauhan-varun](https://linkedin.com/in/chauhan-varun)

Feel free to open issues or PRs - contributions are welcome!
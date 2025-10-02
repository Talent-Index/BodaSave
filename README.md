# Save Na Boda

A blockchain platform that partners with lenders to make motorbike financing fair, transparent, and empowering. Built with Scaffold-ETH.

Live Demo: https://rad-rolypoly-9c3f5f.netlify.app/

## Overview

In Kenya, over 1.2M boda-boda riders rely on loans to own their motorcycles. Many face predatory lenders, hidden charges, and repossessions.

SavenaBoda solves this by:
- Creating transparent repayment schedules on smart contracts.
- Splitting each payment into loan repayment + rider savings.
- Using savings as collateral for future loans.
- Building an on-chain credit history riders can take anywhere.

## Tech stack

- Scaffold-ETH 2 – development framework.
- Solidity / Foundry – smart contracts.
- React + Next.js – frontend.
- TailwindCSS – styling.
- MockUSDC.sol – a mock stablecoin for demo transactions.

## Smart Contracts

- BodaSavings.sol – manages loan repayment, savings wallet, and collateralization.
- MockUSDC.sol – test stablecoin to simulate USDC for repayments.

## Core Flow:

- Register Rider – rider joins the system.
- Deposit (Repayment) – rider pays in MockUSDC.
- Auto-splits into loanRepayment + savingsWallet.
- Track Progress – riders and lenders see transparent repayment status.
- Collateral Savings – savings can be used to support new loans.

## Installation & Setup

1. Clone Scaffold-ETH 2

```
git clone https://github.com/Talent-Index/BodaSave
cd BodaSave
```

2. Install Dependencies
   
```
curl -L https://foundry.paradigm.xyz | bash
foundryup
forge install
```

3. Build Contract

```
forge build
```

4. Start localchain

```
anvil
```

5. Deploy Contracts 

```
forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast
```

6. Start Frontend
   
```
yarn start
```

Now open http://localhost:3000

## Demo Instructions

1. Start anvil (local blockchain).
2. Deploy contracts with Foundry script.
3. Use the frontend to:
- Register a rider.
- Mint MockUSDC (test tokens).
- Deposit repayment → see auto-split into loan & savings.
- Track rider savings wallet & loan status.

## Why This Matters

- Riders → Fair loans, savings safety net, and credit history.
- Lenders → Lower default risk, transparent repayments, stronger customer trust.
- Community → More ownership, less exploitation.

## Screenshots

<img width="1366" height="768" alt="image" src="https://github.com/user-attachments/assets/c01f3024-a977-4cf8-b389-a01111c0aa21" />



## Future Work

- Integrate with real USDC stablecoin on Celo/Polygon.
- Partner with SACCOs & lenders to onboard riders.
- Add mobile-friendly UI for boda riders.
- Insurance integration (accident cover + income protection).

## Acknowledgments

- Scaffold-ETH for the amazing dev framework.
- Mini-Hackathon mentors & community.
- Riders & SACCOs who inspired this solution.



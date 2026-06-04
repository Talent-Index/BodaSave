# 🏍️ BodaBoda Savings Platform

> **Empowering Kenyan Boda Boda Riders with Transparent, Autonomous Debt Management**

A decentralized application (dApp) that revolutionizes how boda boda riders in Kenya manage their motorcycle loans while building financial literacy through transparent, blockchain-based savings.

---

## 🎯 Problem Statement

The boda boda industry in Kenya faces critical challenges:

### For Riders:
- **Predatory Lending**: High-interest loans and hidden fees from loan sharks
- **Illegal Repossessions**: Unfair seizure of motorcycles without proper documentation
- **Financial Illiteracy**: Lack of structured savings and debt management
- **Payment Harassment**: Constant pressure from debt collectors
- **Lack of Transparency**: Unclear loan terms and payment tracking

### For Lenders (e.g., Watu, SACCOs):
- **Payment Defaults**: Difficulty tracking and collecting loan repayments
- **High Collection Costs**: Expensive field agents and enforcement
- **Risk Management**: Limited visibility into rider payment behavior
- **Trust Issues**: Disputes over payment histories

---

## 💡 Our Solution

A blockchain-based savings and loan management platform that:

✅ **Automates** loan repayments through smart contracts  
✅ **Transparently** tracks all transactions on the blockchain  
✅ **Eliminates** middlemen and loan sharks  
✅ **Builds** financial literacy through mandatory savings  
✅ **Protects** riders from illegal repossessions with immutable records  
✅ **Reduces** operational costs for lenders

### How It Works

1. **Riders deposit stablecoins** (pegged to KES/USD) into the platform
2. **Smart contracts automatically split deposits** 50/50:
   - 50% → Personal savings account (rider can withdraw anytime)
   - 50% → Loan repayment pool (accessible by lender/SACCO)
3. **All transactions recorded on-chain** for complete transparency
4. **No intermediaries** = lower costs and faster processing

---

## 🏗️ Technical Architecture

### Tech Stack

- **Smart Contracts**: Solidity ^0.8.20
- **Development Framework**: Foundry
- **Frontend**: Scaffold-ETH (Next.js + React)
- **Blockchain**: Ethereum-compatible networks (Celo, Polygon, etc.)
- **Token Standard**: ERC20 (MockUSDC for testing)

### Core Contracts

#### 1. **BodaBodaSavings.sol**
Main contract handling deposits, withdrawals, and loan pool management.

**Key Features:**
- 50/50 split mechanism for deposits
- Separate savings and loan repayment tracking
- Owner-controlled loan pool withdrawals
- Emergency recovery functions
- Event emissions for frontend integration

#### 2. **MockUSDC.sol**
Testing token simulating USDC/cUSD stablecoins.

**Key Features:**
- 6 decimal places (USDC standard)
- Public faucet for testing (1000 token limit)
- Owner-controlled minting
- ERC20 compliant

---

## 🚀 Getting Started

### Prerequisites

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Install Node.js (v18+)
# Install Yarn
npm install -g yarn
```

### Installation

```bash
# Clone the repository
git clone https://github.com/yourusername/bodaboda-savings.git
cd bodaboda-savings

# Install dependencies
yarn install

# Build smart contracts
forge build

# Run tests
forge test
```

### Deployment

#### Local Development

```bash
# Start local blockchain
anvil

# Deploy contracts (in new terminal)
forge script script/Deploy.s.sol --rpc-url localhost --broadcast

# Start frontend
cd packages/nextjs
yarn dev
```

#### Testnet Deployment (Celo Alfajores)

```bash
# Set environment variables
export PRIVATE_KEY=your_private_key
export RPC_URL=https://alfajores-forno.celo-testnet.org

# Deploy
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify
```

---

## 📖 Smart Contract Functions

### For Riders

#### `deposit(uint256 amount)`
Deposit stablecoins into the platform. Requires prior token approval.

```solidity
// Example: Deposit 100 USDC
stablecoin.approve(contractAddress, 100_000000); // 6 decimals
contract.deposit(100_000000);
```

#### `withdrawSavings(uint256 amount)`
Withdraw from your personal savings balance.

```solidity
// Withdraw 50 USDC from savings
contract.withdrawSavings(50_000000);
```

#### `getBalances(address rider)`
View savings and loan repayment balances.

```solidity
(uint256 savings, uint256 loanRepaid) = contract.getBalances(riderAddress);
```

### For Lenders (Owner Only)

#### `withdrawLoanPool(address to, uint256 amount)`
Withdraw accumulated loan repayments from the pool.

```solidity
contract.withdrawLoanPool(saccoAddress, 1000_000000);
```

#### `getAvailableLoanPool()`
Check available loan pool balance.

```solidity
uint256 available = contract.getAvailableLoanPool();
```

---

## 🔐 Security Features

- ✅ **OpenZeppelin Contracts**: Battle-tested, audited libraries
- ✅ **Access Control**: Ownable pattern for administrative functions
- ✅ **Reentrancy Protection**: Uses checks-effects-interactions pattern
- ✅ **Zero Address Checks**: Prevents accidental token burns
- ✅ **Emergency Recovery**: Owner can recover accidentally sent tokens
- ✅ **Balance Tracking**: Prevents over-withdrawal from pools

### Security Considerations

⚠️ **This is a prototype**. Before production:
1. Conduct professional smart contract audit
2. Implement multi-signature wallet for owner functions
3. Add time-locks for critical operations
4. Consider upgradeability patterns (UUPS/Transparent Proxy)
5. Implement circuit breakers/pause functionality
6. Add comprehensive access control (roles)

---

## 📊 Example Use Cases

### Case 1: New Rider Onboarding

```
1. Rider receives motorcycle from Watu (KES 150,000 loan)
2. Agrees to deposit KES 5,000/week into platform
3. Each deposit:
   - KES 2,500 → Savings (emergency fund)
   - KES 2,500 → Loan repayment
4. After 60 weeks: Loan paid + KES 150,000 saved
```

### Case 2: Transparent Loan Tracking

```
Rider: "How much have I paid?"
System: Shows on-chain transaction history
- Total deposited: KES 50,000
- Loan repaid: KES 25,000
- Savings: KES 25,000
- Remaining loan: KES 125,000
```

### Case 3: Avoiding Illegal Repossession

```
Loan shark: "You haven't paid!"
Rider: Shows blockchain proof of 20 consecutive payments
Smart contract: Immutable payment record protects rider
```

---

## 🌍 Real-World Impact

### For Riders:
- 📈 **Build Credit History**: On-chain payment records
- 💰 **Forced Savings**: Automatic wealth accumulation
- 🛡️ **Legal Protection**: Immutable payment proof
- 📱 **Mobile Access**: Manage finances via smartphone
- 🤝 **Fair Treatment**: Transparent terms and conditions

### For Lenders:
- 💸 **Lower Operating Costs**: Automated collections
- 📊 **Real-Time Tracking**: Instant payment visibility
- ⚡ **Faster Settlements**: Direct smart contract withdrawals
- 🎯 **Better Risk Assessment**: Complete payment history
- 🌐 **Scalability**: Serve more riders with less overhead

### For the Ecosystem:
- 🏦 **Financial Inclusion**: Banking the unbanked
- 💼 **Economic Growth**: Empowered micro-entrepreneurs
- 🔍 **Transparency**: Reduced corruption and exploitation
- 🌱 **Innovation**: Foundation for additional DeFi services

---

## 🛣️ Roadmap

### Phase 1: MVP (Current)
- [x] Core smart contracts
- [x] Basic frontend interface
- [x] Local testing environment
- [ ] Testnet deployment

### Phase 2: Beta Launch
- [ ] Mobile-responsive UI/UX
- [ ] M-Pesa integration (fiat on-ramp)
- [ ] Multi-language support (Swahili, English)
- [ ] Security audit
- [ ] Pilot program with 50 riders

### Phase 3: Production
- [ ] Mainnet deployment (Celo)
- [ ] Partnership with SACCOs/lenders
- [ ] Insurance integration
- [ ] Credit scoring system
- [ ] Referral rewards program

### Phase 4: Expansion
- [ ] Multi-token support (cUSD, cKES)
- [ ] Lending marketplace
- [ ] Rider reputation NFTs
- [ ] Cross-border payments
- [ ] DeFi yield farming for savings

---

## 🤝 Contributing

We welcome contributions from developers, designers, and domain experts!

```bash
# Fork the repository
# Create a feature branch
git checkout -b feature/amazing-feature

# Commit your changes
git commit -m "Add amazing feature"

# Push to branch
git push origin feature/amazing-feature

# Open a Pull Request
```

### Areas for Contribution:
- Smart contract optimization
- Frontend/UX improvements
- Mobile app development
- Security auditing
- Documentation
- Community outreach

---

## 📜 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

## 🙏 Acknowledgments

- **Boda Boda Riders**: For inspiring this solution
- **Watu & SACCOs**: For providing loan access to riders
- **Celo Foundation**: For supporting financial inclusion in Africa
- **OpenZeppelin**: For secure smart contract libraries
- **Scaffold-ETH**: For rapid dApp development tools

---



---

## ⚠️ Disclaimer

This is experimental software under active development. Use at your own risk. Not financial advice. Always do your own research (DYOR) before participating in any blockchain-based financial platform.

---

**Built with ❤️ for the Boda Boda community in Kenya**

*"Empowering riders, one block at a time"*
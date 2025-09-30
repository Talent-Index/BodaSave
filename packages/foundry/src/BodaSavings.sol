// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title BodaBodaSavings
/// @author Team
/// @notice Simple demo contract: deposit ERC20 -> split 50/50 to savings & loan credit
/// @dev For demo/prototype use only - uses MockUSDC for testing
contract BodaBodaSavings is Ownable {
    struct Rider {
        uint256 savings; // credited to savings
        uint256 loanRepaid; // credited to loan repayment
    }

    IERC20 public stablecoin; // MockUSDC instance

    mapping(address => Rider) public riders;

    uint256 public totalLoanCredits; // loan amounts credited
    uint256 public totalLoanWithdrawn; // loan amounts already withdrawn

    event Deposit(address indexed rider, uint256 amount, uint256 savingsPart, uint256 loanPart);
    event WithdrawSavings(address indexed rider, uint256 amount);
    event WithdrawLoanPool(address indexed to, uint256 amount);
    event StablecoinUpdated(address indexed oldStablecoin, address indexed newStablecoin);
    event ERC20Recovered(address indexed token, address indexed to, uint256 amount);

    /// @param _stablecoin MockUSDC contract address
    /// @param initialOwner Initial owner of the contract
    constructor(address _stablecoin, address initialOwner) Ownable(initialOwner) {
        require(_stablecoin != address(0), "Stablecoin zero address");
        stablecoin = IERC20(_stablecoin);

        // Verify the token has decimals function
        (bool success,) = _stablecoin.staticcall(abi.encodeWithSignature("decimals()"));
        require(success, "Invalid stablecoin contract");
    }

    /// @notice Deposit stablecoin (caller must approve first)
    /// @param amount Amount of stablecoin to deposit
    function deposit(uint256 amount) external {
        require(amount > 0, "Zero deposit");

        bool success = stablecoin.transferFrom(msg.sender, address(this), amount);
        require(success, "Transfer failed");

        uint256 half = amount / 2;
        uint256 loanPart = amount - half; // handle odd amounts by giving extra to loan part

        riders[msg.sender].savings += half;
        riders[msg.sender].loanRepaid += loanPart;

        totalLoanCredits += loanPart;

        emit Deposit(msg.sender, amount, half, loanPart);
    }

    /// @notice Get balances for a rider
    /// @param rider Address of the rider
    /// @return savings Savings balance of the rider
    /// @return loanRepaid Loan repayment balance of the rider
    function getBalances(address rider) external view returns (uint256 savings, uint256 loanRepaid) {
        Rider storage r = riders[rider];
        return (r.savings, r.loanRepaid);
    }

    /// @notice Rider withdraws their savings
    /// @param amount Amount to withdraw from savings
    function withdrawSavings(uint256 amount) external {
        require(amount > 0, "Zero withdraw");

        Rider storage rider = riders[msg.sender];
        require(rider.savings >= amount, "Insufficient savings");

        rider.savings -= amount;

        bool success = stablecoin.transfer(msg.sender, amount);
        require(success, "Transfer failed");

        emit WithdrawSavings(msg.sender, amount);
    }

    /// @notice Owner withdraws loan pool funds to lender/SACCO
    /// @param to Recipient address
    /// @param amount Amount to withdraw from loan pool
    function withdrawLoanPool(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Zero address recipient");

        uint256 available = totalLoanCredits - totalLoanWithdrawn;
        require(amount <= available, "Exceeds available pool");

        totalLoanWithdrawn += amount;

        bool success = stablecoin.transfer(to, amount);
        require(success, "Transfer failed");

        emit WithdrawLoanPool(to, amount);
    }

    /// @notice Available loan pool balance
    /// @return Available amount in loan pool
    function getAvailableLoanPool() external view returns (uint256) {
        return totalLoanCredits - totalLoanWithdrawn;
    }

    /// @notice Get total contract stablecoin balance
    /// @return Current stablecoin balance of this contract
    function getContractBalance() external view returns (uint256) {
        return stablecoin.balanceOf(address(this));
    }

    /// @notice Owner can change the stablecoin address (use with caution)
    /// @param _stablecoin New stablecoin address
    function setStablecoin(address _stablecoin) external onlyOwner {
        require(_stablecoin != address(0), "Stablecoin zero address");

        address oldStablecoin = address(stablecoin);
        stablecoin = IERC20(_stablecoin);

        emit StablecoinUpdated(oldStablecoin, _stablecoin);
    }

    /// @notice Emergency withdraw any ERC20 tokens (for recovery purposes)
    /// @param token Address of the token to recover
    /// @param to Recipient address
    /// @param amount Amount to recover
    function recoverERC20(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Zero address recipient");
        require(token != address(0), "Zero address token");

        // Prevent withdrawing the current stablecoin through this function
        require(token != address(stablecoin), "Use withdrawLoanPool for stablecoin");

        bool success = IERC20(token).transfer(to, amount);
        require(success, "Transfer failed");

        emit ERC20Recovered(token, to, amount);
    }
}

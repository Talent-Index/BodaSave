// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MockUSDC - simple mintable ERC20 with 6 decimals (for demo)
/// @notice Use this on local/testnet as a stand-in for USDC/cUSD
contract MockUSDC is ERC20, Ownable {
    uint8 private constant _DECIMALS = 6;

    /// @param initialSupply Initial supply to mint to deployer (scaled to 6 decimals)
    /// @param initialOwner Initial owner of the contract
    constructor(uint256 initialSupply, address initialOwner) ERC20("Mock USDC", "mUSDC") Ownable(initialOwner) {
        if (initialSupply > 0) {
            _mint(initialOwner, initialSupply);
        }
    }

    /// @notice decimals override (USDC uses 6 decimals)
    function decimals() public pure override returns (uint8) {
        return _DECIMALS;
    }

    /// @notice Owner-only mint for seeding accounts
    function ownerMint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Public faucet for demo/testing — mints to caller
    /// @dev REMOVE or restrict in production
    function faucet(uint256 amount) external {
        require(amount <= 1000 * 10 ** _DECIMALS, "Faucet limit exceeded");
        _mint(msg.sender, amount);
    }
}

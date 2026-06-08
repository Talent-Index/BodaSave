// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20}       from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Ownable}     from "@openzeppelin/contracts/access/Ownable.sol";

/// @title  MockUSDC
/// @notice Mintable ERC-20 with 6 decimals — testnet stand-in for real USDC.
///
///         Changes from v1
///         ───────────────
///         [PERMIT] Inherits ERC20Permit (EIP-2612) so BodaBodaSavings can use
///                  depositWithPermit() — one-click deposit, no separate approve tx.
///         [FIX]    Constructor closing brace was missing in original — fixed.
///
/// @dev    On Base mainnet replace this with Circle's real USDC at
///         0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 — no contract changes needed.
contract MockUSDC is ERC20, ERC20Permit, Ownable {

    uint8 private constant _DECIMALS = 6;

    // ── Faucet cap: 1 000 USDC per call ──────────────────────────────────
    uint256 private constant FAUCET_LIMIT = 1_000 * 10 ** 6;

    // ── Events ────────────────────────────────────────────────────────────
    event Faucet(address indexed to, uint256 amount);
    event OwnerMint(address indexed to, uint256 amount);

    // ── Custom errors ─────────────────────────────────────────────────────
    error MockUSDC__FaucetLimitExceeded(uint256 requested, uint256 limit);
    error MockUSDC__ZeroAddress();
    error MockUSDC__ZeroAmount();

    // ─────────────────────────────────────────────────────────────────────
    //                          CONSTRUCTOR
    // ─────────────────────────────────────────────────────────────────────

    /// @param initialSupply  Tokens minted to deployer on construction (6-decimal units).
    ///                       Pass 0 to start with an empty supply.
    /// @param initialOwner   Contract owner — receives initial supply and can ownerMint.
    constructor(
        uint256 initialSupply,
        address initialOwner
    )
        ERC20("Mock USDC", "mUSDC")
        ERC20Permit("Mock USDC")          // [PERMIT] domain separator uses this name
        Ownable(initialOwner)
    {
        if (initialOwner == address(0)) revert MockUSDC__ZeroAddress();
        if (initialSupply > 0) {
            _mint(initialOwner, initialSupply);
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    //                        OVERRIDES
    // ─────────────────────────────────────────────────────────────────────

    /// @notice USDC uses 6 decimal places.
    function decimals() public pure override returns (uint8) {
        return _DECIMALS;
    }

    // ─────────────────────────────────────────────────────────────────────
    //                        MINT FUNCTIONS
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Owner mints arbitrary amount to any address — for seeding test accounts.
    /// @dev    REMOVE or gate behind a multisig in production.
    function ownerMint(address to, uint256 amount) external onlyOwner {
        if (to     == address(0)) revert MockUSDC__ZeroAddress();
        if (amount == 0)          revert MockUSDC__ZeroAmount();
        _mint(to, amount);
        emit OwnerMint(to, amount);
    }

    /// @notice Public faucet — any address can mint up to 1 000 mUSDC per call.
    /// @dev    REMOVE or restrict in production.
    /// @param  amount Amount in 6-decimal units (e.g. 100_000_000 = 100 USDC).
    function faucet(uint256 amount) external {
        if (amount == 0)              revert MockUSDC__ZeroAmount();
        if (amount > FAUCET_LIMIT)    revert MockUSDC__FaucetLimitExceeded(amount, FAUCET_LIMIT);
        _mint(msg.sender, amount);
        emit Faucet(msg.sender, amount);
    }
}

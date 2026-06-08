// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test }     from "forge-std/Test.sol";
import { MockUSDC } from "../src/MockUSDC.sol";
import { Ownable }  from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Test suite for MockUSDC v2 (ERC20Permit version).
///
///         Sections
///         ─────────
///         1. Constructor
///         2. Decimals
///         3. ownerMint
///         4. Faucet
///         5. Transfers
///         6. Permit (EIP-2612)
///         7. Fuzz
contract TestMockUSDC is Test {

    // ── Fixtures ──────────────────────────────────────────────────────
    MockUSDC mockUSDC;

    address constant OWNER   = address(0xA0);
    address constant USER    = address(0xB0);
    address constant SPENDER = address(0xC0);

    uint256 constant INITIAL_SUPPLY = 1_000_000e6;
    uint256 constant USER_BALANCE   = 500_000e6;

    // Private key used to test EIP-2612 permit signatures
    uint256 constant PERMIT_SIGNER_PK = 0xDEAD;
    address          permitSigner;          // = vm.addr(PERMIT_SIGNER_PK)

    // ── Setup ──────────────────────────────────────────────────────────

    function setUp() public {
        vm.startPrank(OWNER);
        mockUSDC = new MockUSDC(INITIAL_SUPPLY, OWNER);
        mockUSDC.ownerMint(USER, USER_BALANCE);
        vm.stopPrank();

        permitSigner = vm.addr(PERMIT_SIGNER_PK);
    }

    // ────────────────────────────────────────────────────────────────
    //                    1. CONSTRUCTOR TESTS
    // ────────────────────────────────────────────────────────────────

    function testConstructorMintsInitialSupplyToOwner() public view {
        assertEq(mockUSDC.balanceOf(OWNER), INITIAL_SUPPLY);
    }

    function testConstructorWithZeroSupplyMintsNothing() public {
        MockUSDC empty = new MockUSDC(0, OWNER);
        assertEq(empty.totalSupply(), 0);
    }

    function testConstructorRevertsIfOwnerIsZeroAddress() public {
        // OZ's Ownable fires OwnableInvalidOwner(address(0)) before our custom
        // MockUSDC__ZeroAddress check — expect the OZ error instead.
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("OwnableInvalidOwner(address)")),
                address(0)
            )
        );
        new MockUSDC(INITIAL_SUPPLY, address(0));
    }

    function testConstructorSetsCorrectNameAndSymbol() public view {
        assertEq(mockUSDC.name(),   "Mock USDC");
        assertEq(mockUSDC.symbol(), "mUSDC");
    }

    // ────────────────────────────────────────────────────────────────
    //                     2. DECIMALS TESTS
    // ────────────────────────────────────────────────────────────────

    function testDecimalsIsSix() public view {
        assertEq(mockUSDC.decimals(), 6);
    }

    // ────────────────────────────────────────────────────────────────
    //                    3. OWNER MINT TESTS
    // ────────────────────────────────────────────────────────────────

    function testOwnerMintSuccess() public {
        uint256 before = mockUSDC.balanceOf(USER);

        vm.prank(OWNER);
        mockUSDC.ownerMint(USER, 100_000e6);

        assertEq(mockUSDC.balanceOf(USER) - before, 100_000e6);
    }

    function testOwnerMintEmitsEvent() public {
        vm.prank(OWNER);
        vm.expectEmit(true, false, false, true);
        emit MockUSDC.OwnerMint(USER, 100_000e6);
        mockUSDC.ownerMint(USER, 100_000e6);
    }

    function testOwnerMintRevertsIfNotOwner() public {
        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                USER
            )
        );
        mockUSDC.ownerMint(USER, 100_000e6);
    }

    function testOwnerMintRevertsIfZeroAddress() public {
        vm.prank(OWNER);
        vm.expectRevert(MockUSDC.MockUSDC__ZeroAddress.selector);
        mockUSDC.ownerMint(address(0), 100_000e6);
    }

    function testOwnerMintRevertsIfZeroAmount() public {
        vm.prank(OWNER);
        vm.expectRevert(MockUSDC.MockUSDC__ZeroAmount.selector);
        mockUSDC.ownerMint(USER, 0);
    }

    // ────────────────────────────────────────────────────────────────
    //                     4. FAUCET TESTS
    // ────────────────────────────────────────────────────────────────

    function testFaucetSuccess() public {
        uint256 amount = 100e6;
        uint256 before = mockUSDC.balanceOf(USER);

        vm.prank(USER);
        mockUSDC.faucet(amount);

        assertEq(mockUSDC.balanceOf(USER) - before, amount);
    }

    function testFaucetEmitsEvent() public {
        vm.prank(USER);
        vm.expectEmit(true, false, false, true);
        emit MockUSDC.Faucet(USER, 100e6);
        mockUSDC.faucet(100e6);
    }

    function testFaucetRevertsIfExceedsLimit() public {
        uint256 overLimit = 1_001e6; // above 1 000 cap

        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                MockUSDC.MockUSDC__FaucetLimitExceeded.selector,
                overLimit,
                1_000e6
            )
        );
        mockUSDC.faucet(overLimit);
    }

    function testFaucetRevertsIfZeroAmount() public {
        vm.prank(USER);
        vm.expectRevert(MockUSDC.MockUSDC__ZeroAmount.selector);
        mockUSDC.faucet(0);
    }

    function testFaucetAtExactLimitSucceeds() public {
        vm.prank(USER);
        mockUSDC.faucet(1_000e6); // exactly at cap — must not revert
    }

    // ────────────────────────────────────────────────────────────────
    //                    5. TRANSFER TESTS
    // ────────────────────────────────────────────────────────────────

    function testTransferBetweenAccounts() public {
        vm.prank(USER);
        mockUSDC.transfer(SPENDER, 50_000e6);

        assertEq(mockUSDC.balanceOf(SPENDER), 50_000e6);
        assertEq(mockUSDC.balanceOf(USER),    USER_BALANCE - 50_000e6);
    }

    function testApproveAndTransferFrom() public {
        vm.prank(OWNER);
        mockUSDC.approve(USER, 10_000e6);

        vm.prank(USER);
        mockUSDC.transferFrom(OWNER, USER, 10_000e6);

        assertEq(mockUSDC.balanceOf(USER), USER_BALANCE + 10_000e6);
    }

    function testTransferRevertsIfInsufficientBalance() public {
        vm.prank(USER);
        vm.expectRevert(); // ERC20InsufficientBalance
        mockUSDC.transfer(SPENDER, USER_BALANCE + 1);
    }

    // ────────────────────────────────────────────────────────────────
    //                 6. PERMIT (EIP-2612) TESTS
    // ────────────────────────────────────────────────────────────────

    /// @dev Builds and signs an EIP-2612 permit digest using the test private key.
    function _signPermit(
        address owner_,
        address spender_,
        uint256 value_,
        uint256 nonce_,
        uint256 deadline_
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                ),
                owner_,
                spender_,
                value_,
                nonce_,
                deadline_
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", mockUSDC.DOMAIN_SEPARATOR(), structHash)
        );

        (v, r, s) = vm.sign(PERMIT_SIGNER_PK, digest);
    }

    function testPermitSetsAllowance() public {
        uint256 amount   = 500e6;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce    = mockUSDC.nonces(permitSigner);

        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(permitSigner, SPENDER, amount, nonce, deadline);

        mockUSDC.permit(permitSigner, SPENDER, amount, deadline, v, r, s);

        assertEq(mockUSDC.allowance(permitSigner, SPENDER), amount);
    }

    function testPermitRevertsIfDeadlineExpired() public {
        uint256 amount   = 500e6;
        uint256 deadline = block.timestamp - 1; // already expired
        uint256 nonce    = mockUSDC.nonces(permitSigner);

        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(permitSigner, SPENDER, amount, nonce, deadline);

        vm.expectRevert(); // ERC2612ExpiredSignature
        mockUSDC.permit(permitSigner, SPENDER, amount, deadline, v, r, s);
    }

    function testPermitRevertsIfSignerMismatch() public {
        uint256 amount   = 500e6;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce    = mockUSDC.nonces(permitSigner);

        // Signed for permitSigner but submitted with USER as owner — mismatch
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(permitSigner, SPENDER, amount, nonce, deadline);

        vm.expectRevert(); // ERC2612InvalidSigner
        mockUSDC.permit(USER, SPENDER, amount, deadline, v, r, s);
    }

    function testPermitNonceIncrementsAfterUse() public {
        uint256 amount   = 500e6;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce    = mockUSDC.nonces(permitSigner);

        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(permitSigner, SPENDER, amount, nonce, deadline);

        mockUSDC.permit(permitSigner, SPENDER, amount, deadline, v, r, s);

        assertEq(mockUSDC.nonces(permitSigner), nonce + 1);
    }

    // ────────────────────────────────────────────────────────────────
    //                      7. FUZZ TESTS
    // ────────────────────────────────────────────────────────────────

    /// @dev Any amount within faucet limit should succeed.
    function testFuzzFaucetWithinLimit(uint256 amount) public {
        amount = bound(amount, 1, 1_000e6);
        uint256 before = mockUSDC.balanceOf(USER);

        vm.prank(USER);
        mockUSDC.faucet(amount);

        assertEq(mockUSDC.balanceOf(USER) - before, amount);
    }

    /// @dev ownerMint of any nonzero amount to a nonzero address should succeed.
    function testFuzzOwnerMintAnyAmount(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);
        uint256 before = mockUSDC.balanceOf(USER);

        vm.prank(OWNER);
        mockUSDC.ownerMint(USER, amount);

        assertEq(mockUSDC.balanceOf(USER) - before, amount);
    }
}

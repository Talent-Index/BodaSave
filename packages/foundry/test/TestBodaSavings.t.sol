// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test }            from "forge-std/Test.sol";
import { BodaBodaSavings } from "../src/BodaSavings.sol";
import { MockUSDC }        from "../src/MockUSDC.sol";
import { Ownable }         from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Test suite for BodaBodaSavings V2.
///
///         Shared test setup
///         ──────────────────
///         • Three lenders registered at deployment (weekly / monthly / daily).
///         • One rider (USER) registered with full KYC against LENDER_WEEKLY.
///         • USER starts with INITIAL_BALANCE MockUSDC and has approved the contract.
///
///         Sections
///         ─────────
///         1. Constructor
///         2. Lender Management
///         3. Rider Registration & KYC
///         4. Deposit
///         5. Pot Mechanism
///         6. Savings Withdrawal Flow
///         7. Admin — pause / setStablecoin / recoverERC20
///         8. View helpers
contract TestBodaSavings is Test {

    // ────────────────────────────────────────────────────────────────
    //                        TEST FIXTURES
    // ────────────────────────────────────────────────────────────────

    BodaBodaSavings bodaSavings;
    MockUSDC        mockUSDC;

    // Actors
    address constant OWNER        = address(0xA0);
    address constant USER         = address(0xB0);   // registered, verified rider
    address constant STRANGER     = address(0xC0);   // unregistered address
    address constant NEW_LENDER   = address(0xD0);

    // Lenders registered at deployment
    address constant LENDER_WEEKLY   = address(0x1111);
    address constant LENDER_MONTHLY  = address(0x2222);
    address constant LENDER_DAILY    = address(0x3333);

    // Amounts (6-decimal USDC)
    uint256 constant INITIAL_BALANCE  = 1_000e6;
    uint256 constant LOAN_TARGET      = 5_000e6;
    uint256 constant DEPOSIT_AMOUNT   = 1_000e6;

    // KYC fixtures
    bytes32 constant KYC_HASH     = keccak256("rider_kyc_docs_hash");
    bytes32 constant KYC_PROVIDER = bytes32("SMILE_IDENTITY");
    uint256          licenseExpiry;   // set in setUp()

    // ────────────────────────────────────────────────────────────────
    //                           SET UP
    // ────────────────────────────────────────────────────────────────

    function setUp() public {
        // Warp to a realistic timestamp so licenseExpiry can be set in the future
        vm.warp(1_700_000_000);
        licenseExpiry = block.timestamp + 365 days;

        vm.startPrank(OWNER);

        // Deploy stablecoin
        mockUSDC = new MockUSDC(20_000_000e6, OWNER);

        // Build lender arrays
        address[] memory lenderAddrs = new address[](3);
        lenderAddrs[0] = LENDER_WEEKLY;
        lenderAddrs[1] = LENDER_MONTHLY;
        lenderAddrs[2] = LENDER_DAILY;

        string[] memory lenderNames = new string[](3);
        lenderNames[0] = "Mwanga Haba SACCO";
        lenderNames[1] = "Faulu MFB";
        lenderNames[2] = "Kenya Women MFI";

        uint256[] memory cycles = new uint256[](3);
        cycles[0] = 7 days;
        cycles[1] = 30 days;
        cycles[2] = 1 days;

        // Deploy V2 contract
        bodaSavings = new BodaBodaSavings(
            address(mockUSDC),
            lenderAddrs,
            lenderNames,
            cycles,
            OWNER
        );

        // Fund USER and register as a verified rider
        mockUSDC.ownerMint(USER, INITIAL_BALANCE);

        bodaSavings.registerRider(
            USER,
            LENDER_WEEKLY,
            LOAN_TARGET,
            KYC_HASH,
            bodaSavings.KYC_FULL(),
            licenseExpiry,
            KYC_PROVIDER
        );

        vm.stopPrank();

        // USER approves the contract to spend their tokens
        vm.prank(USER);
        mockUSDC.approve(address(bodaSavings), type(uint256).max);
    }

    // ────────────────────────────────────────────────────────────────
    //                     1. CONSTRUCTOR TESTS
    // ────────────────────────────────────────────────────────────────

    function testConstructorRevertsIfStablecoinZeroAddress() public {
        address[] memory addrs  = new address[](1);
        string[]  memory names  = new string[](1);
        uint256[] memory cycles = new uint256[](1);
        addrs[0]  = LENDER_WEEKLY;
        names[0]  = "Test Lender";
        cycles[0] = 7 days;

        vm.expectRevert(
            BodaBodaSavings.BodaBodaSavings__StablecoinCannotBeZeroAddress.selector
        );
        new BodaBodaSavings(address(0), addrs, names, cycles, OWNER);
    }

    function testConstructorRevertsIfNoLendersProvided() public {
        address[] memory addrs  = new address[](0);
        string[]  memory names  = new string[](0);
        uint256[] memory cycles = new uint256[](0);

        vm.expectRevert(
            BodaBodaSavings.BodaBodaSavings__NoLendersProvided.selector
        );
        new BodaBodaSavings(address(mockUSDC), addrs, names, cycles, OWNER);
    }

    function testConstructorRegistersAllLenders() public view {
        assertEq(bodaSavings.getLenderCount(), 3);
    }

    // ────────────────────────────────────────────────────────────────
    //                   2. LENDER MANAGEMENT TESTS
    // ────────────────────────────────────────────────────────────────

    function testAddLenderSuccess() public {
        vm.prank(OWNER);
        vm.expectEmit(true, false, false, true);
        emit BodaBodaSavings.LenderAdded(NEW_LENDER, "New SACCO", 14 days);
        bodaSavings.addLender(NEW_LENDER, "New SACCO", 14 days);

        assertEq(bodaSavings.getLenderCount(), 4);
        (,uint256 cycle, bool verified, bool active) = bodaSavings.getLender(NEW_LENDER);
        assertEq(cycle,    14 days);
        assertTrue(verified);
        assertTrue(active);
    }

    function testAddLenderRevertsIfAlreadyRegistered() public {
        vm.prank(OWNER);
        vm.expectRevert(
            BodaBodaSavings.BodaBodaSavings__LenderAlreadyRegistered.selector
        );
        bodaSavings.addLender(LENDER_WEEKLY, "Duplicate", 7 days);
    }

    function testAddLenderRevertsIfZeroCycle() public {
        vm.prank(OWNER);
        vm.expectRevert(
            BodaBodaSavings.BodaBodaSavings__InvalidCollectionCycle.selector
        );
        bodaSavings.addLender(NEW_LENDER, "Bad Lender", 0);
    }

    function testDeactivateAndReactivateLender() public {
        vm.startPrank(OWNER);
        bodaSavings.deactivateLender(LENDER_WEEKLY);
        (,,, bool activeBefore) = bodaSavings.getLender(LENDER_WEEKLY);
        assertFalse(activeBefore);

        bodaSavings.reactivateLender(LENDER_WEEKLY);
        (,,, bool activeAfter) = bodaSavings.getLender(LENDER_WEEKLY);
        assertTrue(activeAfter);
        vm.stopPrank();
    }

    function testUpdateLenderCycleSuccess() public {
        vm.prank(OWNER);
        bodaSavings.updateLenderCycle(LENDER_WEEKLY, 14 days);
        (, uint256 cycle,,) = bodaSavings.getLender(LENDER_WEEKLY);
        assertEq(cycle, 14 days);
    }

    function testGetLendersPagination() public view {
        // offset=0, limit=2 → first two lenders
        address[] memory page = bodaSavings.getLenders(0, 2);
        assertEq(page.length, 2);
        assertEq(page[0], LENDER_WEEKLY);
        assertEq(page[1], LENDER_MONTHLY);

        // offset=2, limit=0 → all remaining
        address[] memory rest = bodaSavings.getLenders(2, 0);
        assertEq(rest.length, 1);
        assertEq(rest[0], LENDER_DAILY);
    }

    // ────────────────────────────────────────────────────────────────
    //                3. RIDER REGISTRATION & KYC TESTS
    // ────────────────────────────────────────────────────────────────

    function testRegisterRiderSuccess() public view {
        assertTrue(bodaSavings.isVerifiedRider(USER));
    }

    function testRegisterRiderRevertsIfAlreadyRegistered() public {
        vm.prank(OWNER);
        vm.expectRevert(
            BodaBodaSavings.BodaBodaSavings__RiderAlreadyRegistered.selector
        );
        bodaSavings.registerRider(
            USER, LENDER_WEEKLY, LOAN_TARGET, KYC_HASH,
            bodaSavings.KYC_FULL(), licenseExpiry, KYC_PROVIDER
        );
    }

    function testRegisterRiderRevertsIfLenderInactive() public {
        address newRider = address(0xE0);
        vm.startPrank(OWNER);
        bodaSavings.deactivateLender(LENDER_WEEKLY);
        vm.expectRevert(
            BodaBodaSavings.BodaBodaSavings__LenderNotActive.selector
        );
        bodaSavings.registerRider(
            newRider, LENDER_WEEKLY, LOAN_TARGET, KYC_HASH,
            bodaSavings.KYC_FULL(), licenseExpiry, KYC_PROVIDER
        );
        vm.stopPrank();
    }

    function testRegisterRiderRevertsIfLicenseExpired() public {
        address newRider = address(0xF0);
        vm.prank(OWNER);
        vm.expectRevert(
            BodaBodaSavings.BodaBodaSavings__LicenseExpired.selector
        );
        bodaSavings.registerRider(
            newRider, LENDER_WEEKLY, LOAN_TARGET, KYC_HASH,
            bodaSavings.KYC_FULL(),
            block.timestamp - 1,   // expired
            KYC_PROVIDER
        );
    }

    function testUpdateRiderKYCSuccess() public {
        bytes32 newHash = keccak256("updated_kyc_docs");
        vm.prank(OWNER);
        bodaSavings.updateRiderKYC(
            USER, newHash, bodaSavings.KYC_PREMIUM(),
            licenseExpiry + 365 days, KYC_PROVIDER
        );
        (bytes32 h, uint8 lvl,,,,) = bodaSavings.getRiderKYC(USER);
        assertEq(h,   newHash);
        assertEq(lvl, bodaSavings.KYC_PREMIUM());
    }

    function testUpdateLoanTargetSuccess() public {
        vm.prank(OWNER);
        bodaSavings.updateLoanTarget(USER, 8_000e6);
        (uint256 target,,,,,) = bodaSavings.getLoanStatus(USER);
        assertEq(target, 8_000e6);
    }

    function testUpdateLoanTargetRevertsIfBelowRepaid() public {
        // First make some repayments via deposit + pot
        vm.prank(USER);
        bodaSavings.deposit(DEPOSIT_AMOUNT);

        vm.prank(USER);
        bodaSavings.lockToPot(DEPOSIT_AMOUNT / 2, 0);

        vm.prank(USER);
        bodaSavings.releaseFromPot();

        // loanRepaid = 500e6, so setting target to 100e6 should revert
        vm.prank(OWNER);
        vm.expectRevert(
            BodaBodaSavings.BodaBodaSavings__NewTargetBelowRepaid.selector
        );
        bodaSavings.updateLoanTarget(USER, 100e6);
    }

    // ────────────────────────────────────────────────────────────────
    //                       4. DEPOSIT TESTS
    // ────────────────────────────────────────────────────────────────

    function testDepositRevertsIfZero() public {
        vm.prank(USER);
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__ZeroDeposit.selector);
        bodaSavings.deposit(0);
    }

    function testDepositRevertsIfNotVerified() public {
        vm.prank(STRANGER);
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__RiderNotRegistered.selector);
        bodaSavings.deposit(100e6);
    }

    function testDepositSplits5050() public {
        vm.prank(USER);
        vm.expectEmit(true, false, false, true);
        emit BodaBodaSavings.Deposit(
            USER,
            DEPOSIT_AMOUNT,
            DEPOSIT_AMOUNT / 2,
            DEPOSIT_AMOUNT / 2,
            block.timestamp
        );
        bodaSavings.deposit(DEPOSIT_AMOUNT);

        (
            uint256 savingsBalance,
            uint256 loanBalance,
            ,,,,,,,,
        ) = bodaSavings.getRiderAnalytics(USER);

        assertEq(savingsBalance, DEPOSIT_AMOUNT / 2);
        assertEq(loanBalance,    DEPOSIT_AMOUNT / 2);
        assertEq(bodaSavings.totalLoanCredits(), DEPOSIT_AMOUNT / 2);
        assertEq(mockUSDC.balanceOf(address(bodaSavings)), DEPOSIT_AMOUNT);
    }

    function testDepositOddAmountRoundsLoanUp() public {
        // 101e6 → savings = 50.5e6 rounded down = 50e6, loan = 51e6
        uint256 odd = 101e6;
        mockUSDC.transfer(USER, odd);   // top up so USER has enough

        vm.prank(USER);
        bodaSavings.deposit(odd);

        (uint256 sav, uint256 loan,,,,,,,,, ) = bodaSavings.getRiderAnalytics(USER);
        assertEq(sav,  50e6);
        assertEq(loan, 51e6);
    }

    function testDepositTracksFirstAndLastTimestamps() public {
        uint256 t1 = block.timestamp;
        vm.prank(USER);
        bodaSavings.deposit(DEPOSIT_AMOUNT);

        vm.warp(block.timestamp + 1 days);
        uint256 t2 = block.timestamp;
        mockUSDC.transfer(USER, DEPOSIT_AMOUNT);
        vm.prank(USER);
        bodaSavings.deposit(DEPOSIT_AMOUNT);

        (,,,, , uint256 last, uint256 first,,,, ) = bodaSavings.getRiderAnalytics(USER);
        assertEq(first, t1);
        assertEq(last,  t2);
    }

    // ────────────────────────────────────────────────────────────────
    //                      5. POT MECHANISM TESTS
    // ────────────────────────────────────────────────────────────────

    function _depositAndLock(uint256 lockAmount) internal {
        vm.prank(USER);
        bodaSavings.deposit(DEPOSIT_AMOUNT);
        vm.prank(USER);
        bodaSavings.lockToPot(lockAmount, block.timestamp + 3 days);
    }

    function testLockToPotSuccess() public {
        _depositAndLock(DEPOSIT_AMOUNT / 2);

        (,,,,,,, bool potActive, uint256 potBal,,) =
            bodaSavings.getRiderAnalytics(USER);

        assertTrue(potActive);
        assertEq(potBal, DEPOSIT_AMOUNT / 2);
        assertEq(bodaSavings.getLockedPotTotal(), DEPOSIT_AMOUNT / 2);
    }

    function testLockToPotRevertsIfAlreadyActive() public {
        _depositAndLock(DEPOSIT_AMOUNT / 2);
        vm.prank(USER);
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__PotAlreadyActive.selector);
        bodaSavings.lockToPot(100e6, 0);
    }

    function testLockToPotRevertsIfInsufficientLoanBalance() public {
        vm.prank(USER);
        vm.expectRevert(
            BodaBodaSavings.BodaBodaSavings__InsufficientLoanBalance.selector
        );
        bodaSavings.lockToPot(100e6, 0);   // no deposit yet
    }

    function testReleaseFromPotSendsToLender() public {
        _depositAndLock(DEPOSIT_AMOUNT / 2);

        uint256 lenderBefore = mockUSDC.balanceOf(LENDER_WEEKLY);

        vm.prank(USER);
        bodaSavings.releaseFromPot();

        uint256 lenderAfter = mockUSDC.balanceOf(LENDER_WEEKLY);
        assertEq(lenderAfter - lenderBefore, DEPOSIT_AMOUNT / 2);

        // Pot should be cleared
        (,,,,,,, bool potActive,,,) = bodaSavings.getRiderAnalytics(USER);
        assertFalse(potActive);
        assertEq(bodaSavings.getLockedPotTotal(), 0);
    }

    function testSettleExpiredPotByAnyone() public {
        _depositAndLock(DEPOSIT_AMOUNT / 2);

        // Advance past the lender's weekly cycle
        vm.warp(block.timestamp + 7 days + 1);

        // STRANGER settles — autonomous, no owner needed
        vm.prank(STRANGER);
        bodaSavings.settleExpiredPot(USER);

        (,,,,,,, bool potActive,,,) = bodaSavings.getRiderAnalytics(USER);
        assertFalse(potActive);
    }

    function testSettleExpiredPotRevertsIfDeadlineNotReached() public {
        _depositAndLock(DEPOSIT_AMOUNT / 2);

        // Only 3 days in — not yet expired
        vm.warp(block.timestamp + 3 days);

        vm.expectRevert(
            BodaBodaSavings.BodaBodaSavings__PotDeadlineNotReached.selector
        );
        bodaSavings.settleExpiredPot(USER);
    }

    function testPotDeadlineDynamicPerLender() public {
        // Register a second rider against the DAILY lender
        address riderB = address(0xBB);
        vm.prank(OWNER);
        mockUSDC.ownerMint(riderB, DEPOSIT_AMOUNT);

        vm.prank(OWNER);
        bodaSavings.registerRider(
            riderB, LENDER_DAILY, LOAN_TARGET, KYC_HASH,
            bodaSavings.KYC_FULL(), licenseExpiry, KYC_PROVIDER
        );

        vm.startPrank(riderB);
        mockUSDC.approve(address(bodaSavings), type(uint256).max);
        bodaSavings.deposit(DEPOSIT_AMOUNT);
        bodaSavings.lockToPot(DEPOSIT_AMOUNT / 2, 0);
        vm.stopPrank();

        // After 1 day + 1s → riderB's pot (daily cycle) should be settleable
        vm.warp(block.timestamp + 1 days + 1);

        // riderB's pot should expire (1 day cycle)
        bodaSavings.settleExpiredPot(riderB);

        // USER's pot (weekly cycle) should NOT yet be expired
        vm.prank(USER);
        bodaSavings.deposit(DEPOSIT_AMOUNT);
        vm.prank(USER);
        bodaSavings.lockToPot(DEPOSIT_AMOUNT / 2, 0);

        vm.expectRevert(
            BodaBodaSavings.BodaBodaSavings__PotDeadlineNotReached.selector
        );
        bodaSavings.settleExpiredPot(USER);
    }

    function testPotExcessReturnedToLoanBalance() public {
        // Rider has 100e6 loanBalance but only 50e6 remaining on loan
        // Lock 80e6 → 50e6 goes to lender, 30e6 returns to loanBalance

        // Register a fresh rider with a small loan target
        address riderC = address(0xCC);
        uint256 smallTarget = 50e6;

        vm.prank(OWNER);
        mockUSDC.ownerMint(riderC, 200e6);

        vm.prank(OWNER);
        bodaSavings.registerRider(
            riderC, LENDER_WEEKLY, smallTarget, KYC_HASH,
            bodaSavings.KYC_FULL(), licenseExpiry, KYC_PROVIDER
        );

        vm.startPrank(riderC);
        mockUSDC.approve(address(bodaSavings), type(uint256).max);
        bodaSavings.deposit(160e6);   // loanBalance = 80e6, savingsBalance = 80e6
        bodaSavings.lockToPot(80e6, 0);
        vm.stopPrank();

        uint256 lenderBefore = mockUSDC.balanceOf(LENDER_WEEKLY);

        vm.expectEmit(true, false, false, true);
        emit BodaBodaSavings.PotExcessReturned(riderC, 30e6);

        vm.prank(riderC);
        bodaSavings.releaseFromPot();

        // Lender received only 50e6 (the remaining loan balance)
        assertEq(mockUSDC.balanceOf(LENDER_WEEKLY) - lenderBefore, 50e6);

        // Excess 30e6 returned to riderC's loanBalance
        (,uint256 loanBal,,,,) = bodaSavings.getLoanStatus(riderC);
        assertEq(loanBal, 30e6);
    }

    // ────────────────────────────────────────────────────────────────
    //                6. SAVINGS WITHDRAWAL FLOW TESTS
    // ────────────────────────────────────────────────────────────────

    function _depositAndRequestWithdrawal(uint256 withdrawAmount) internal {
        vm.prank(USER);
        bodaSavings.deposit(DEPOSIT_AMOUNT);

        vm.prank(USER);
        bodaSavings.requestWithdrawal(
            withdrawAmount,
            bodaSavings.REASON_MEDICAL()
        );
    }

    function testRequestWithdrawalSuccess() public {
        _depositAndRequestWithdrawal(200e6);

        (uint256 amt, bytes32 cat,,, , BodaBodaSavings.WithdrawalStatus status) =
            bodaSavings.getWithdrawalRequest(USER);

        assertEq(amt, 200e6);
        assertEq(cat, bodaSavings.REASON_MEDICAL());
        assertEq(uint8(status), uint8(BodaBodaSavings.WithdrawalStatus.Pending));
    }

    function testRequestWithdrawalRevertsIfInvalidCategory() public {
        vm.prank(USER);
        bodaSavings.deposit(DEPOSIT_AMOUNT);

        vm.prank(USER);
        vm.expectRevert(
            BodaBodaSavings.BodaBodaSavings__InvalidWithdrawalCategory.selector
        );
        bodaSavings.requestWithdrawal(100e6, bytes32("INVALID_REASON"));
    }

    function testRequestWithdrawalRevertsIfInsufficientSavings() public {
        vm.prank(USER);
        vm.expectRevert(
            BodaBodaSavings.BodaBodaSavings__InsufficientSavings.selector
        );
        bodaSavings.requestWithdrawal(100e6, bodaSavings.REASON_EMERGENCY());
    }

    function testApproveAndClaimWithdrawal() public {
        _depositAndRequestWithdrawal(200e6);

        // Owner approves
        vm.prank(OWNER);
        bodaSavings.approveWithdrawal(USER);

        // Advance past the 150s delay
        vm.warp(block.timestamp + bodaSavings.WITHDRAWAL_DELAY() + 1);

        uint256 balanceBefore = mockUSDC.balanceOf(USER);

        vm.prank(USER);
        vm.expectEmit(true, false, false, true);
        emit BodaBodaSavings.WithdrawalClaimed(USER, 200e6, block.timestamp);
        bodaSavings.claimWithdrawal();

        assertEq(mockUSDC.balanceOf(USER) - balanceBefore, 200e6);

        // History should have one record
        BodaBodaSavings.WithdrawalRecord[] memory hist =
            bodaSavings.getWithdrawalHistory(USER);
        assertEq(hist.length, 1);
        assertEq(hist[0].amount,   200e6);
        assertEq(hist[0].category, bodaSavings.REASON_MEDICAL());
    }

    function testClaimWithdrawalRevertsIfDelayNotMet() public {
        _depositAndRequestWithdrawal(200e6);

        vm.prank(OWNER);
        bodaSavings.approveWithdrawal(USER);

        // Try to claim immediately — should revert
        vm.prank(USER);
        vm.expectRevert(
            BodaBodaSavings.BodaBodaSavings__WithdrawalDelayNotMet.selector
        );
        bodaSavings.claimWithdrawal();
    }

    function testDenyWithdrawalReturnsFunds() public {
        _depositAndRequestWithdrawal(200e6);

        // Check savings were locked
        (uint256 sav,,,,,,,,,, ) = bodaSavings.getRiderAnalytics(USER);
        assertEq(sav, DEPOSIT_AMOUNT / 2 - 200e6);

        // Owner denies
        vm.prank(OWNER);
        bodaSavings.denyWithdrawal(USER);

        // Savings restored
        (uint256 savAfter,,,,,,,,,, ) = bodaSavings.getRiderAnalytics(USER);
        assertEq(savAfter, DEPOSIT_AMOUNT / 2);

        // Request cleared
        (,,,,, BodaBodaSavings.WithdrawalStatus status) =
            bodaSavings.getWithdrawalRequest(USER);
        assertEq(uint8(status), uint8(BodaBodaSavings.WithdrawalStatus.None));
    }

    function testAllWithdrawalCategoriesAccepted() public {
        // Fund rider enough for 7 requests
        mockUSDC.transfer(USER, 7 * DEPOSIT_AMOUNT);

        bytes32[7] memory categories = [
            bodaSavings.REASON_MEDICAL(),
            bodaSavings.REASON_REPAIR(),
            bodaSavings.REASON_EDUCATION(),
            bodaSavings.REASON_HOUSEHOLD(),
            bodaSavings.REASON_EMERGENCY(),
            bodaSavings.REASON_FAMILY_OBLIGATION(),
            bodaSavings.REASON_OTHER()
        ];

        for (uint256 i = 0; i < 7; i++) {
            // Fresh deposit each round
            vm.prank(USER);
            bodaSavings.deposit(DEPOSIT_AMOUNT);

            // Request with this category
            vm.prank(USER);
            bodaSavings.requestWithdrawal(100e6, categories[i]);

            // Owner approves + warp + claim to reset state
            vm.prank(OWNER);
            bodaSavings.approveWithdrawal(USER);
            vm.warp(block.timestamp + bodaSavings.WITHDRAWAL_DELAY() + 1);
            vm.prank(USER);
            bodaSavings.claimWithdrawal();
        }

        BodaBodaSavings.WithdrawalRecord[] memory hist =
            bodaSavings.getWithdrawalHistory(USER);
        assertEq(hist.length, 7);
    }

    // ────────────────────────────────────────────────────────────────
    //               7. ADMIN — PAUSE / STABLECOIN / RECOVER
    // ────────────────────────────────────────────────────────────────

    function testPauseBlocksDeposit() public {
        vm.prank(OWNER);
        bodaSavings.pause();

        vm.prank(USER);
        vm.expectRevert();   // EnforcedPause
        bodaSavings.deposit(DEPOSIT_AMOUNT);
    }

    function testUnpauseRestoresDeposit() public {
        vm.startPrank(OWNER);
        bodaSavings.pause();
        bodaSavings.unpause();
        vm.stopPrank();

        vm.prank(USER);
        bodaSavings.deposit(DEPOSIT_AMOUNT);   // should not revert
    }

    function testSetStablecoinRevertsIfBalanceNotZero() public {
        // Put funds in the contract first
        vm.prank(USER);
        bodaSavings.deposit(DEPOSIT_AMOUNT);

        MockUSDC newToken = new MockUSDC(10e6, OWNER);
        vm.prank(OWNER);
        vm.expectRevert(
            BodaBodaSavings.BodaBodaSavings__ContractBalanceMustBeZero.selector
        );
        bodaSavings.setStablecoin(address(newToken));
    }

    function testSetStablecoinSuccessWhenBalanceZero() public {
        MockUSDC newToken = new MockUSDC(10e6, OWNER);
        address  old      = address(bodaSavings.stablecoin());

        vm.prank(OWNER);
        vm.expectEmit(true, true, false, false);
        emit BodaBodaSavings.StablecoinUpdated(old, address(newToken));
        bodaSavings.setStablecoin(address(newToken));

        assertEq(address(bodaSavings.stablecoin()), address(newToken));
    }

    function testRecoverERC20Success() public {
        MockUSDC otherToken = new MockUSDC(10e6, OWNER);
        vm.prank(OWNER);
        otherToken.transfer(address(bodaSavings), 5e6);

        uint256 before = otherToken.balanceOf(OWNER);
        vm.prank(OWNER);
        bodaSavings.recoverERC20(address(otherToken), OWNER, 5e6);
        assertEq(otherToken.balanceOf(OWNER) - before, 5e6);
    }

    function testRecoverERC20RevertsIfStablecoin() public {
        vm.prank(OWNER);
        vm.expectRevert(
            BodaBodaSavings.BodaBodaSavings__CannotRecoverStablecoin.selector
        );
        bodaSavings.recoverERC20(address(mockUSDC), OWNER, 1e6);
    }

    function testOnlyOwnerCanPause() public {
        vm.prank(STRANGER);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                STRANGER
            )
        );
        bodaSavings.pause();
    }

    // ────────────────────────────────────────────────────────────────
    //                     8. VIEW HELPER TESTS
    // ────────────────────────────────────────────────────────────────

    function testGetLoanStatusProgress() public {
        vm.prank(USER);
        bodaSavings.deposit(DEPOSIT_AMOUNT);

        vm.prank(USER);
        bodaSavings.lockToPot(DEPOSIT_AMOUNT / 2, 0);

        vm.prank(USER);
        bodaSavings.releaseFromPot();

        (
            uint256 target,
            uint256 loanBal,
            uint256 repaid,
            uint256 remaining,
            bool    cleared,
            uint256 bps
        ) = bodaSavings.getLoanStatus(USER);

        assertEq(target,    LOAN_TARGET);
        assertEq(loanBal,   0);              // locked and settled
        assertEq(repaid,    DEPOSIT_AMOUNT / 2);
        assertEq(remaining, LOAN_TARGET - DEPOSIT_AMOUNT / 2);
        assertFalse(cleared);
        assertEq(bps, (repaid * 10_000) / target);
    }

    function testGetIdleLoanBalanceAndLockedPotTotal() public {
        vm.prank(USER);
        bodaSavings.deposit(DEPOSIT_AMOUNT);

        // Before locking — all loan credits are idle
        assertEq(bodaSavings.getIdleLoanBalance(), DEPOSIT_AMOUNT / 2);
        assertEq(bodaSavings.getLockedPotTotal(),  0);

        vm.prank(USER);
        bodaSavings.lockToPot(DEPOSIT_AMOUNT / 2, 0);

        // After locking — idle = 0, locked = 500e6
        assertEq(bodaSavings.getIdleLoanBalance(), 0);
        assertEq(bodaSavings.getLockedPotTotal(),  DEPOSIT_AMOUNT / 2);
    }

    function testGetContractBalance() public {
        vm.prank(USER);
        bodaSavings.deposit(DEPOSIT_AMOUNT);
        assertEq(bodaSavings.getContractBalance(), DEPOSIT_AMOUNT);
    }

    function testIsVerifiedRiderReturnsFalseForStranger() public view {
        assertFalse(bodaSavings.isVerifiedRider(STRANGER));
    }

    // ────────────────────────────────────────────────────────────────
    //                      9. FUZZ TESTS
    // ────────────────────────────────────────────────────────────────

    /// @dev Deposit any even amount — savings and loan parts should always sum to total
    function testFuzzDepositSplitAlwaysSumsToTotal(uint256 amount) public {
        // Bound to realistic range and multiples of 2
        amount = bound(amount, 2, INITIAL_BALANCE);
        amount = amount % 2 == 0 ? amount : amount - 1;

        mockUSDC.transfer(USER, amount);

        vm.prank(USER);
        bodaSavings.deposit(amount);

        (uint256 sav, uint256 loan,,,,,,,,, ) = bodaSavings.getRiderAnalytics(USER);
        assertEq(sav + loan, amount);
    }

    /// @dev Any valid lock amount should never exceed loanBalance
    function testFuzzLockToPotNeverExceedsLoanBalance(uint256 lockAmount) public {
        vm.prank(USER);
        bodaSavings.deposit(DEPOSIT_AMOUNT);

        (, uint256 loanBal,,,,) = bodaSavings.getLoanStatus(USER);
        lockAmount = bound(lockAmount, 1, loanBal);

        vm.prank(USER);
        bodaSavings.lockToPot(lockAmount, 0);

        (,,,,,,,, uint256 potBal,,) = bodaSavings.getRiderAnalytics(USER);
        assertEq(potBal, lockAmount);
    }
}

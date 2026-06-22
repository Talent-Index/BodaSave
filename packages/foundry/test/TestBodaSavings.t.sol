// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test }            from "forge-std/Test.sol";
import { BodaBodaSavings } from "../src/BodaSavings.sol";
import { MockUSDC }        from "../src/MockUSDC.sol";
import { Ownable }         from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Test suite for BodaBodaSavings v4 (scheduled auto-settlement).
///
///         Major v4 differences vs the V3.1 suite:
///         • The pot (lockToPot / releaseFromPot / settleExpiredPot / getLockedPotTotal)
///           is gone — Section 6 now exercises settleLoanRepayment() instead.
///         • getRiderProfile() and getRiderAnalytics() return named memory structs
///           (RiderProfileView / RiderAnalyticsView), not positional tuples.
///         • New coverage: cycle-change-applies-to-existing-riders, loan-cleared
///           routing, split rounding accumulator, tiered auto-approval, solvency
///           invariant, Ownable2Step, and fee-on-transfer crediting (SEC-B).
contract TestBodaSavings is Test {

    BodaBodaSavings bodaSavings;
    MockUSDC        mockUSDC;

    address constant OWNER     = address(0xA0);
    address constant STRANGER  = address(0xC0);
    address constant NEW_OWNER = address(0xA1);

    uint256 constant USER_PK = 0xBEEF;
    address          USER;

    address constant LENDER_WEEKLY  = address(0x1111);
    address constant LENDER_MONTHLY = address(0x2222);
    address constant LENDER_DAILY   = address(0x3333);
    address constant NEW_LENDER     = address(0xD0);

    uint256 constant INITIAL_BALANCE = 10_000e6;
    uint256 constant LOAN_TARGET     = 5_000e6;
    uint256 constant DEPOSIT_AMOUNT  = 1_000e6;

    bytes32 constant KYC_HASH     = keccak256("rider_kyc_docs_hash");
    bytes32 constant KYC_PROVIDER = bytes32("SMILE_IDENTITY");
    uint256          licenseExpiry;

    string  constant RIDER_NAME   = "John Kamau";
    uint8   constant RIDER_AGE    = 32;
    bytes1  constant RIDER_GENDER = bytes1(0x4d);   // 'M'

    uint8 constant KYC_BASIC_LEVEL   = 1;
    uint8 constant KYC_FULL_LEVEL    = 2;
    uint8 constant KYC_PREMIUM_LEVEL = 3;

    bytes32 constant REASON_MEDICAL_VAL = "MEDICAL";

    uint256 constant SETUP_TIMESTAMP = 1_700_000_000;

    function setUp() public {
        USER = vm.addr(USER_PK);

        vm.warp(SETUP_TIMESTAMP);
        licenseExpiry = block.timestamp + 365 days;

        vm.startPrank(OWNER);
        mockUSDC = new MockUSDC(20_000_000e6, OWNER);

        (
            address[] memory lenderAddrs,
            string[]  memory lenderNames,
            uint256[] memory cycles,
            BodaBodaSavings.RepaymentSchedule[] memory schedules
        ) = _standardLenders();

        bodaSavings = new BodaBodaSavings(
            address(mockUSDC), lenderAddrs, lenderNames, cycles, schedules, OWNER
        );

        mockUSDC.ownerMint(USER, INITIAL_BALANCE);
        vm.stopPrank();

        vm.prank(USER);
        bodaSavings.registerRider(
            RIDER_NAME, RIDER_AGE, RIDER_GENDER,
            LENDER_WEEKLY,
            BodaBodaSavings.SplitRatio.SPLIT_50_50,
            LOAN_TARGET, KYC_HASH,
            KYC_FULL_LEVEL, licenseExpiry, KYC_PROVIDER
        );

        vm.prank(USER);
        mockUSDC.approve(address(bodaSavings), type(uint256).max);
    }

    // ════════════════════════════════════════════════════════════════
    //                          HELPERS
    // ════════════════════════════════════════════════════════════════

    function _standardLenders()
        internal
        pure
        returns (
            address[] memory addrs,
            string[]  memory names,
            uint256[] memory cycles,
            BodaBodaSavings.RepaymentSchedule[] memory schedules
        )
    {
        addrs  = new address[](3);
        names  = new string[](3);
        cycles = new uint256[](3);
        schedules = new BodaBodaSavings.RepaymentSchedule[](3);

        addrs[0] = LENDER_WEEKLY;  names[0] = "Mwanga Haba SACCO"; cycles[0] = 7 days;
        addrs[1] = LENDER_MONTHLY; names[1] = "Faulu MFB";         cycles[1] = 30 days;
        addrs[2] = LENDER_DAILY;   names[2] = "Kenya Women MFI";   cycles[2] = 1 days;

        schedules[0] = BodaBodaSavings.RepaymentSchedule.WEEKLY;
        schedules[1] = BodaBodaSavings.RepaymentSchedule.MONTHLY;
        schedules[2] = BodaBodaSavings.RepaymentSchedule.WEEKLY;
    }

    function _deployWith(address token) internal returns (BodaBodaSavings) {
        (
            address[] memory a,
            string[]  memory n,
            uint256[] memory c,
            BodaBodaSavings.RepaymentSchedule[] memory s
        ) = _standardLenders();
        return new BodaBodaSavings(token, a, n, c, s, OWNER);
    }

    function _signPermit(
        uint256 signerPk,
        address spender,
        uint256 value,
        uint256 deadline
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        address signer = vm.addr(signerPk);
        uint256 nonce  = mockUSDC.nonces(signer);

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                ),
                signer, spender, value, nonce, deadline
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", mockUSDC.DOMAIN_SEPARATOR(), structHash)
        );
        (v, r, s) = vm.sign(signerPk, digest);
    }

    function _registerRider(
        address rider,
        address lender,
        BodaBodaSavings.SplitRatio ratio,
        uint256 loanTarget
    ) internal {
        vm.prank(OWNER);
        mockUSDC.ownerMint(rider, INITIAL_BALANCE);

        vm.prank(rider);
        bodaSavings.registerRider(
            "Test Rider", 30, bytes1(0x4d),
            lender, ratio, loanTarget,
            KYC_HASH, KYC_FULL_LEVEL, licenseExpiry, KYC_PROVIDER
        );

        vm.prank(rider);
        mockUSDC.approve(address(bodaSavings), type(uint256).max);
    }

    /// @dev Warp just past a rider's next scheduled settlement.
    function _warpPastSettlement(address rider) internal {
        vm.warp(bodaSavings.getNextSettlementDue(rider) + 1);
    }

    function _analytics(address rider)
        internal view returns (BodaBodaSavings.RiderAnalyticsView memory)
    {
        return bodaSavings.getRiderAnalytics(rider);
    }

    function _depositAndRequestWithdrawal(uint256 withdrawAmount) internal {
        vm.prank(USER);
        bodaSavings.deposit(DEPOSIT_AMOUNT);
        vm.prank(USER);
        bodaSavings.requestWithdrawal(withdrawAmount, REASON_MEDICAL_VAL);
    }

    /// @dev Registers a rider, deposits enough to exceed a small loan target, settles,
    ///      and returns the rider in a loan-cleared state. (target 50e6, 50/50 split)
    function _setupClearedRider() internal returns (address rider) {
        rider = address(0xC1EA4);
        _registerRider(rider, LENDER_WEEKLY, BodaBodaSavings.SplitRatio.SPLIT_50_50, 50e6);
        vm.prank(rider);
        bodaSavings.deposit(160e6);              // savings 80e6, loan 80e6
        _warpPastSettlement(rider);
        bodaSavings.settleLoanRepayment(rider);  // pays 50e6, 30e6 excess -> savings
    }

    // ════════════════════════════════════════════════════════════════
    //                    1. CONSTRUCTOR TESTS
    // ════════════════════════════════════════════════════════════════

    function testConstructorRevertsIfStablecoinZeroAddress() public {
        (
            address[] memory addrs,
            string[]  memory names,
            uint256[] memory cycs,
            BodaBodaSavings.RepaymentSchedule[] memory scheds
        ) = _standardLenders();

        vm.expectRevert(
            BodaBodaSavings.BodaBodaSavings__StablecoinCannotBeZeroAddress.selector
        );
        new BodaBodaSavings(address(0), addrs, names, cycs, scheds, OWNER);
    }

    function testConstructorRevertsIfNoLendersProvided() public {
        address[] memory addrs  = new address[](0);
        string[]  memory names  = new string[](0);
        uint256[] memory cycs   = new uint256[](0);
        BodaBodaSavings.RepaymentSchedule[] memory scheds =
            new BodaBodaSavings.RepaymentSchedule[](0);

        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__NoLendersProvided.selector);
        new BodaBodaSavings(address(mockUSDC), addrs, names, cycs, scheds, OWNER);
    }

    function testConstructorRevertsIfArrayLengthMismatch() public {
        address[] memory addrs  = new address[](2);
        string[]  memory names  = new string[](1);
        uint256[] memory cycs   = new uint256[](2);
        BodaBodaSavings.RepaymentSchedule[] memory scheds =
            new BodaBodaSavings.RepaymentSchedule[](2);
        addrs[0] = LENDER_WEEKLY; addrs[1] = LENDER_MONTHLY;
        names[0] = "Only one";
        cycs[0] = 7 days; cycs[1] = 30 days;

        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__ArrayLengthMismatch.selector);
        new BodaBodaSavings(address(mockUSDC), addrs, names, cycs, scheds, OWNER);
    }

    function testConstructorRegistersAllLenders() public view {
        assertEq(bodaSavings.getLenderCount(), 3);
    }

    function testConstructorStoresRepaymentSchedule() public view {
        (, , BodaBodaSavings.RepaymentSchedule sched, , ) = bodaSavings.getLender(LENDER_WEEKLY);
        assertEq(uint8(sched), uint8(BodaBodaSavings.RepaymentSchedule.WEEKLY));

        (, , BodaBodaSavings.RepaymentSchedule sched2, , ) = bodaSavings.getLender(LENDER_MONTHLY);
        assertEq(uint8(sched2), uint8(BodaBodaSavings.RepaymentSchedule.MONTHLY));
    }

    // ════════════════════════════════════════════════════════════════
    //                  2. LENDER MANAGEMENT TESTS
    // ════════════════════════════════════════════════════════════════

    function testAddLenderSuccess() public {
        vm.prank(OWNER);
        bodaSavings.addLender(
            NEW_LENDER, "New SACCO", 14 days, BodaBodaSavings.RepaymentSchedule.BIWEEKLY
        );

        assertEq(bodaSavings.getLenderCount(), 4);
        (, uint256 cycle, BodaBodaSavings.RepaymentSchedule sched, bool verified, bool active) =
            bodaSavings.getLender(NEW_LENDER);
        assertEq(cycle, 14 days);
        assertEq(uint8(sched), uint8(BodaBodaSavings.RepaymentSchedule.BIWEEKLY));
        assertTrue(verified);
        assertTrue(active);
    }

    function testAddLenderRevertsIfAlreadyRegistered() public {
        vm.prank(OWNER);
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__LenderAlreadyRegistered.selector);
        bodaSavings.addLender(
            LENDER_WEEKLY, "Duplicate", 7 days, BodaBodaSavings.RepaymentSchedule.WEEKLY
        );
    }

    function testAddLenderRevertsIfZeroCycle() public {
        vm.prank(OWNER);
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__InvalidCollectionCycle.selector);
        bodaSavings.addLender(NEW_LENDER, "Bad", 0, BodaBodaSavings.RepaymentSchedule.MONTHLY);
    }

    function testDeactivateAndReactivateLender() public {
        vm.startPrank(OWNER);
        bodaSavings.deactivateLender(LENDER_WEEKLY);
        (,,,, bool activeBefore) = bodaSavings.getLender(LENDER_WEEKLY);
        assertFalse(activeBefore);

        bodaSavings.reactivateLender(LENDER_WEEKLY);
        (,,,, bool activeAfter) = bodaSavings.getLender(LENDER_WEEKLY);
        assertTrue(activeAfter);
        vm.stopPrank();
    }

    function testUpdateLenderCycleSuccess() public {
        vm.prank(OWNER);
        bodaSavings.updateLenderCycle(LENDER_WEEKLY, 14 days);
        (, uint256 cycle,,,) = bodaSavings.getLender(LENDER_WEEKLY);
        assertEq(cycle, 14 days);
    }

    function testGetLendersPagination() public view {
        address[] memory page = bodaSavings.getLenders(0, 2);
        assertEq(page.length, 2);
        assertEq(page[0], LENDER_WEEKLY);
        assertEq(page[1], LENDER_MONTHLY);

        address[] memory rest = bodaSavings.getLenders(2, 0);
        assertEq(rest.length, 1);
        assertEq(rest[0], LENDER_DAILY);
    }

    // ════════════════════════════════════════════════════════════════
    //             3. RIDER REGISTRATION TESTS
    // ════════════════════════════════════════════════════════════════

    function testRegisterRiderSuccess() public view {
        assertTrue(bodaSavings.isVerifiedRider(USER));
    }

    function testRegisterRiderStoresIdentity() public view {
        BodaBodaSavings.RiderProfileView memory p = bodaSavings.getRiderProfile(USER);
        assertEq(p.name, RIDER_NAME);
        assertEq(p.age,  RIDER_AGE);
        assertTrue(p.gender == RIDER_GENDER);
        assertTrue(p.registered);
    }

    function testRegisterRiderStoresSplitRatio() public view {
        BodaBodaSavings.RiderProfileView memory p = bodaSavings.getRiderProfile(USER);
        assertEq(uint8(p.splitRatio), uint8(BodaBodaSavings.SplitRatio.SPLIT_50_50));
    }

    function testRegisterRiderStoresLenderAndSchedule() public view {
        BodaBodaSavings.RiderProfileView memory p = bodaSavings.getRiderProfile(USER);
        assertEq(p.lenderAddress, LENDER_WEEKLY);
        assertEq(p.lenderName, "Mwanga Haba SACCO");
        assertEq(uint8(p.lenderSchedule), uint8(BodaBodaSavings.RepaymentSchedule.WEEKLY));
    }

    function testRegisterRiderInitializesSettlementClock() public view {
        // lastSettledAt set at registration; first settlement due one cycle later.
        BodaBodaSavings.RiderAnalyticsView memory a = _analytics(USER);
        assertEq(a.lastSettledAt, SETUP_TIMESTAMP);
        assertEq(a.nextSettlementDue, SETUP_TIMESTAMP + 7 days);
    }

    function testRegisterRiderRevertsIfAlreadyRegistered() public {
        vm.prank(USER);
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__RiderAlreadyRegistered.selector);
        bodaSavings.registerRider(
            RIDER_NAME, RIDER_AGE, RIDER_GENDER,
            LENDER_WEEKLY, BodaBodaSavings.SplitRatio.SPLIT_50_50,
            LOAN_TARGET, KYC_HASH, KYC_FULL_LEVEL, licenseExpiry, KYC_PROVIDER
        );
    }

    function testRegisterRiderRevertsIfNameEmpty() public {
        vm.prank(address(0xE0));
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__NameRequired.selector);
        bodaSavings.registerRider(
            "", RIDER_AGE, RIDER_GENDER,
            LENDER_WEEKLY, BodaBodaSavings.SplitRatio.SPLIT_50_50,
            LOAN_TARGET, KYC_HASH, KYC_FULL_LEVEL, licenseExpiry, KYC_PROVIDER
        );
    }

    function testRegisterRiderRevertsIfAgeTooLow() public {
        vm.prank(address(0xE1));
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__InvalidAge.selector);
        bodaSavings.registerRider(
            RIDER_NAME, 17, RIDER_GENDER,
            LENDER_WEEKLY, BodaBodaSavings.SplitRatio.SPLIT_50_50,
            LOAN_TARGET, KYC_HASH, KYC_FULL_LEVEL, licenseExpiry, KYC_PROVIDER
        );
    }

    function testRegisterRiderRevertsIfAgeTooHigh() public {
        vm.prank(address(0xE2));
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__InvalidAge.selector);
        bodaSavings.registerRider(
            RIDER_NAME, 66, RIDER_GENDER,
            LENDER_WEEKLY, BodaBodaSavings.SplitRatio.SPLIT_50_50,
            LOAN_TARGET, KYC_HASH, KYC_FULL_LEVEL, licenseExpiry, KYC_PROVIDER
        );
    }

    function testRegisterRiderRevertsIfInvalidGender() public {
        vm.prank(address(0xE3));
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__InvalidGender.selector);
        bodaSavings.registerRider(
            RIDER_NAME, RIDER_AGE, bytes1(0x58),   // 'X'
            LENDER_WEEKLY, BodaBodaSavings.SplitRatio.SPLIT_50_50,
            LOAN_TARGET, KYC_HASH, KYC_FULL_LEVEL, licenseExpiry, KYC_PROVIDER
        );
    }

    function testRegisterRiderRevertsIfLenderInactive() public {
        vm.prank(OWNER);
        bodaSavings.deactivateLender(LENDER_WEEKLY);

        vm.prank(address(0xE4));
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__LenderNotActive.selector);
        bodaSavings.registerRider(
            RIDER_NAME, RIDER_AGE, RIDER_GENDER,
            LENDER_WEEKLY, BodaBodaSavings.SplitRatio.SPLIT_50_50,
            LOAN_TARGET, KYC_HASH, KYC_FULL_LEVEL, licenseExpiry, KYC_PROVIDER
        );
    }

    function testRegisterRiderRevertsIfLicenseExpired() public {
        vm.prank(address(0xE5));
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__LicenseExpired.selector);
        bodaSavings.registerRider(
            RIDER_NAME, RIDER_AGE, RIDER_GENDER,
            LENDER_WEEKLY, BodaBodaSavings.SplitRatio.SPLIT_50_50,
            LOAN_TARGET, KYC_HASH, KYC_FULL_LEVEL, block.timestamp - 1, KYC_PROVIDER
        );
    }

    function testAllGenderValuesAccepted() public {
        bytes1[3]  memory genders    = [bytes1(0x4d), bytes1(0x46), bytes1(0x4f)];
        address[3] memory riderAddrs = [address(0xF1), address(0xF2), address(0xF3)];

        for (uint256 i = 0; i < 3; i++) {
            vm.prank(riderAddrs[i]);
            bodaSavings.registerRider(
                RIDER_NAME, RIDER_AGE, genders[i],
                LENDER_WEEKLY, BodaBodaSavings.SplitRatio.SPLIT_50_50,
                LOAN_TARGET, KYC_HASH, KYC_FULL_LEVEL, licenseExpiry, KYC_PROVIDER
            );
            assertTrue(bodaSavings.isVerifiedRider(riderAddrs[i]));
        }
    }

    function testUpdateRiderKYCSuccess() public {
        bytes32 newHash = keccak256("updated_kyc");
        vm.prank(OWNER);
        bodaSavings.updateRiderKYC(USER, newHash, KYC_PREMIUM_LEVEL, licenseExpiry + 365 days, KYC_PROVIDER);
        (bytes32 h, uint8 lvl,,,,) = bodaSavings.getRiderKYC(USER);
        assertEq(h,   newHash);
        assertEq(lvl, KYC_PREMIUM_LEVEL);
    }

    function testUpdateLoanTargetSuccess() public {
        vm.prank(OWNER);
        bodaSavings.updateLoanTarget(USER, 8_000e6);
        (uint256 target,,,,,) = bodaSavings.getLoanStatus(USER);
        assertEq(target, 8_000e6);
    }

    function testUpdateLoanTargetRevertsIfBelowRepaid() public {
        // Build up repaid balance via a scheduled settlement.
        vm.prank(USER);
        bodaSavings.deposit(DEPOSIT_AMOUNT);          // loan 500e6
        _warpPastSettlement(USER);
        bodaSavings.settleLoanRepayment(USER);        // loanRepaid = 500e6

        vm.prank(OWNER);
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__NewTargetBelowRepaid.selector);
        bodaSavings.updateLoanTarget(USER, 100e6);
    }

    function testUpdateSplitRatioAffectsFutureDeposits() public {
        vm.expectEmit(true, false, false, true);
        emit BodaBodaSavings.SplitRatioUpdated(
            USER,
            BodaBodaSavings.SplitRatio.SPLIT_50_50,
            BodaBodaSavings.SplitRatio.SPLIT_70_30
        );
        vm.prank(USER);
        bodaSavings.updateSplitRatio(BodaBodaSavings.SplitRatio.SPLIT_70_30);

        vm.prank(USER);
        bodaSavings.deposit(DEPOSIT_AMOUNT);

        BodaBodaSavings.RiderAnalyticsView memory a = _analytics(USER);
        assertEq(a.savingsBalance, 700e6);
        assertEq(a.loanBalance,    300e6);
    }

    // ════════════════════════════════════════════════════════════════
    //              4. DEPOSIT — SPLIT RATIO TESTS
    // ════════════════════════════════════════════════════════════════

    function testDepositRevertsIfZero() public {
        vm.prank(USER);
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__ZeroDeposit.selector);
        bodaSavings.deposit(0);
    }

    function testDepositRevertsIfNotRegistered() public {
        vm.prank(STRANGER);
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__RiderNotRegistered.selector);
        bodaSavings.deposit(100e6);
    }

    function testDepositSplit5050() public {
        vm.prank(USER);
        bodaSavings.deposit(DEPOSIT_AMOUNT);
        BodaBodaSavings.RiderAnalyticsView memory a = _analytics(USER);
        assertEq(a.savingsBalance, DEPOSIT_AMOUNT / 2);
        assertEq(a.loanBalance,    DEPOSIT_AMOUNT / 2);
    }

    function testDepositSplit7030() public {
        address rider70 = address(0xAA);
        _registerRider(rider70, LENDER_WEEKLY, BodaBodaSavings.SplitRatio.SPLIT_70_30, LOAN_TARGET);
        vm.prank(rider70);
        bodaSavings.deposit(DEPOSIT_AMOUNT);
        BodaBodaSavings.RiderAnalyticsView memory a = _analytics(rider70);
        assertEq(a.savingsBalance, 700e6);
        assertEq(a.loanBalance,    300e6);
    }

    function testDepositSplit3070() public {
        address rider30 = address(0xBB);
        _registerRider(rider30, LENDER_MONTHLY, BodaBodaSavings.SplitRatio.SPLIT_30_70, LOAN_TARGET);
        vm.prank(rider30);
        bodaSavings.deposit(DEPOSIT_AMOUNT);
        BodaBodaSavings.RiderAnalyticsView memory a = _analytics(rider30);
        assertEq(a.savingsBalance, 300e6);
        assertEq(a.loanBalance,    700e6);
    }

    function testDepositOddAmountFirstDepositLoanGetsFloorRemainder() public {
        // First deposit (remainder starts at 0) matches V3 behaviour exactly.
        address freshRider = address(0xABCD);
        vm.prank(OWNER);
        mockUSDC.ownerMint(freshRider, 101);

        vm.prank(freshRider);
        bodaSavings.registerRider(
            "Fresh Rider", 25, bytes1(0x4d),
            LENDER_WEEKLY, BodaBodaSavings.SplitRatio.SPLIT_70_30,
            LOAN_TARGET, KYC_HASH, KYC_FULL_LEVEL, licenseExpiry, KYC_PROVIDER
        );
        vm.prank(freshRider);
        mockUSDC.approve(address(bodaSavings), type(uint256).max);

        vm.prank(freshRider);
        bodaSavings.deposit(101);

        BodaBodaSavings.RiderAnalyticsView memory a = _analytics(freshRider);
        assertEq(a.savingsBalance, 70);   // floor(101 * 70 / 100)
        assertEq(a.loanBalance,    31);   // 101 - 70
        assertEq(a.savingsBalance + a.loanBalance, 101);
    }

    function testSplitRemainderAccumulatesAcrossDeposits() public {
        // [V4-6] The rounding remainder carries, so it nets out over deposits.
        address r70 = address(0x7070);
        _registerRider(r70, LENDER_WEEKLY, BodaBodaSavings.SplitRatio.SPLIT_70_30, LOAN_TARGET);

        vm.prank(r70);
        bodaSavings.deposit(101);   // savings 70, loan 31, remainder 70
        vm.prank(r70);
        bodaSavings.deposit(101);   // numerator 7070+70=7140 -> savings 71, loan 30

        BodaBodaSavings.RiderAnalyticsView memory a = _analytics(r70);
        assertEq(a.savingsBalance, 141);   // 70 + 71 (carry corrected the rounding)
        assertEq(a.loanBalance,    61);    // 31 + 30
        assertEq(a.totalDeposited, 202);
    }

    function testDepositUpdatesTotalSavingsHeld() public {
        vm.prank(USER);
        bodaSavings.deposit(DEPOSIT_AMOUNT);
        assertEq(bodaSavings.totalSavingsHeld(), DEPOSIT_AMOUNT / 2);
    }

    function testDepositUpdatesTotalUnsettledLoanBalance() public {
        vm.prank(USER);
        bodaSavings.deposit(DEPOSIT_AMOUNT);
        assertEq(bodaSavings.totalUnsettledLoanBalance(), DEPOSIT_AMOUNT / 2);
    }

    function testDepositTracksFirstAndLastTimestamps() public {
        vm.prank(USER);
        bodaSavings.deposit(DEPOSIT_AMOUNT);

        vm.warp(SETUP_TIMESTAMP + 1 days);
        vm.prank(OWNER);
        mockUSDC.ownerMint(USER, DEPOSIT_AMOUNT);
        vm.prank(USER);
        bodaSavings.deposit(DEPOSIT_AMOUNT);

        BodaBodaSavings.RiderAnalyticsView memory a = _analytics(USER);
        assertEq(a.firstDepositAt, SETUP_TIMESTAMP);
        assertEq(a.lastDepositAt,  SETUP_TIMESTAMP + 1 days);
    }

    // ════════════════════════════════════════════════════════════════
    //               5. depositWithPermit TESTS
    // ════════════════════════════════════════════════════════════════

    function testDepositWithPermitSuccess() public {
        vm.prank(USER);
        mockUSDC.approve(address(bodaSavings), 0);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(USER_PK, address(bodaSavings), DEPOSIT_AMOUNT, deadline);

        vm.prank(USER);
        bodaSavings.depositWithPermit(DEPOSIT_AMOUNT, deadline, v, r, s);

        BodaBodaSavings.RiderAnalyticsView memory a = _analytics(USER);
        assertEq(a.savingsBalance, DEPOSIT_AMOUNT / 2);
        assertEq(a.loanBalance,    DEPOSIT_AMOUNT / 2);
    }

    function testDepositWithPermitRevertsIfZeroAmount() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(USER_PK, address(bodaSavings), 0, deadline);

        vm.prank(USER);
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__ZeroDeposit.selector);
        bodaSavings.depositWithPermit(0, deadline, v, r, s);
    }

    function testDepositWithPermitRevertsIfExpiredDeadline() public {
        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(USER_PK, address(bodaSavings), DEPOSIT_AMOUNT, deadline);

        vm.prank(USER);
        vm.expectRevert();
        bodaSavings.depositWithPermit(DEPOSIT_AMOUNT, deadline, v, r, s);
    }

    function testDepositWithPermitRevertsIfNotRegistered() public {
        uint256 strangerPk = 0xCAFE;
        address stranger   = vm.addr(strangerPk);
        vm.prank(OWNER);
        mockUSDC.ownerMint(stranger, DEPOSIT_AMOUNT);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(strangerPk, address(bodaSavings), DEPOSIT_AMOUNT, deadline);

        vm.prank(stranger);
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__RiderNotRegistered.selector);
        bodaSavings.depositWithPermit(DEPOSIT_AMOUNT, deadline, v, r, s);
    }

    function testDepositWithPermitIncrementsNonce() public {
        vm.prank(USER);
        mockUSDC.approve(address(bodaSavings), 0);

        uint256 nonceBefore = mockUSDC.nonces(USER);
        uint256 deadline    = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(USER_PK, address(bodaSavings), DEPOSIT_AMOUNT, deadline);

        vm.prank(USER);
        bodaSavings.depositWithPermit(DEPOSIT_AMOUNT, deadline, v, r, s);

        assertEq(mockUSDC.nonces(USER), nonceBefore + 1);
    }

    // ════════════════════════════════════════════════════════════════
    //          6. LOAN SETTLEMENT (scheduled, passive)  [V4-1]
    // ════════════════════════════════════════════════════════════════

    function testSettleRevertsIfNotDue() public {
        vm.prank(USER);
        bodaSavings.deposit(DEPOSIT_AMOUNT);
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__SettlementNotDue.selector);
        bodaSavings.settleLoanRepayment(USER);
    }

    function testSettleRevertsIfRiderNotRegistered() public {
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__RiderNotRegistered.selector);
        bodaSavings.settleLoanRepayment(STRANGER);
    }

    function testSettleSweepsToLenderAndResetsClock() public {
        vm.prank(USER);
        bodaSavings.deposit(DEPOSIT_AMOUNT);            // loan 500e6
        _warpPastSettlement(USER);
        uint256 settleTime   = block.timestamp;
        uint256 lenderBefore = mockUSDC.balanceOf(LENDER_WEEKLY);

        vm.prank(STRANGER);                             // permissionless
        bodaSavings.settleLoanRepayment(USER);

        assertEq(mockUSDC.balanceOf(LENDER_WEEKLY) - lenderBefore, 500e6);

        BodaBodaSavings.RiderAnalyticsView memory a = _analytics(USER);
        assertEq(a.loanBalance,       0);
        assertEq(a.loanRepaid,        500e6);
        assertEq(a.lastSettledAt,     settleTime);
        assertEq(a.nextSettlementDue, settleTime + 7 days);

        // clock reset — an immediate re-settle is not due
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__SettlementNotDue.selector);
        bodaSavings.settleLoanRepayment(USER);
    }

    function testSettleZeroBalanceAdvancesClockNoTransfer() public {
        // No deposit -> loan 0. Settlement is a harmless schedule-advancing no-op.
        _warpPastSettlement(USER);
        uint256 t            = block.timestamp;
        uint256 lenderBefore = mockUSDC.balanceOf(LENDER_WEEKLY);

        bodaSavings.settleLoanRepayment(USER);

        assertEq(mockUSDC.balanceOf(LENDER_WEEKLY), lenderBefore);
        assertEq(_analytics(USER).lastSettledAt, t);
    }

    function testSettleBlockedWhenPaused() public {
        vm.prank(USER);
        bodaSavings.deposit(DEPOSIT_AMOUNT);
        _warpPastSettlement(USER);

        vm.prank(OWNER);
        bodaSavings.pause();

        vm.expectRevert();   // Pausable: EnforcedPause
        bodaSavings.settleLoanRepayment(USER);
    }

    function testUpdateLenderCycleAppliesToExistingRider() public {
        // [V4-2] cycle change re-bases the existing rider's next settlement.
        vm.prank(USER);
        bodaSavings.deposit(DEPOSIT_AMOUNT);            // loan 500e6

        vm.warp(SETUP_TIMESTAMP + 1 days + 1);
        assertFalse(bodaSavings.isSettlementDue(USER)); // not due under 7-day cycle

        vm.prank(OWNER);
        bodaSavings.updateLenderCycle(LENDER_WEEKLY, 1 days);
        assertTrue(bodaSavings.isSettlementDue(USER));  // now due under 1-day cycle

        uint256 lenderBefore = mockUSDC.balanceOf(LENDER_WEEKLY);
        bodaSavings.settleLoanRepayment(USER);
        assertEq(mockUSDC.balanceOf(LENDER_WEEKLY) - lenderBefore, 500e6);
    }

    function testSettleCapsAtTargetAndRoutesExcessToSavings() public {
        // [V4-3] loanBalance beyond remaining target spills into savings on clearing.
        address riderC = address(0xCC00);
        _registerRider(riderC, LENDER_WEEKLY, BodaBodaSavings.SplitRatio.SPLIT_50_50, 50e6);

        vm.prank(riderC);
        bodaSavings.deposit(160e6);                    // savings 80e6, loan 80e6
        _warpPastSettlement(riderC);

        uint256 lenderBefore = mockUSDC.balanceOf(LENDER_WEEKLY);
        bodaSavings.settleLoanRepayment(riderC);

        assertEq(mockUSDC.balanceOf(LENDER_WEEKLY) - lenderBefore, 50e6); // capped at target

        BodaBodaSavings.RiderAnalyticsView memory a = _analytics(riderC);
        assertEq(a.loanBalance,    0);
        assertEq(a.loanRepaid,     50e6);
        assertEq(a.savingsBalance, 110e6);             // 80e6 + 30e6 excess

        (,,,, bool cleared,) = bodaSavings.getLoanStatus(riderC);
        assertTrue(cleared);
    }

    function testDepositsRouteFullyToSavingsAfterLoanCleared() public {
        address rider = _setupClearedRider();          // cleared, savings 110e6
        vm.prank(rider);
        bodaSavings.deposit(100e6);

        BodaBodaSavings.RiderAnalyticsView memory a = _analytics(rider);
        assertEq(a.loanBalance,    0);                 // nothing routed to loan
        assertEq(a.savingsBalance, 210e6);             // full deposit to savings
    }

    function testSettlementSucceedsAfterLicenseExpired() public {
        // Repayment is an obligation — must settle even if the licence lapsed.
        vm.prank(USER);
        bodaSavings.deposit(DEPOSIT_AMOUNT);

        vm.warp(licenseExpiry + 7 days + 1);           // licence expired, settlement due
        uint256 lenderBefore = mockUSDC.balanceOf(LENDER_WEEKLY);
        bodaSavings.settleLoanRepayment(USER);
        assertEq(mockUSDC.balanceOf(LENDER_WEEKLY) - lenderBefore, 500e6);
    }

    // ════════════════════════════════════════════════════════════════
    //       7. SAVINGS WITHDRAWAL + TIERED APPROVAL  [AUD-3][V4-5]
    // ════════════════════════════════════════════════════════════════

    function testRequestWithdrawalAboveThresholdIsPending() public {
        _depositAndRequestWithdrawal(200e6);           // 200e6 > 50e6 threshold

        (uint256 amt, bytes32 cat,,,, BodaBodaSavings.WithdrawalStatus status) =
            bodaSavings.getWithdrawalRequest(USER);
        assertEq(amt, 200e6);
        assertEq(cat, REASON_MEDICAL_VAL);
        assertEq(uint8(status), uint8(BodaBodaSavings.WithdrawalStatus.Pending));
    }

    function testRequestWithdrawalUnderThresholdAutoApproves() public {
        vm.prank(USER);
        bodaSavings.deposit(DEPOSIT_AMOUNT);

        uint256 small = bodaSavings.autoApprovalThreshold();   // 50e6, <= threshold
        vm.prank(USER);
        bodaSavings.requestWithdrawal(small, REASON_MEDICAL_VAL);

        (,,,,, BodaBodaSavings.WithdrawalStatus status) = bodaSavings.getWithdrawalRequest(USER);
        assertEq(uint8(status), uint8(BodaBodaSavings.WithdrawalStatus.Approved));

        // claimable after the delay without any manual approval
        vm.warp(block.timestamp + bodaSavings.WITHDRAWAL_DELAY() + 1);
        uint256 before = mockUSDC.balanceOf(USER);
        vm.prank(USER);
        bodaSavings.claimWithdrawal();
        assertEq(mockUSDC.balanceOf(USER) - before, small);
    }

    function testOwnerCanRevokeAutoApprovedWithdrawalDuringDelay() public {
        vm.prank(USER);
        bodaSavings.deposit(DEPOSIT_AMOUNT);
        vm.prank(USER);
        bodaSavings.requestWithdrawal(50e6, REASON_MEDICAL_VAL);  // auto-approved

        vm.prank(OWNER);
        bodaSavings.revokeApprovedWithdrawal(USER);

        assertEq(_analytics(USER).savingsBalance, DEPOSIT_AMOUNT / 2); // restored
    }

    function testRequestWithdrawalRevertsIfInvalidCategory() public {
        vm.prank(USER);
        bodaSavings.deposit(DEPOSIT_AMOUNT);
        vm.prank(USER);
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__InvalidWithdrawalCategory.selector);
        bodaSavings.requestWithdrawal(100e6, bytes32("INVALID"));
    }

    function testRequestWithdrawalRevertsIfInsufficientSavings() public {
        vm.prank(USER);
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__InsufficientSavings.selector);
        bodaSavings.requestWithdrawal(100e6, bytes32("EMERGENCY"));
    }

    function testApproveAndClaimWithdrawal() public {
        _depositAndRequestWithdrawal(200e6);

        vm.prank(OWNER);
        bodaSavings.approveWithdrawal(USER);

        vm.warp(block.timestamp + bodaSavings.WITHDRAWAL_DELAY() + 1);

        uint256 before = mockUSDC.balanceOf(USER);
        vm.prank(USER);
        bodaSavings.claimWithdrawal();
        assertEq(mockUSDC.balanceOf(USER) - before, 200e6);

        BodaBodaSavings.WithdrawalRecord[] memory hist = bodaSavings.getWithdrawalHistory(USER);
        assertEq(hist.length,    1);
        assertEq(hist[0].amount, 200e6);
    }

    function testClaimWithdrawalSucceedsAfterKYCExpires() public {
        _depositAndRequestWithdrawal(200e6);

        vm.prank(OWNER);
        bodaSavings.approveWithdrawal(USER);

        vm.warp(licenseExpiry + bodaSavings.WITHDRAWAL_DELAY() + 1);

        // deposits are gated by licence...
        vm.prank(OWNER);
        mockUSDC.ownerMint(USER, 1e6);
        vm.prank(USER);
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__LicenseExpired.selector);
        bodaSavings.deposit(1e6);

        // ...but reclaiming one's own savings is not.
        uint256 before = mockUSDC.balanceOf(USER);
        vm.prank(USER);
        bodaSavings.claimWithdrawal();
        assertEq(mockUSDC.balanceOf(USER) - before, 200e6);
    }

    function testClaimWithdrawalRevertsIfDelayNotMet() public {
        _depositAndRequestWithdrawal(200e6);
        vm.prank(OWNER);
        bodaSavings.approveWithdrawal(USER);

        vm.prank(USER);
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__WithdrawalDelayNotMet.selector);
        bodaSavings.claimWithdrawal();
    }

    function testDenyWithdrawalReturnsFunds() public {
        _depositAndRequestWithdrawal(200e6);

        vm.prank(OWNER);
        bodaSavings.denyWithdrawal(USER);

        assertEq(_analytics(USER).savingsBalance, DEPOSIT_AMOUNT / 2);

        (,,,,, BodaBodaSavings.WithdrawalStatus status) = bodaSavings.getWithdrawalRequest(USER);
        assertEq(uint8(status), uint8(BodaBodaSavings.WithdrawalStatus.None));
    }

    function testRevokeApprovedWithdrawalSuccess() public {
        _depositAndRequestWithdrawal(200e6);

        vm.prank(OWNER);
        bodaSavings.approveWithdrawal(USER);
        vm.prank(OWNER);
        bodaSavings.revokeApprovedWithdrawal(USER);

        assertEq(_analytics(USER).savingsBalance, DEPOSIT_AMOUNT / 2);

        (,,,,, BodaBodaSavings.WithdrawalStatus statusAfter) = bodaSavings.getWithdrawalRequest(USER);
        assertEq(uint8(statusAfter), uint8(BodaBodaSavings.WithdrawalStatus.None));
    }

    function testRevokeApprovedWithdrawalRevertsIfNotApproved() public {
        _depositAndRequestWithdrawal(200e6);           // Pending, not Approved
        vm.prank(OWNER);
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__WithdrawalNotApproved.selector);
        bodaSavings.revokeApprovedWithdrawal(USER);
    }

    function testCancelWithdrawalFromPendingSuccess() public {
        _depositAndRequestWithdrawal(200e6);

        vm.prank(USER);
        bodaSavings.cancelWithdrawal();

        assertEq(_analytics(USER).savingsBalance, DEPOSIT_AMOUNT / 2);

        (,,,,, BodaBodaSavings.WithdrawalStatus status) = bodaSavings.getWithdrawalRequest(USER);
        assertEq(uint8(status), uint8(BodaBodaSavings.WithdrawalStatus.None));
    }

    function testCancelWithdrawalFromApprovedSuccess() public {
        _depositAndRequestWithdrawal(200e6);
        vm.prank(OWNER);
        bodaSavings.approveWithdrawal(USER);

        vm.prank(USER);
        bodaSavings.cancelWithdrawal();

        assertEq(_analytics(USER).savingsBalance, DEPOSIT_AMOUNT / 2);
    }

    function testCancelWithdrawalRevertsIfNoRequest() public {
        vm.prank(USER);
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__NoWithdrawalToCancel.selector);
        bodaSavings.cancelWithdrawal();
    }

    function testCancelWithdrawalWorksAfterKYCExpires() public {
        _depositAndRequestWithdrawal(200e6);
        vm.warp(licenseExpiry + 1);

        vm.prank(USER);
        bodaSavings.cancelWithdrawal();

        assertEq(_analytics(USER).savingsBalance, DEPOSIT_AMOUNT / 2);
    }

    function testClaimWithdrawalDecreasesTotalSavingsHeld() public {
        _depositAndRequestWithdrawal(200e6);
        uint256 heldBefore = bodaSavings.totalSavingsHeld();

        vm.prank(OWNER);
        bodaSavings.approveWithdrawal(USER);
        vm.warp(block.timestamp + bodaSavings.WITHDRAWAL_DELAY() + 1);

        vm.prank(USER);
        bodaSavings.claimWithdrawal();

        assertEq(bodaSavings.totalSavingsHeld(), heldBefore - 200e6);
    }

    function testAllWithdrawalCategoriesAccepted() public {
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
            vm.prank(OWNER);
            mockUSDC.ownerMint(USER, DEPOSIT_AMOUNT);
            vm.prank(USER);
            bodaSavings.deposit(DEPOSIT_AMOUNT);

            vm.prank(USER);
            bodaSavings.requestWithdrawal(100e6, categories[i]);   // 100e6 > threshold -> Pending
            vm.prank(OWNER);
            bodaSavings.approveWithdrawal(USER);

            vm.warp(block.timestamp + bodaSavings.WITHDRAWAL_DELAY() + 1);
            vm.prank(USER);
            bodaSavings.claimWithdrawal();
        }

        assertEq(bodaSavings.getWithdrawalHistory(USER).length, 7);
    }

    // ════════════════════════════════════════════════════════════════
    //   8. ADMIN — PAUSE / setStablecoin [AUD-4] / threshold / recover
    // ════════════════════════════════════════════════════════════════

    function testPauseBlocksDeposit() public {
        vm.prank(OWNER);
        bodaSavings.pause();
        vm.prank(USER);
        vm.expectRevert();
        bodaSavings.deposit(DEPOSIT_AMOUNT);
    }

    function testPauseBlocksDepositWithPermit() public {
        vm.prank(OWNER);
        bodaSavings.pause();

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(USER_PK, address(bodaSavings), DEPOSIT_AMOUNT, deadline);

        vm.prank(USER);
        vm.expectRevert();
        bodaSavings.depositWithPermit(DEPOSIT_AMOUNT, deadline, v, r, s);
    }

    function testUnpauseRestoresDeposit() public {
        vm.startPrank(OWNER);
        bodaSavings.pause();
        bodaSavings.unpause();
        vm.stopPrank();

        vm.prank(USER);
        bodaSavings.deposit(DEPOSIT_AMOUNT);
    }

    function testSetAutoApprovalThreshold() public {
        vm.expectEmit(false, false, false, true);
        emit BodaBodaSavings.AutoApprovalThresholdUpdated(50e6, 100e6);
        vm.prank(OWNER);
        bodaSavings.setAutoApprovalThreshold(100e6);
        assertEq(bodaSavings.autoApprovalThreshold(), 100e6);
    }

    function testSetAutoApprovalThresholdOnlyOwner() public {
        vm.prank(STRANGER);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER)
        );
        bodaSavings.setAutoApprovalThreshold(100e6);
    }

    function testSetStablecoinRevertsIfSavingsHeldNonZero() public {
        vm.prank(USER);
        bodaSavings.deposit(DEPOSIT_AMOUNT);

        MockUSDC newToken = new MockUSDC(10e6, OWNER);
        vm.prank(OWNER);
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__OutstandingAccounting.selector);
        bodaSavings.setStablecoin(address(newToken));
    }

    function testSetStablecoinRevertsIfDecimalsMismatch() public {
        Decimals18Token t18 = new Decimals18Token();
        vm.prank(OWNER);
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__DecimalsMismatch.selector);
        bodaSavings.setStablecoin(address(t18));
    }

    function testSetStablecoinSuccessWhenAllAccountingZero() public {
        MockUSDC newToken = new MockUSDC(10e6, OWNER);
        address  old      = address(bodaSavings.stablecoin());

        vm.prank(OWNER);
        vm.expectEmit(true, true, false, false);
        emit BodaBodaSavings.StablecoinUpdated(old, address(newToken));
        bodaSavings.setStablecoin(address(newToken));

        assertEq(address(bodaSavings.stablecoin()), address(newToken));
    }

    function testRecoverERC20Success() public {
        MockUSDC other = new MockUSDC(10e6, OWNER);
        vm.prank(OWNER);
        other.ownerMint(address(bodaSavings), 5e6);

        uint256 before = other.balanceOf(OWNER);
        vm.prank(OWNER);
        bodaSavings.recoverERC20(address(other), OWNER, 5e6);
        assertEq(other.balanceOf(OWNER) - before, 5e6);
    }

    function testRecoverERC20RevertsIfStablecoin() public {
        vm.prank(OWNER);
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__CannotRecoverStablecoin.selector);
        bodaSavings.recoverERC20(address(mockUSDC), OWNER, 1e6);
    }

    function testOnlyOwnerCanPause() public {
        vm.prank(STRANGER);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER)
        );
        bodaSavings.pause();
    }

    // ════════════════════════════════════════════════════════════════
    //         9. OWNABLE2STEP  [SEC-A]  +  SOLVENCY  [V4-7]
    // ════════════════════════════════════════════════════════════════

    function testOwnershipTransferIsTwoStep() public {
        vm.prank(OWNER);
        bodaSavings.transferOwnership(NEW_OWNER);

        assertEq(bodaSavings.owner(),        OWNER);       // unchanged until accepted
        assertEq(bodaSavings.pendingOwner(), NEW_OWNER);

        vm.prank(NEW_OWNER);
        bodaSavings.acceptOwnership();
        assertEq(bodaSavings.owner(), NEW_OWNER);
    }

    function testAcceptOwnershipRevertsForNonPending() public {
        vm.prank(OWNER);
        bodaSavings.transferOwnership(NEW_OWNER);

        vm.prank(STRANGER);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER)
        );
        bodaSavings.acceptOwnership();
    }

    function testIsSolventAndTotalObligations() public {
        vm.prank(USER);
        bodaSavings.deposit(DEPOSIT_AMOUNT);
        assertTrue(bodaSavings.isSolvent());
        assertEq(bodaSavings.getTotalObligations(), DEPOSIT_AMOUNT);  // 500 sav + 500 loan
    }

    function testSolvencyHoldsThroughSettlement() public {
        vm.prank(USER);
        bodaSavings.deposit(DEPOSIT_AMOUNT);
        _warpPastSettlement(USER);
        bodaSavings.settleLoanRepayment(USER);

        assertTrue(bodaSavings.isSolvent());
        assertEq(bodaSavings.getTotalObligations(), 500e6);          // savings only now
    }

    // ════════════════════════════════════════════════════════════════
    //        10. FEE-ON-TRANSFER CREDITING  [SEC-B]
    // ════════════════════════════════════════════════════════════════

    function testDepositCreditsActualReceivedNotRequested() public {
        FeeOnTransferToken fee  = new FeeOnTransferToken();   // 1% fee, 6 decimals
        BodaBodaSavings   fresh = _deployWith(address(fee));

        address rider = address(0xFEE1);
        vm.prank(rider);
        fresh.registerRider(
            "Fee Rider", 30, bytes1(0x4d),
            LENDER_WEEKLY, BodaBodaSavings.SplitRatio.SPLIT_50_50,
            LOAN_TARGET, KYC_HASH, KYC_FULL_LEVEL, licenseExpiry, KYC_PROVIDER
        );

        fee.mint(rider, 1_000e6);
        vm.prank(rider);
        fee.approve(address(fresh), type(uint256).max);

        vm.prank(rider);
        fresh.deposit(1_000e6);                              // 1% fee -> 990e6 arrives

        BodaBodaSavings.RiderAnalyticsView memory a = fresh.getRiderAnalytics(rider);
        assertEq(a.savingsBalance + a.loanBalance, 990e6);   // credited the real delta
        assertEq(a.totalDeposited, 990e6);
        assertEq(fresh.getContractBalance(), 990e6);
    }

    // ════════════════════════════════════════════════════════════════
    //   10.5 RELAYER / creditDeposit  [V4.1-1][V4.1-2] — off-chain fiat rail leg
    // ════════════════════════════════════════════════════════════════

    address constant RELAYER = address(0xBEE5);

    /// @dev Funds the relayer with mockUSDC and approves the contract, mirroring
    ///      what a real backend wallet must do before calling creditDeposit().
    function _setUpRelayer(uint256 relayerBalance) internal {
        vm.prank(OWNER);
        bodaSavings.setRelayer(RELAYER);

        vm.prank(OWNER);
        mockUSDC.ownerMint(RELAYER, relayerBalance);

        vm.prank(RELAYER);
        mockUSDC.approve(address(bodaSavings), type(uint256).max);
    }

    function testSetRelayerOnlyOwner() public {
        vm.prank(STRANGER);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER)
        );
        bodaSavings.setRelayer(RELAYER);
    }

    function testSetRelayerEmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit BodaBodaSavings.RelayerUpdated(address(0), RELAYER);
        vm.prank(OWNER);
        bodaSavings.setRelayer(RELAYER);
        assertEq(bodaSavings.relayer(), RELAYER);
    }

    function testCreditDepositRevertsIfCallerNotRelayer() public {
        _setUpRelayer(1_000e6);
        vm.prank(STRANGER); // not the configured relayer
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__NotRelayer.selector);
        bodaSavings.creditDeposit(USER, 100e6);
    }

    function testCreditDepositRevertsIfNoRelayerConfigured() public {
        // Fresh deploy, relayer never set (still address(0)) — unreachable by design.
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__NotRelayer.selector);
        bodaSavings.creditDeposit(USER, 100e6);
    }

    function testCreditDepositRevertsIfRiderNotRegistered() public {
        _setUpRelayer(1_000e6);
        vm.prank(RELAYER);
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__RiderNotRegistered.selector);
        bodaSavings.creditDeposit(STRANGER, 100e6);
    }

    function testCreditDepositRevertsIfZeroAmount() public {
        _setUpRelayer(1_000e6);
        vm.prank(RELAYER);
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__ZeroDeposit.selector);
        bodaSavings.creditDeposit(USER, 0);
    }

    function testCreditDepositRevertsIfZeroAddressRider() public {
        _setUpRelayer(1_000e6);
        vm.prank(RELAYER);
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__ZeroAddress.selector);
        bodaSavings.creditDeposit(address(0), 100e6);
    }

    /// @dev Not a mint: if the relayer hasn't approved/funded itself, the underlying
    ///      SafeERC20 transferFrom reverts exactly as it would for a normal deposit.
    function testCreditDepositRevertsIfRelayerHasInsufficientBalance() public {
        vm.prank(OWNER);
        bodaSavings.setRelayer(RELAYER);
        // Deliberately skip minting/approving — relayer holds and has approved nothing.
        vm.prank(RELAYER);
        vm.expectRevert();
        bodaSavings.creditDeposit(USER, 100e6);
    }

    function testCreditDepositAppliesSameSplitAsWalletDeposit() public {
        _setUpRelayer(1_000e6);

        vm.prank(RELAYER);
        bodaSavings.creditDeposit(USER, DEPOSIT_AMOUNT); // USER is 50/50

        BodaBodaSavings.RiderAnalyticsView memory a = _analytics(USER);
        assertEq(a.savingsBalance, DEPOSIT_AMOUNT / 2);
        assertEq(a.loanBalance,    DEPOSIT_AMOUNT / 2);
        assertEq(a.totalDeposited, DEPOSIT_AMOUNT);
    }

    function testCreditDepositPullsFromRelayerNotRider() public {
        _setUpRelayer(1_000e6);

        uint256 riderBalBefore   = mockUSDC.balanceOf(USER);
        uint256 relayerBalBefore = mockUSDC.balanceOf(RELAYER);

        vm.prank(RELAYER);
        bodaSavings.creditDeposit(USER, DEPOSIT_AMOUNT);

        // Rider's own wallet balance is untouched — funds came from the relayer.
        assertEq(mockUSDC.balanceOf(USER), riderBalBefore);
        assertEq(relayerBalBefore - mockUSDC.balanceOf(RELAYER), DEPOSIT_AMOUNT);
    }

    function testCreditDepositRespectsLoanClearedRouting() public {
        // [V4-3] same routing as a wallet deposit once the loan target is met.
        _setUpRelayer(1_000e6);
        address rider = _setupClearedRider(); // cleared via wallet deposit + settlement

        vm.prank(RELAYER);
        bodaSavings.creditDeposit(rider, 100e6);

        BodaBodaSavings.RiderAnalyticsView memory a = _analytics(rider);
        assertEq(a.loanBalance,    0);       // nothing routed to loan
        assertEq(a.savingsBalance, 210e6);   // 110e6 prior + full 100e6 credited deposit
    }

    function testCreditDepositEmitsDepositCreditedEvent() public {
        _setUpRelayer(1_000e6);

        vm.expectEmit(true, true, false, true);
        emit BodaBodaSavings.DepositCredited(
            USER, RELAYER, DEPOSIT_AMOUNT, DEPOSIT_AMOUNT / 2, DEPOSIT_AMOUNT / 2, block.timestamp
        );
        vm.prank(RELAYER);
        bodaSavings.creditDeposit(USER, DEPOSIT_AMOUNT);
    }

    function testCreditDepositBlockedWhenPaused() public {
        _setUpRelayer(1_000e6);
        vm.prank(OWNER);
        bodaSavings.pause();

        vm.prank(RELAYER);
        vm.expectRevert(); // Pausable: EnforcedPause
        bodaSavings.creditDeposit(USER, DEPOSIT_AMOUNT);
    }

    function testCreditDepositMaintainsSolvencyInvariant() public {
        _setUpRelayer(1_000e6);

        vm.prank(RELAYER);
        bodaSavings.creditDeposit(USER, DEPOSIT_AMOUNT);

        assertTrue(bodaSavings.isSolvent());
        assertEq(bodaSavings.getTotalObligations(), DEPOSIT_AMOUNT);
        assertGe(bodaSavings.getContractBalance(), bodaSavings.getTotalObligations());
    }

    function testCreditDepositUpdatesAggregatesLikeWalletDeposit() public {
        _setUpRelayer(1_000e6);

        uint256 savingsBefore  = bodaSavings.totalSavingsHeld();
        uint256 unsettledBefore = bodaSavings.totalUnsettledLoanBalance();

        vm.prank(RELAYER);
        bodaSavings.creditDeposit(USER, DEPOSIT_AMOUNT);

        assertEq(bodaSavings.totalSavingsHeld() - savingsBefore, DEPOSIT_AMOUNT / 2);
        assertEq(bodaSavings.totalUnsettledLoanBalance() - unsettledBefore, DEPOSIT_AMOUNT / 2);
    }

    /// @dev [V4.1-1] On-chain idempotency is explicitly NOT enforced — calling
    ///      creditDeposit() twice for "the same" off-chain payment double-credits.
    ///      That's a documented design choice (responsibility sits with the backend
    ///      ledger), and this test exists to make the behaviour explicit rather than
    ///      implicitly assumed.
    function testCreditDepositCalledTwiceDoubleCredits() public {
        _setUpRelayer(2_000e6);

        vm.prank(RELAYER);
        bodaSavings.creditDeposit(USER, DEPOSIT_AMOUNT);
        vm.prank(RELAYER);
        bodaSavings.creditDeposit(USER, DEPOSIT_AMOUNT); // same "invoice" in spirit

        BodaBodaSavings.RiderAnalyticsView memory a = _analytics(USER);
        assertEq(a.totalDeposited, DEPOSIT_AMOUNT * 2); // double-credited, as documented
    }

    function testFuzzCreditDepositSplitAlwaysSumsToTotal(uint256 amount) public {
        amount = bound(amount, 2, 5_000e6);
        _setUpRelayer(amount);

        vm.prank(RELAYER);
        bodaSavings.creditDeposit(USER, amount);

        BodaBodaSavings.RiderAnalyticsView memory a = _analytics(USER);
        assertEq(a.savingsBalance + a.loanBalance, amount);
    }

    // ════════════════════════════════════════════════════════════════
    //                  11. VIEW HELPER TESTS
    // ════════════════════════════════════════════════════════════════

    function testGetRiderProfileReturnsCorrectData() public view {
        BodaBodaSavings.RiderProfileView memory p = bodaSavings.getRiderProfile(USER);
        assertEq(p.name, RIDER_NAME);
        assertEq(p.age,  RIDER_AGE);
        assertTrue(p.gender == RIDER_GENDER);
        assertTrue(p.registered);
        assertEq(p.lenderAddress, LENDER_WEEKLY);
        assertEq(p.lenderName,    "Mwanga Haba SACCO");
        assertEq(uint8(p.lenderSchedule), uint8(BodaBodaSavings.RepaymentSchedule.WEEKLY));
    }

    function testGetRiderReturnsRawStruct() public view {
        BodaBodaSavings.Rider memory r = bodaSavings.getRider(USER);
        assertEq(r.name,       RIDER_NAME);
        assertEq(r.loanTarget, LOAN_TARGET);
        assertTrue(r.registered);
    }

    function testGetLoanStatusProgress() public {
        vm.prank(USER);
        bodaSavings.deposit(DEPOSIT_AMOUNT);
        _warpPastSettlement(USER);
        bodaSavings.settleLoanRepayment(USER);

        (
            uint256 target,
            uint256 loanBal,
            uint256 repaid,
            uint256 remaining,
            bool    cleared,
            uint256 bps
        ) = bodaSavings.getLoanStatus(USER);

        assertEq(target,    LOAN_TARGET);
        assertEq(loanBal,   0);
        assertEq(repaid,    DEPOSIT_AMOUNT / 2);
        assertEq(remaining, LOAN_TARGET - DEPOSIT_AMOUNT / 2);
        assertFalse(cleared);
        assertEq(bps, (repaid * 10_000) / target);
    }

    function testGetIdleLoanBalance() public {
        vm.prank(USER);
        bodaSavings.deposit(DEPOSIT_AMOUNT);
        assertEq(bodaSavings.getIdleLoanBalance(), DEPOSIT_AMOUNT / 2);

        _warpPastSettlement(USER);
        bodaSavings.settleLoanRepayment(USER);
        assertEq(bodaSavings.getIdleLoanBalance(), 0);
    }

    function testGetContractBalance() public {
        vm.prank(USER);
        bodaSavings.deposit(DEPOSIT_AMOUNT);
        assertEq(bodaSavings.getContractBalance(), DEPOSIT_AMOUNT);
    }

    function testGetRepaymentHistoryRecordsSettlement() public {
        vm.prank(USER);
        bodaSavings.deposit(DEPOSIT_AMOUNT);
        _warpPastSettlement(USER);
        vm.prank(STRANGER);
        bodaSavings.settleLoanRepayment(USER);

        BodaBodaSavings.RepaymentRecord[] memory hist = bodaSavings.getRepaymentHistory(USER);
        assertEq(hist.length,        1);
        assertEq(hist[0].amount,     500e6);
        assertTrue(hist[0].autoTriggered);              // settled by a third party
    }

    function testIsVerifiedRiderReturnsFalseForStranger() public view {
        assertFalse(bodaSavings.isVerifiedRider(STRANGER));
    }

    // ════════════════════════════════════════════════════════════════
    //                     12. FUZZ TESTS
    // ════════════════════════════════════════════════════════════════

    function testFuzzDepositSplitAlwaysSumsToTotal(uint256 amount) public {
        amount = bound(amount, 2, INITIAL_BALANCE);
        vm.prank(OWNER);
        mockUSDC.ownerMint(USER, amount);

        vm.prank(USER);
        bodaSavings.deposit(amount);

        BodaBodaSavings.RiderAnalyticsView memory a = _analytics(USER);
        assertEq(a.savingsBalance + a.loanBalance, amount);
    }

    function testFuzzDepositWithPermitSplitSumsToTotal(uint256 amount) public {
        amount = bound(amount, 2, INITIAL_BALANCE);

        vm.prank(USER);
        mockUSDC.approve(address(bodaSavings), 0);
        vm.prank(OWNER);
        mockUSDC.ownerMint(USER, amount);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(USER_PK, address(bodaSavings), amount, deadline);

        vm.prank(USER);
        bodaSavings.depositWithPermit(amount, deadline, v, r, s);

        BodaBodaSavings.RiderAnalyticsView memory a = _analytics(USER);
        assertEq(a.savingsBalance + a.loanBalance, amount);
    }

    function testFuzzTotalSavingsHeldTracksFirstDeposit(uint256 amount) public {
        amount = bound(amount, 2, INITIAL_BALANCE);
        vm.prank(OWNER);
        mockUSDC.ownerMint(USER, amount);

        vm.prank(USER);
        bodaSavings.deposit(amount);

        BodaBodaSavings.RiderAnalyticsView memory a = _analytics(USER);
        assertEq(bodaSavings.totalSavingsHeld(), a.savingsBalance);
    }

    function testFuzzSettlementSweepsFullLoanBalance(uint256 amount) public {
        // Bound so the loan portion never exceeds the target (no excess-to-savings).
        amount = bound(amount, 2, LOAN_TARGET);
        vm.prank(OWNER);
        mockUSDC.ownerMint(USER, amount);

        vm.prank(USER);
        bodaSavings.deposit(amount);

        uint256 loanBefore   = _analytics(USER).loanBalance;
        _warpPastSettlement(USER);
        uint256 lenderBefore = mockUSDC.balanceOf(LENDER_WEEKLY);

        bodaSavings.settleLoanRepayment(USER);

        assertEq(mockUSDC.balanceOf(LENDER_WEEKLY) - lenderBefore, loanBefore);
        assertEq(_analytics(USER).loanBalance, 0);
    }

    function testFuzzSolvencyInvariantHolds(uint256 amount) public {
        amount = bound(amount, 2, INITIAL_BALANCE);
        vm.prank(OWNER);
        mockUSDC.ownerMint(USER, amount);

        vm.prank(USER);
        bodaSavings.deposit(amount);

        assertTrue(bodaSavings.isSolvent());
        assertGe(
            bodaSavings.getContractBalance(),
            bodaSavings.getTotalObligations()
        );
    }
}

// ════════════════════════════════════════════════════════════════════
//                       TEST-ONLY HELPER TOKENS
// ════════════════════════════════════════════════════════════════════

/// @dev Minimal ERC20 that charges a 1% fee on every transfer, used to verify
///      [SEC-B]: the contract credits the actual received delta, not the requested
///      amount. Implements only what BodaBodaSavings.deposit() touches.
contract FeeOnTransferToken {
    string  public name     = "Fee";
    string  public symbol   = "FEE";
    uint256 public totalSupply;
    uint256 public constant feeBps = 100; // 1%

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function decimals() external pure returns (uint8) { return 6; }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply   += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _xfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _xfer(from, to, amount);
        return true;
    }

    function _xfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        uint256 fee = (amount * feeBps) / 10_000;
        balanceOf[from] -= amount;
        balanceOf[to]   += amount - fee;
        totalSupply     -= fee;                 // fee burned
    }
}

/// @dev Minimal token reporting 18 decimals, used to verify the setStablecoin()
///      decimals-parity guard [AUD-4]. Only decimals() is ever called on it.
contract Decimals18Token {
    function decimals() external pure returns (uint8) { return 18; }
}

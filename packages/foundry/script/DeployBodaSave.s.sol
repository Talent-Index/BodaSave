// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Script, console } from "forge-std/Script.sol";
import { MockUSDC }         from "../src/MockUSDC.sol";
import { BodaBodaSavings }  from "../src/BodaSavings.sol";

/// @notice Deploys MockUSDC (ERC20Permit) and BodaBodaSavings (v4).
///
///         Demo lender setup
///         ──────────────────
///         Three placeholder lenders are registered at deployment:
///           • Mwanga Haba SACCO  — 7-day cycle   | WEEKLY  schedule
///           • Faulu MFB          — 30-day cycle  | MONTHLY schedule
///           • Kenya Women MFI    — 1-day cycle   | WEEKLY  schedule
///
///         The "cycle" is the lender's settlement cadence: how often a rider's
///         accumulated loanBalance is swept to the lender by settleLoanRepayment().
///         (v4 replaced the V3 pot lock/release with scheduled auto-settlement.)
///
///         Replace the lender addresses below with real wallets before deploying
///         to a public testnet or mainnet.
///
///         Constructor (unchanged from V3 → v4)
///         ─────────────────────────────────────
///           address             _stablecoin
///           address[]  memory   _lenderAddrs
///           string[]   memory   _lenderNames
///           uint256[]  memory   _cycles            ← settlement cadence (seconds)
///           RepaymentSchedule[] _schedules
///           address             initialOwner
///
/// @dev    Run with:
///         forge script script/DeployBodaSave.s.sol --rpc-url <RPC> \
///             --account <KEYSTORE> --broadcast --verify
contract Deploy is Script {

    // ── Placeholder lender addresses (replace before real deployment) ──
    address constant LENDER_MWANGA_HABA = address(0x1111);
    address constant LENDER_FAULU       = address(0x2222);
    address constant LENDER_KENYA_WOMEN = address(0x3333);

    function run() external {
        vm.startBroadcast();

        // ── 1. Deploy MockUSDC (has ERC20Permit for depositWithPermit) ──
        MockUSDC mockUSDC = new MockUSDC(
            100_000 * 10 ** 6,  // 100 000 mUSDC minted to deployer
            msg.sender
        );

        // ── 2. Build lender registry arrays ──────────────────────────────

        address[] memory lenderAddrs = new address[](3);
        lenderAddrs[0] = LENDER_MWANGA_HABA;
        lenderAddrs[1] = LENDER_FAULU;
        lenderAddrs[2] = LENDER_KENYA_WOMEN;

        string[] memory lenderNames = new string[](3);
        lenderNames[0] = "Mwanga Haba SACCO";
        lenderNames[1] = "Faulu MFB";
        lenderNames[2] = "Kenya Women MFI";

        uint256[] memory cycles = new uint256[](3);
        cycles[0] = 7 days;    // weekly settlement cadence
        cycles[1] = 30 days;   // monthly settlement cadence
        cycles[2] = 1 days;    // daily settlement cadence

        // [ID-3] RepaymentSchedule — surfaced on the Loan frontend tab
        BodaBodaSavings.RepaymentSchedule[] memory schedules =
            new BodaBodaSavings.RepaymentSchedule[](3);
        schedules[0] = BodaBodaSavings.RepaymentSchedule.WEEKLY;
        schedules[1] = BodaBodaSavings.RepaymentSchedule.MONTHLY;
        schedules[2] = BodaBodaSavings.RepaymentSchedule.WEEKLY;

        // ── 3. Deploy BodaBodaSavings v4 ─────────────────────────────────
        //
        //       PRODUCTION NOTE: replace msg.sender with a Gnosis Safe address.
        //       v4 uses Ownable2Step, so transferring ownership to the Safe is a
        //       two-step propose/accept — the Safe must call acceptOwnership().
        BodaBodaSavings savings = new BodaBodaSavings(
            address(mockUSDC),
            lenderAddrs,
            lenderNames,
            cycles,
            schedules,
            msg.sender
        );

        vm.stopBroadcast();

        // ── 4. Log deployed addresses ─────────────────────────────────────
        console.log("=== BodaSave v4 Deployment ===");
        console.log("MockUSDC deployed to:       ", address(mockUSDC));
        console.log("BodaBodaSavings deployed to:", address(savings));
        console.log("------------------------------");
        console.log("Lender[0] Mwanga Haba SACCO:", lenderAddrs[0]);
        console.log("  settlement cycle:  7 days | schedule: WEEKLY");
        console.log("Lender[1] Faulu MFB:        ", lenderAddrs[1]);
        console.log("  settlement cycle: 30 days | schedule: MONTHLY");
        console.log("Lender[2] Kenya Women MFI:  ", lenderAddrs[2]);
        console.log("  settlement cycle:  1 day  | schedule: WEEKLY");
        console.log("------------------------------");
        console.log("Owner:                      ", msg.sender);
        console.log("Chain ID:                   ", block.chainid);
    }
}

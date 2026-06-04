// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Script, console } from "forge-std/Script.sol";
import { MockUSDC }         from "../src/MockUSDC.sol";
import { BodaBodaSavings }  from "../src/BodaSavings.sol";

/// @notice Deploys MockUSDC and BodaBodaSavings with a set of founding lenders.
///
///         Demo lender setup
///         ──────────────────
///         Three placeholder lenders are registered at deployment:
///           • Mwanga Haba SACCO  — weekly collection  (7 days)
///           • Faulu MFB          — monthly collection (30 days)
///           • Kenya Women MFI    — daily collection   (1 day)
///
///         Replace the addresses below with real lender wallets before
///         deploying to a public testnet or mainnet.
///
/// @dev    Run with:
///         forge script script/DeployBodaSave.s.sol --rpc-url <RPC> \
///             --account <KEYSTORE> --broadcast
contract Deploy is Script {

    // ── Placeholder lender addresses (replace before real deployment) ──
    address constant LENDER_MWANGA_HABA  = address(0x1111);
    address constant LENDER_FAULU        = address(0x2222);
    address constant LENDER_KENYA_WOMEN  = address(0x3333);

    function run() external {
        vm.startBroadcast();

        // 1. Deploy MockUSDC with 100,000 tokens minted to deployer
        MockUSDC mockUSDC = new MockUSDC(100_000 * 10 ** 6, msg.sender);

        // 2. Build lender registry arrays
        address[] memory lenderAddrs = new address[](3);
        lenderAddrs[0] = LENDER_MWANGA_HABA;
        lenderAddrs[1] = LENDER_FAULU;
        lenderAddrs[2] = LENDER_KENYA_WOMEN;

        string[] memory lenderNames = new string[](3);
        lenderNames[0] = "Mwanga Haba SACCO";
        lenderNames[1] = "Faulu MFB";
        lenderNames[2] = "Kenya Women MFI";

        uint256[] memory cycles = new uint256[](3);
        cycles[0] = 7 days;   // weekly
        cycles[1] = 30 days;  // monthly
        cycles[2] = 1 days;   // daily

        // 3. Deploy BodaBodaSavings (V2)
        BodaBodaSavings savings = new BodaBodaSavings(
            address(mockUSDC),
            lenderAddrs,
            lenderNames,
            cycles,
            msg.sender        // initialOwner — use a Gnosis Safe in production
        );

        vm.stopBroadcast();

        // 4. Log deployed addresses
        console.log("MockUSDC deployed to:       ", address(mockUSDC));
        console.log("BodaBodaSavings deployed to:", address(savings));
        console.log("Lender[0] Mwanga Haba SACCO:", lenderAddrs[0]);
        console.log("Lender[1] Faulu MFB:        ", lenderAddrs[1]);
        console.log("Lender[2] Kenya Women MFI:  ", lenderAddrs[2]);
    }
}

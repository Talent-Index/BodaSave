// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {BodaBodaSavings} from "../src/BodaSavings.sol";

contract Deploy is Script {
    function run() external {
        // This will use the account from cast wallet
        vm.startBroadcast();

        // Deploy MockUSDC with 100,000 tokens
        MockUSDC mockUSDC = new MockUSDC(100000 * 10 ** 6, msg.sender);

        // Deploy BodaBodaSavings
        BodaBodaSavings savings = new BodaBodaSavings(address(mockUSDC), msg.sender);

        vm.stopBroadcast();

        // Log addresses
        console.log("MockUSDC deployed to:", address(mockUSDC));
        console.log("BodaBodaSavings deployed to:", address(savings));
    }
}

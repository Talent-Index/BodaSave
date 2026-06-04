// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract TestMockUSDC is Test {
    MockUSDC mockUSDC;
    address USER = makeAddr("user");

    ////////////////////////////
    //     Setup Function     //
    ////////////////////////////

    function setUp() public {
        mockUSDC = new MockUSDC(1_000_000e6, address(this));
        mockUSDC.ownerMint(USER, 500_000e6);
    }

    ////////////////////////////
    //   Constructor Tests    //
    ////////////////////////////

    function testConstructorMintsInitialSupply() public view {
        assertEq(mockUSDC.balanceOf(address(this)), 1_000_000e6);
    }

    function testDecimalsIsSix() public view {
        assertEq(mockUSDC.decimals(), 6);
    }

    ////////////////////////////
    //      Minting Tests     //
    ////////////////////////////

    function testOwnerMintSuccess() public {
        uint256 beforeBalance = mockUSDC.balanceOf(USER);
        mockUSDC.ownerMint(USER, 100_000e6);
        uint256 afterBalance = mockUSDC.balanceOf(USER);

        assertEq(afterBalance - beforeBalance, 100_000e6);
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

    ////////////////////////////
    //       Faucet Tests     //
    ////////////////////////////

    function testFaucetSuccess() public {
        vm.startPrank(USER);
        uint256 beforeBalance = mockUSDC.balanceOf(USER);

        mockUSDC.faucet(100 * 10 ** mockUSDC.decimals());

        uint256 afterBalance = mockUSDC.balanceOf(USER);
        vm.stopPrank();

        assertEq(afterBalance - beforeBalance, 100 * 10 ** mockUSDC.decimals());
    }

    function testFaucetRevertsIfExceedsLimit() public {
        vm.prank(USER);
        uint256 exceedAmount = 1001 * 10 ** mockUSDC.decimals();
        vm.expectRevert("Faucet limit exceeded");
        mockUSDC.faucet(exceedAmount);
    }

    ////////////////////////////
    //     Transfer Tests     //
    ////////////////////////////

    function testTransferBetweenAccounts() public {
        vm.prank(USER);
        mockUSDC.transfer(address(0xBEEF), 50_000e6);
        assertEq(mockUSDC.balanceOf(address(0xBEEF)), 50_000e6);
    }

    function testApproveAndTransferFrom() public {
        mockUSDC.approve(USER, 10_000e6);
        vm.prank(USER);
        mockUSDC.transferFrom(address(this), USER, 10_000e6);
        assertEq(mockUSDC.balanceOf(USER), 510_000e6);
    }
}

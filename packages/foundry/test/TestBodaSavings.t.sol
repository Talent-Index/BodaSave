// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { BodaBodaSavings } from "../src/BodaSavings.sol";
import { MockUSDC } from "../src/MockUSDC.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";


contract TestBodaSavings is Test {
    BodaBodaSavings bodaSavings;
    MockUSDC mockUSDC;
    address USER = makeAddr("user");

    uint256 public constant INITIAL_BALANCE = 1000e6;

    function setUp() public {
        mockUSDC = new MockUSDC(20_000_000e6, address(this));
        bodaSavings = new BodaBodaSavings(address(mockUSDC), address(this));
        mockUSDC.ownerMint(USER, INITIAL_BALANCE);
    }

    ////////////////////////////
    //     Deposit Tests      //
    ////////////////////////////

    function testDepositRevertIfAmountIsZero() public {
        vm.prank(USER);
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__ZeroDeposit.selector);
        bodaSavings.deposit(0);
    }

    function testDepositSuccess() public {
        vm.startPrank(USER);
        mockUSDC.approve(address(bodaSavings), INITIAL_BALANCE);
        vm.expectEmit(true, true, true, true);
        emit BodaBodaSavings.Deposit(USER, INITIAL_BALANCE, INITIAL_BALANCE / 2, INITIAL_BALANCE / 2);
        bodaSavings.deposit(INITIAL_BALANCE);
        vm.stopPrank();

        (uint256 savings, uint256 loanRepaid) = bodaSavings.getBalances(USER);
        assertEq(savings, INITIAL_BALANCE / 2);
        assertEq(loanRepaid, INITIAL_BALANCE / 2);
        assertEq(bodaSavings.totalLoanCredits(), INITIAL_BALANCE / 2);
        assertEq(mockUSDC.balanceOf(address(bodaSavings)), INITIAL_BALANCE);
    }

    //////////////////////////////
    //  Withdraw Savings Tests  //
    //////////////////////////////

    function testWithdrawSavingsRevertsIfAmountIsZero() public {
        vm.prank(USER);
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__ZeroWithdraw.selector);
        bodaSavings.withdrawSavings(0);
    }

    function testWithdrawSavingsSuccess() public {
        vm.startPrank(USER);
        mockUSDC.approve(address(bodaSavings), INITIAL_BALANCE);
        bodaSavings.deposit(INITIAL_BALANCE);
        vm.stopPrank();

        vm.startPrank(USER);
        vm.expectEmit(true, true, true, true);
        emit BodaBodaSavings.WithdrawSavings(USER, 250e6);
        bodaSavings.withdrawSavings(250e6);
        vm.stopPrank();

        (uint256 savings, ) = bodaSavings.getBalances(USER);
        assertEq(savings, (INITIAL_BALANCE / 2) - 250e6);
    }

    function testWithdrawSavingsRevertIfInsufficientSavings() public {
        vm.startPrank(USER);
        mockUSDC.approve(address(bodaSavings), INITIAL_BALANCE);
        bodaSavings.deposit(INITIAL_BALANCE);
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__InsufficientSavings.selector);
        bodaSavings.withdrawSavings(INITIAL_BALANCE);
        vm.stopPrank();
    }

    /////////////////////////////
    //   Loan Pool Tests       //
    /////////////////////////////

    function testWithdrawLoanPoolSuccess() public {
        vm.startPrank(USER);
        mockUSDC.approve(address(bodaSavings), INITIAL_BALANCE);
        bodaSavings.deposit(INITIAL_BALANCE);
        vm.stopPrank();

        uint256 beforeBalance = mockUSDC.balanceOf(address(this));
        bodaSavings.withdrawLoanPool(address(this), 500e6);
        uint256 afterBalance = mockUSDC.balanceOf(address(this));

        assertEq(afterBalance - beforeBalance, 500e6);
    }

    function testWithdrawLoanPoolRevertIfNotOwner() public {
        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                USER
            )
        );
        bodaSavings.withdrawLoanPool(USER, 100e6);
    }

    ////////////////////////////////
    //   Stablecoin Set Tests     //
    ////////////////////////////////

    function testSetStablecoinRevertIfAddressZero() public {
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__StableCoinCannotBeAddressZero.selector);
        bodaSavings.setStablecoin(address(0));
    }

    /////////////////////////////
    //   ERC20 Recovery Tests  //
    /////////////////////////////

    function testRecoverERC20Success() public {
        MockUSDC otherToken = new MockUSDC(10e6, address(this));
        otherToken.transfer(address(bodaSavings), 5e6);

        uint256 beforeBalance = otherToken.balanceOf(address(this));
        bodaSavings.recoverERC20(address(otherToken), address(this), 5e6);
        uint256 afterBalance = otherToken.balanceOf(address(this));

        assertEq(afterBalance - beforeBalance, 5e6);
    }

    function testRecoverERC20RevertIfTokenIsStablecoin() public {
        vm.expectRevert(BodaBodaSavings.BodaBodaSavings__CannotWithdrawStablecoinViaRecover.selector);
        bodaSavings.recoverERC20(address(mockUSDC), address(this), 1e6);
    }

    function testConstructorRevertIfStablecoinZeroAddress() public {
    vm.expectRevert(BodaBodaSavings.BodaBodaSavings__StableCoinCannotBeAddressZero.selector);
    new BodaBodaSavings(address(0), address(this));
}


function testRecoverERC20RevertIfRecipientZero() public {
    MockUSDC otherToken = new MockUSDC(10e6, address(this));
    vm.expectRevert(BodaBodaSavings.BodaBodaSavings__ZeroAddressRecipient.selector);
    bodaSavings.recoverERC20(address(otherToken), address(0), 1e6);
}

function testRecoverERC20RevertIfTokenZero() public {
    vm.expectRevert(BodaBodaSavings.BodaBodaSavings__ZeroAddressToken.selector);
    bodaSavings.recoverERC20(address(0), address(this), 1e6);
}

function testSetStablecoinSuccess() public {
    MockUSDC newToken = new MockUSDC(10e6, address(this));
    address oldStablecoin = address(bodaSavings.stablecoin());

    vm.expectEmit(true, true, true, true);
    emit BodaBodaSavings.StablecoinUpdated(oldStablecoin, address(newToken));

    bodaSavings.setStablecoin(address(newToken));
    assertEq(address(bodaSavings.stablecoin()), address(newToken));
}

function testGetAvailableLoanPoolAndBalance() public {
    vm.startPrank(USER);
    mockUSDC.approve(address(bodaSavings), 1000e6);
    bodaSavings.deposit(1000e6);
    vm.stopPrank();

    assertEq(bodaSavings.getAvailableLoanPool(), 500e6);
    assertEq(bodaSavings.getContractBalance(), 1000e6);
}


}

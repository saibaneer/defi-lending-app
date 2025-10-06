// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SimpleLendingMarket} from "./Market.sol";

contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract SimpleLendingMarket_DepositTest is Test {
    MockERC20 internal usdc;
    SimpleLendingMarket internal vault;

    address internal alice = address(0xA11CE);

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "mUSDC");
        vault = new SimpleLendingMarket(IERC20(address(usdc)), "Vault Shares", "vShare");

        usdc.mint(alice, 1_000_000e18);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }


    function testDepositMintsAndIssuesShares() public {
        uint256 amount = 10_000e18;

        //Check before deposit
        assertEq(usdc.balanceOf(alice), 1_000_000e18, "pre: alice balance not equal");
        assertEq(usdc.balanceOf(address(vault)), 0, "pre: vault balance not equal");
        assertEq(vault.totalSupply(), 0, "pre: no shares");

        //Check events
        vm.startPrank(alice);
        vm.expectEmit(true, false, false, true);
        emit SimpleLendingMarket.Deposited(alice, amount, amount);
        vault.depositLoanAsset(amount);
        vm.stopPrank();

        //Check state after deposit
        assertEq(usdc.balanceOf(alice), 1_000_000e18 - amount, "post: alice balance not equal");
        assertEq(usdc.balanceOf(address(vault)), amount, "post: vault balance not equal");
        assertEq(vault.balanceOf(alice), amount);
        assertEq(vault.totalSupply(), amount);
        assertEq(vault.rewardPerShare(), 0);

        (uint256 pendingRewards, uint256 checkpointRewardPerShare) = vault.lenderInfo(alice);
        assertEq(pendingRewards, 0);
        assertEq(checkpointRewardPerShare, 0);

    }
}

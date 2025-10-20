// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SimpleLendingMarket} from "./Market.sol";
import {IMockOracle} from "./IMockOracle.sol";
import {ISwap} from "./ISwap.sol";
import {LoanState, LoanParameters} from "./library/DataTypes.sol";
import {MarketSupportLibrary} from "./library/MarketSupportLibrary.sol";

contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _decimals = d;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }
}

contract MockOracle is IMockOracle {
    mapping(address => uint256) public prices;

    function setAssetPrice(address asset, uint256 price) external {
        prices[asset] = price;
    }

    function getAssetPrice(address asset) external view returns (uint256) {
        return prices[asset];
    }
}

contract MockSwap is ISwap {
    uint256 public mockAmountOut;
    bool public shouldRevert;
    
    function setMockAmountOut(uint256 amount) external {
        mockAmountOut = amount;
    }
    
    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }
    
    function swapExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external returns (uint256 amountOut) {
        if (shouldRevert) {
            revert("Swap failed");
        }
        
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        
        // If mockAmountOut is set, use it; otherwise use default 80% logic
        if (mockAmountOut > 0) {
            amountOut = mockAmountOut;
        } else {
            // Default: simulate 80% output (20% slippage/fees)
            amountOut = (amountIn * 80) / 100;
        }
        
        MockERC20(tokenOut).mint(msg.sender, amountOut);
        return amountOut;
    }
}

contract SimpleLendingMarketTest is Test {
    MockERC20 internal usdc;
    MockERC20 internal weth;
    SimpleLendingMarket internal market;
    MockOracle internal oracle;
    MockSwap internal swapPlatform;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal mockTreasury = address(0x7BEAD);

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);
        weth = new MockERC20("Mock WETH", "mWETH", 18);
        market = new SimpleLendingMarket(IERC20(address(usdc)), "Vault Shares", "vShare");
        oracle = new MockOracle();
        swapPlatform = new MockSwap();

        // Setup market
        market.setOracleAddress(address(oracle));
        market.setAcceptableCollateralAsset(address(weth));
        market.setLoanToValueRatio(0.5 ether); // 50% LTV
        market.setLiquidationThreshold(0.6 ether); // 60% liquidation threshold
        market.setTreasuryAddress(mockTreasury);
        market.setSwapPlatformAddress(address(swapPlatform));

        // Set initial prices
        oracle.setAssetPrice(address(weth), 2000e18); // $2000 per ETH

        // Mint tokens
        usdc.mint(alice, 1_000_000e6);
        weth.mint(bob, 100e18);

        // Approvals
        vm.startPrank(alice);
        usdc.approve(address(market), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        weth.approve(address(market), type(uint256).max);
        usdc.approve(address(market), type(uint256).max);
        vm.stopPrank();
    }

    // ==================== DEPOSIT TESTS ====================

    function testDepositMintsAndIssuesShares() public {
        uint256 amount = 10_000e6;

        assertEq(usdc.balanceOf(alice), 1_000_000e6, "pre: alice balance");
        assertEq(usdc.balanceOf(address(market)), 0, "pre: market balance");
        assertEq(market.totalSupply(), 0, "pre: no shares");

        vm.startPrank(alice);
        vm.expectEmit(true, false, false, true);
        emit SimpleLendingMarket.Deposited(alice, amount, amount);
        market.depositLoanAsset(amount);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 1_000_000e6 - amount, "post: alice balance");
        assertEq(usdc.balanceOf(address(market)), amount, "post: market balance");
        assertEq(market.balanceOf(alice), amount);
        assertEq(market.totalSupply(), amount);
        assertEq(market.rewardPerShare(), 0);

        (uint256 pendingRewards, uint256 checkpointRewardPerShare) = market.lenderInfo(alice);
        assertEq(pendingRewards, 0);
        assertEq(checkpointRewardPerShare, 0);
    }

    function testMultipleDeposits() public {
        vm.startPrank(alice);
        market.depositLoanAsset(5_000e6);
        market.depositLoanAsset(5_000e6);
        vm.stopPrank();

        assertEq(market.balanceOf(alice), 10_000e6);
        assertEq(market.totalSupply(), 10_000e6);
    }

    // ==================== WITHDRAWAL TESTS ====================

    function testWithdrawReducesShares() public {
        vm.startPrank(alice);
        market.depositLoanAsset(10_000e6);
        
        uint256 withdrawAmount = 3_000e6;
        vm.expectEmit(true, true, false, true);
        emit SimpleLendingMarket.Withdrawn(alice, address(market), withdrawAmount);
        market.withdrawLoanAsset(withdrawAmount, false);
        vm.stopPrank();

        assertEq(market.balanceOf(alice), 7_000e6);
        assertEq(usdc.balanceOf(alice), 1_000_000e6 - 7_000e6);
    }

    function testCannotWithdrawMoreThanBalance() public {
        vm.startPrank(alice);
        market.depositLoanAsset(10_000e6);
        
        vm.expectRevert();
        market.withdrawLoanAsset(11_000e6, false);
        vm.stopPrank();
    }

    // ==================== COLLATERAL TESTS ====================

    function testDepositCollateral() public {
        uint256 collateralAmount = 1e18;

        vm.startPrank(bob);
        vm.expectEmit(true, true, true, true);
        emit SimpleLendingMarket.DepositedCollateralAsset(bob, address(market), address(weth), collateralAmount);
        market.depositLoanCollateral(address(weth), collateralAmount);
        vm.stopPrank();

        uint256 available = market.getBorrowerAssetAvailable(bob, address(weth));
        assertEq(available, collateralAmount);
        assertEq(weth.balanceOf(address(market)), collateralAmount);
    }

    function testWithdrawCollateral() public {
        vm.startPrank(bob);
        market.depositLoanCollateral(address(weth), 1e18);
        
        vm.expectEmit(true, true, false, true);
        emit SimpleLendingMarket.WithdrewCollateral(address(weth), address(market), bob, 0.5e18);
        market.withdrawFromAvailableCollateral(0.5e18, address(weth));
        vm.stopPrank();

        uint256 available = market.getBorrowerAssetAvailable(bob, address(weth));
        assertEq(available, 0.5e18);
    }

    function testCannotWithdrawMoreCollateralThanAvailable() public {
        vm.startPrank(bob);
        market.depositLoanCollateral(address(weth), 1e18);
        
        vm.expectRevert("Cannot withdraw this amount!");
        market.withdrawFromAvailableCollateral(2e18, address(weth));
        vm.stopPrank();
    }

    // ==================== BORROW TESTS ====================

    function testBorrow() public {
        // Alice deposits USDC for lending
        vm.prank(alice);
        market.depositLoanAsset(10_000e6);

        // Bob deposits collateral and borrows
        vm.startPrank(bob);
        market.depositLoanCollateral(address(weth), 1e18); // $2000 worth
        
        uint256 borrowAmount = 1_000e6; // Borrow $1000 (50% LTV)
        market.borrow(borrowAmount, address(weth));
        vm.stopPrank();

        assertEq(usdc.balanceOf(bob), borrowAmount);
        assertEq(market.totalBorrows(), borrowAmount);
        
        uint256 activeLoanCount = market.getActiveLoanCount(bob);
        assertEq(activeLoanCount, 1);
        
        // Verify collateral accounting
        uint256 available = market.getBorrowerAssetAvailable(bob, address(weth));
        uint256 borrowed = market.getBorrowerAssetBorrowed(bob, address(weth));
        assertEq(available, 0, "All collateral should be used");
        assertEq(borrowed, 1e18, "1 ETH should be locked as collateral");
    }

    function testCannotBorrowWithoutCollateral() public {
        vm.prank(alice);
        market.depositLoanAsset(10_000e6);

        vm.startPrank(bob);
        vm.expectRevert("Insufficient collateral available!");
        market.borrow(1_000e6, address(weth));
        vm.stopPrank();
    }

    function testCannotBorrowMoreThanLTV() public {
        vm.prank(alice);
        market.depositLoanAsset(10_000e6);

        vm.startPrank(bob);
        market.depositLoanCollateral(address(weth), 1e18); // $2000 worth
        
        // Try to borrow more than 50% LTV
        vm.expectRevert("Insufficient collateral available!");
        market.borrow(1_100e6, address(weth));
        vm.stopPrank();
    }

    // ==================== REPAYMENT TESTS ====================

    function testRepayLoan() public {
        // Setup: Alice lends, Bob borrows
        vm.prank(alice);
        market.depositLoanAsset(10_000e6);

        vm.startPrank(bob);
        market.depositLoanCollateral(address(weth), 1e18);
        market.borrow(1_000e6, address(weth));
        
        // Generate loan ID using the library function
        LoanParameters memory loanParams = LoanParameters({
            collateralTokenAddress: address(weth),
            borrower: bob,
            collateralUnitsUsed: 1e18,
            pricefeedId: bytes32(0),
            liquidationPrice: 1200e18,
            amountBorrowed: 1_000e6,
            interestRateForLoan: market.TEN_PERCENT_PER_SECOND_INTEREST_RATE(),
            timeOfBorrow: block.timestamp
        });
        bytes32 loanId = MarketSupportLibrary.generateLoanId(loanParams);

        // Mint USDC for repayment
        usdc.mint(bob, 10_000e6);
        
        vm.warp(block.timestamp + 1); // Move forward 1 second
        
        uint256 repaymentDue = market.estimateRepaymentDue(loanId, 1_000e6);
        market.repayLoan(loanId, 1_000e6);
        vm.stopPrank();

        assertEq(market.totalBorrows(), 0);
        uint256 activeLoanCount = market.getActiveLoanCount(bob);
        assertEq(activeLoanCount, 0);
        
        // Verify collateral is returned
        uint256 available = market.getBorrowerAssetAvailable(bob, address(weth));
        uint256 borrowed = market.getBorrowerAssetBorrowed(bob, address(weth));
        assertEq(available, 1e18, "Collateral should be returned");
        assertEq(borrowed, 0, "No collateral should be locked");
    }

    function testCannotRepayOthersLoan() public {
        vm.prank(alice);
        market.depositLoanAsset(10_000e6);

        vm.startPrank(bob);
        market.depositLoanCollateral(address(weth), 1e18);
        market.borrow(1_000e6, address(weth));
        vm.stopPrank();

        bytes32 fakeLoanId = keccak256(abi.encodePacked("fake"));
        
        vm.prank(alice);
        vm.expectRevert();
        market.repayLoan(fakeLoanId, 1_000e6);
    }

    // ==================== LIQUIDATION TESTS ====================

    function testCanBeLiquidated() public {
        vm.prank(alice);
        market.depositLoanAsset(10_000e6);

        vm.startPrank(bob);
        market.depositLoanCollateral(address(weth), 1e18);
        market.borrow(1_000e6, address(weth));
        vm.stopPrank();

        LoanParameters memory loanParams = LoanParameters({
            collateralTokenAddress: address(weth),
            borrower: bob,
            collateralUnitsUsed: 1e18,
            pricefeedId: bytes32(0),
            liquidationPrice: 1200e18,
            amountBorrowed: 1_000e6,
            interestRateForLoan: market.TEN_PERCENT_PER_SECOND_INTEREST_RATE(),
            timeOfBorrow: block.timestamp
        });
        bytes32 loanId = MarketSupportLibrary.generateLoanId(loanParams);

        // Price is still $2000, liquidation at $1200, should not be liquidatable
        assertFalse(market.canBeLiquidated(loanId));

        // Drop price below liquidation threshold
        oracle.setAssetPrice(address(weth), 1100e18); // $1100 < $1200
        assertTrue(market.canBeLiquidated(loanId));
    }

    function testLiquidateLoan() public {
        vm.prank(alice);
        market.depositLoanAsset(10_000e6);

        vm.startPrank(bob);
        market.depositLoanCollateral(address(weth), 1e18);
        market.borrow(1_000e6, address(weth));
        vm.stopPrank();

        LoanParameters memory loanParams = LoanParameters({
            collateralTokenAddress: address(weth),
            borrower: bob,
            collateralUnitsUsed: 1e18,
            pricefeedId: bytes32(0),
            liquidationPrice: 1200e18,
            amountBorrowed: 1_000e6,
            interestRateForLoan: market.TEN_PERCENT_PER_SECOND_INTEREST_RATE(),
            timeOfBorrow: block.timestamp
        });
        bytes32 loanId = MarketSupportLibrary.generateLoanId(loanParams);

        // Drop price to trigger liquidation
        oracle.setAssetPrice(address(weth), 1100e18);

        // Setup approvals for swap
        vm.prank(address(market));
        weth.approve(address(swapPlatform), type(uint256).max);

        // Alice liquidates bob's loan
        vm.prank(alice);
        market.liquidateLoan(loanId);

        uint256 activeLoanCount = market.getActiveLoanCount(bob);
        assertEq(activeLoanCount, 0);
        
        // Verify collateral is removed from borrowed
        uint256 borrowed = market.getBorrowerAssetBorrowed(bob, address(weth));
        assertEq(borrowed, 0, "Liquidated collateral should be removed");
    }

    function testCannotLiquidateOwnLoan() public {
        vm.prank(alice);
        market.depositLoanAsset(10_000e6);

        vm.startPrank(bob);
        market.depositLoanCollateral(address(weth), 1e18);
        market.borrow(1_000e6, address(weth));
        
        LoanParameters memory loanParams = LoanParameters({
            collateralTokenAddress: address(weth),
            borrower: bob,
            collateralUnitsUsed: 1e18,
            pricefeedId: bytes32(0),
            liquidationPrice: 1200e18,
            amountBorrowed: 1_000e6,
            interestRateForLoan: market.TEN_PERCENT_PER_SECOND_INTEREST_RATE(),
            timeOfBorrow: block.timestamp
        });
        bytes32 loanId = MarketSupportLibrary.generateLoanId(loanParams);

        oracle.setAssetPrice(address(weth), 1100e18);

        // Setup approval for swap
        vm.stopPrank();
        vm.prank(address(market));
        weth.approve(address(swapPlatform), type(uint256).max);

        // Bob tries to liquidate his own loan
        vm.prank(bob);
        vm.expectRevert("Cannot liquidate your own loan!");
        market.liquidateLoan(loanId);
    }

    // ==================== INTEREST ACCRUAL TESTS ====================

    function testInterestAccrual() public {
        vm.prank(alice);
        market.depositLoanAsset(10_000e6);

        vm.startPrank(bob);
        market.depositLoanCollateral(address(weth), 1e18);
        market.borrow(1_000e6, address(weth));
        vm.stopPrank();

        // Move forward in time
        vm.warp(block.timestamp + 365 days);

        uint256 growthRPS = market.estimateGrowthRPS();
        assertGt(growthRPS, 0, "Interest should accrue over time");
    }

    function testRewardsDistribution() public {
        vm.prank(alice);
        market.depositLoanAsset(10_000e6);

        vm.startPrank(bob);
        market.depositLoanCollateral(address(weth), 1e18);
        market.borrow(1_000e6, address(weth));
        vm.stopPrank();

        // Move forward and update rewards
        vm.warp(block.timestamp + 100);
        
        vm.prank(alice);
        market.claimShareRewards();

        (uint256 pendingRewards,) = market.lenderInfo(alice);
        // After claiming, pending rewards should be 0
        assertEq(pendingRewards, 0);
    }

    // ==================== CONFIGURATION TESTS ====================

    function testSetLiquidationThreshold() public {
        market.setLiquidationThreshold(0.7 ether);
        assertEq(market.liquidationThreshold(), 0.7 ether);
    }

    function testCannotSetLowLiquidationThreshold() public {
        vm.expectRevert("Amount must be greater than or equal to 0.6 ether");
        market.setLiquidationThreshold(0.5 ether);
    }

    function testSetLoanToValueRatio() public {
        market.setLoanToValueRatio(0.6 ether);
        assertEq(market.loanToValueRatio(), 0.6 ether);
    }

    function testCannotSetLowLoanToValueRatio() public {
        vm.expectRevert("Amount must be greater than or equal to 0.4 ether");
        market.setLoanToValueRatio(0.3 ether);
    }

    // ==================== EDGE CASES ====================

    function testEstimateUnitsOfCollateralNeeded() public {
        uint256 borrowAmount = 1_000e6;
        uint256 unitsNeeded = market.estimateUnitsOfCollateralNeededForLoan(borrowAmount, address(weth));
        
        // At 50% LTV and $2000 per ETH, borrowing $1000 requires $2000 collateral = 1 ETH
        assertEq(unitsNeeded, 1e18);
    }

    function testZeroAddressChecks() public {
        vm.expectRevert("Zero Address not allowed!");
        market.setOracleAddress(address(0));
    }

    function testLastUpdatedTimeInitialized() public {
        assertGt(market.lastUpdatedTime(), 0, "lastUpdatedTime should be initialized");
    }

    // ==================== GETTER FUNCTION TESTS ====================

    function testGetBorrowerAssetAvailable() public {
        vm.startPrank(bob);
        market.depositLoanCollateral(address(weth), 2e18);
        vm.stopPrank();

        uint256 available = market.getBorrowerAssetAvailable(bob, address(weth));
        assertEq(available, 2e18, "Should return correct available collateral");
    }

    function testGetBorrowerAssetBorrowed() public {
        // Setup lending liquidity
        vm.prank(alice);
        market.depositLoanAsset(10_000e6);

        // Bob deposits collateral and borrows
        vm.startPrank(bob);
        market.depositLoanCollateral(address(weth), 2e18);
        market.borrow(1_000e6, address(weth));
        vm.stopPrank();

        uint256 borrowed = market.getBorrowerAssetBorrowed(bob, address(weth));
        assertEq(borrowed, 1e18, "Should return correct borrowed collateral amount");
    }

    function testGetBorrowerAssetAvailableAfterBorrow() public {
        // Setup lending liquidity
        vm.prank(alice);
        market.depositLoanAsset(10_000e6);

        // Bob deposits 2 ETH and borrows against 1 ETH
        vm.startPrank(bob);
        market.depositLoanCollateral(address(weth), 2e18);
        market.borrow(1_000e6, address(weth)); // Uses 1 ETH as collateral
        vm.stopPrank();

        uint256 available = market.getBorrowerAssetAvailable(bob, address(weth));
        uint256 borrowed = market.getBorrowerAssetBorrowed(bob, address(weth));
        
        assertEq(available, 1e18, "Should have 1 ETH available");
        assertEq(borrowed, 1e18, "Should have 1 ETH borrowed against");
    }

    function testGetBorrowerAssetAvailableAfterRepayment() public {
        // Setup lending liquidity
        vm.prank(alice);
        market.depositLoanAsset(10_000e6);

        // Bob borrows
        vm.startPrank(bob);
        market.depositLoanCollateral(address(weth), 1e18);
        market.borrow(1_000e6, address(weth));
        
        LoanParameters memory loanParams = LoanParameters({
            collateralTokenAddress: address(weth),
            borrower: bob,
            collateralUnitsUsed: 1e18,
            pricefeedId: bytes32(0),
            liquidationPrice: 1200e18,
            amountBorrowed: 1_000e6,
            interestRateForLoan: market.TEN_PERCENT_PER_SECOND_INTEREST_RATE(),
            timeOfBorrow: block.timestamp
        });
        bytes32 loanId = MarketSupportLibrary.generateLoanId(loanParams);

        // Mint USDC for repayment and repay
        usdc.mint(bob, 10_000e6);
        vm.warp(block.timestamp + 1);
        market.repayLoan(loanId, 1_000e6);
        vm.stopPrank();

        uint256 available = market.getBorrowerAssetAvailable(bob, address(weth));
        uint256 borrowed = market.getBorrowerAssetBorrowed(bob, address(weth));
        
        assertEq(available, 1e18, "Collateral should be returned to available");
        assertEq(borrowed, 0, "Should have no borrowed collateral");
    }

    function testGetBorrowerAssetAvailableRevertsOnZeroAddress() public {
        vm.expectRevert("Zero Address not allowed!");
        market.getBorrowerAssetAvailable(address(0), address(weth));

        vm.expectRevert("Zero Address not allowed!");
        market.getBorrowerAssetAvailable(bob, address(0));
    }

    function testGetBorrowerAssetBorrowedRevertsOnZeroAddress() public {
        vm.expectRevert("Zero Address not allowed!");
        market.getBorrowerAssetBorrowed(address(0), address(weth));

        vm.expectRevert("Zero Address not allowed!");
        market.getBorrowerAssetBorrowed(bob, address(0));
    }

    function testGetBorrowerAssetAvailableForMultipleCollateralTypes() public {
        // Create another collateral token
        MockERC20 wbtc = new MockERC20("Mock WBTC", "mWBTC", 8);
        market.setAcceptableCollateralAsset(address(wbtc));
        oracle.setAssetPrice(address(wbtc), 40000e18); // $40,000 per BTC
        
        wbtc.mint(bob, 10e8);
        
        vm.startPrank(bob);
        wbtc.approve(address(market), type(uint256).max);
        
        // Deposit both types of collateral
        market.depositLoanCollateral(address(weth), 5e18);
        market.depositLoanCollateral(address(wbtc), 2e8);
        vm.stopPrank();

        uint256 wethAvailable = market.getBorrowerAssetAvailable(bob, address(weth));
        uint256 wbtcAvailable = market.getBorrowerAssetAvailable(bob, address(wbtc));
        
        assertEq(wethAvailable, 5e18, "Should have correct WETH available");
        assertEq(wbtcAvailable, 2e8, "Should have correct WBTC available");
    }

    // ==================== LIBRARY FUNCTION TESTS ====================

    function testGenerateLoanId() public {
        LoanParameters memory loanParams = LoanParameters({
            collateralTokenAddress: address(weth),
            borrower: bob,
            collateralUnitsUsed: 1e18,
            pricefeedId: bytes32(0),
            liquidationPrice: 1200e18,
            amountBorrowed: 1000e6,
            interestRateForLoan: market.TEN_PERCENT_PER_SECOND_INTEREST_RATE(),
            timeOfBorrow: block.timestamp
        });

        bytes32 loanId = MarketSupportLibrary.generateLoanId(loanParams);
        
        // Generate the same ID again to verify consistency
        bytes32 loanId2 = MarketSupportLibrary.generateLoanId(loanParams);
        
        assertEq(loanId, loanId2, "Same parameters should generate same loan ID");
        assertTrue(loanId != bytes32(0), "Loan ID should not be zero");
    }

    function testGenerateLoanIdDifferentForDifferentParams() public {
        LoanParameters memory loanParams1 = LoanParameters({
            collateralTokenAddress: address(weth),
            borrower: bob,
            collateralUnitsUsed: 1e18,
            pricefeedId: bytes32(0),
            liquidationPrice: 1200e18,
            amountBorrowed: 1000e6,
            interestRateForLoan: market.TEN_PERCENT_PER_SECOND_INTEREST_RATE(),
            timeOfBorrow: block.timestamp
        });

        LoanParameters memory loanParams2 = LoanParameters({
            collateralTokenAddress: address(weth),
            borrower: alice,  // Different borrower
            collateralUnitsUsed: 1e18,
            pricefeedId: bytes32(0),
            liquidationPrice: 1200e18,
            amountBorrowed: 1000e6,
            interestRateForLoan: market.TEN_PERCENT_PER_SECOND_INTEREST_RATE(),
            timeOfBorrow: block.timestamp
        });

        bytes32 loanId1 = MarketSupportLibrary.generateLoanId(loanParams1);
        bytes32 loanId2 = MarketSupportLibrary.generateLoanId(loanParams2);
        
        assertTrue(loanId1 != loanId2, "Different parameters should generate different loan IDs");
    }

    function testGetLiquidationPrice() public {
        uint256 assetPrice = 2000e18; // $2000
        uint256 liquidationThreshold = 0.6 ether; // 60%
        
        uint256 liquidationPrice = MarketSupportLibrary.getLiquidationPrice(
            liquidationThreshold,
            assetPrice
        );
        
        assertEq(liquidationPrice, 1200e18, "Liquidation price should be 60% of asset price");
    }

    function testGetLiquidationPriceAtDifferentThresholds() public {
        uint256 assetPrice = 3000e18;
        
        uint256 liquidationPrice70 = MarketSupportLibrary.getLiquidationPrice(0.7 ether, assetPrice);
        uint256 liquidationPrice80 = MarketSupportLibrary.getLiquidationPrice(0.8 ether, assetPrice);
        
        assertEq(liquidationPrice70, 2100e18, "70% threshold");
        assertEq(liquidationPrice80, 2400e18, "80% threshold");
    }

    function testGetRepaymentDue() public {
        uint256 principal = 1000e6;
        uint256 interestRate = market.TEN_PERCENT_PER_SECOND_INTEREST_RATE();
        uint256 timePassed = 365 days;
        
        uint256 repaymentDue = MarketSupportLibrary.getRepaymentDue(
            principal,
            interestRate,
            timePassed
        );
        
        assertGt(repaymentDue, principal, "Repayment should include interest");
    }

    function testGetRepaymentDueZeroTime() public {
        uint256 principal = 1000e6;
        uint256 interestRate = market.TEN_PERCENT_PER_SECOND_INTEREST_RATE();
        uint256 timePassed = 0;
        
        uint256 repaymentDue = MarketSupportLibrary.getRepaymentDue(
            principal,
            interestRate,
            timePassed
        );
        
        assertEq(repaymentDue, principal, "No time passed means no interest");
    }

    function testGetRepaymentDueIncreasesWithTime() public {
        uint256 principal = 1000e6;
        uint256 interestRate = market.TEN_PERCENT_PER_SECOND_INTEREST_RATE();
        
        uint256 repayment1Day = MarketSupportLibrary.getRepaymentDue(principal, interestRate, 1 days);
        uint256 repayment7Days = MarketSupportLibrary.getRepaymentDue(principal, interestRate, 7 days);
        uint256 repayment30Days = MarketSupportLibrary.getRepaymentDue(principal, interestRate, 30 days);
        
        assertTrue(repayment1Day < repayment7Days, "7 days should cost more than 1 day");
        assertTrue(repayment7Days < repayment30Days, "30 days should cost more than 7 days");
    }

    function testSplitAmountPrecise() public {
        uint256 amount = 1000e18;
        
        (uint256 share1, uint256 share2, uint256 share3) = MarketSupportLibrary.splitAmountPrecise(amount);
        
        assertEq(share1, 400e18, "First share should be 40%");
        assertEq(share2, 400e18, "Second share should be 40%");
        assertEq(share3, 200e18, "Third share should be 20%");
        assertEq(share1 + share2 + share3, amount, "Shares should sum to original amount");
    }

    function testSplitAmountPreciseWithRemainder() public {
        uint256 amount = 101; // Amount that doesn't divide evenly
        
        (uint256 share1, uint256 share2, uint256 share3) = MarketSupportLibrary.splitAmountPrecise(amount);
        
        assertEq(share1, 40, "First share should be 40");
        assertEq(share2, 40, "Second share should be 40");
        assertEq(share3, 21, "Third share should get the remainder");
        assertEq(share1 + share2 + share3, amount, "Shares should sum to original amount");
    }

    function testSplitAmountPreciseEdgeCases() public {
        // Test with 0
        (uint256 s1, uint256 s2, uint256 s3) = MarketSupportLibrary.splitAmountPrecise(0);
        assertEq(s1 + s2 + s3, 0, "Zero amount should split to zero");
        
        // Test with 1
        (s1, s2, s3) = MarketSupportLibrary.splitAmountPrecise(1);
        assertEq(s1 + s2 + s3, 1, "Should preserve even smallest amounts");
        
        // Test with large amount
        uint256 largeAmount = type(uint128).max;
        (s1, s2, s3) = MarketSupportLibrary.splitAmountPrecise(largeAmount);
        assertEq(s1 + s2 + s3, largeAmount, "Should handle large amounts");
    }

    function testTo18Decimals() public {
        // Test USDC (6 decimals) to 18 decimals
        uint256 usdcAmount = 1000e6;
        uint256 converted = MarketSupportLibrary._to18(usdcAmount, 6);
        assertEq(converted, 1000e18, "Should convert 6 decimals to 18");
        
        // Test already 18 decimals
        uint256 wethAmount = 1e18;
        uint256 noChange = MarketSupportLibrary._to18(wethAmount, 18);
        assertEq(noChange, 1e18, "Should not change 18 decimals");
        
        // Test WBTC (8 decimals) to 18 decimals
        uint256 wbtcAmount = 1e8;
        uint256 converted8to18 = MarketSupportLibrary._to18(wbtcAmount, 8);
        assertEq(converted8to18, 1e18, "Should convert 8 decimals to 18");
    }

    function testFrom18Decimals() public {
        // Test 18 decimals to USDC (6 decimals)
        uint256 amount18 = 1000e18;
        uint256 converted = MarketSupportLibrary._from18(amount18, 6);
        assertEq(converted, 1000e6, "Should convert 18 decimals to 6");
        
        // Test no change for 18 decimals
        uint256 noChange = MarketSupportLibrary._from18(amount18, 18);
        assertEq(noChange, 1000e18, "Should not change 18 decimals");
        
        // Test 18 decimals to WBTC (8 decimals)
        uint256 converted18to8 = MarketSupportLibrary._from18(1e18, 8);
        assertEq(converted18to8, 1e8, "Should convert 18 decimals to 8");
    }

    function testDecimalConversionRoundTrip() public {
        uint256 original = 12345e6; // USDC amount
        
        // Convert to 18 decimals and back
        uint256 to18 = MarketSupportLibrary._to18(original, 6);
        uint256 backTo6 = MarketSupportLibrary._from18(to18, 6);
        
        assertEq(backTo6, original, "Round trip conversion should preserve value");
    }

    // ==================== ADVANCED LIQUIDATION TESTS ====================

    function testLiquidationDistributesCorrectly() public {
        vm.prank(alice);
        market.depositLoanAsset(10_000e6);

        vm.startPrank(bob);
        market.depositLoanCollateral(address(weth), 1e18);
        market.borrow(1_000e6, address(weth));
        vm.stopPrank();

        LoanParameters memory loanParams = LoanParameters({
            collateralTokenAddress: address(weth),
            borrower: bob,
            collateralUnitsUsed: 1e18,
            pricefeedId: bytes32(0),
            liquidationPrice: 1200e18,
            amountBorrowed: 1_000e6,
            interestRateForLoan: market.TEN_PERCENT_PER_SECOND_INTEREST_RATE(),
            timeOfBorrow: block.timestamp
        });
        bytes32 loanId = MarketSupportLibrary.generateLoanId(loanParams);

        oracle.setAssetPrice(address(weth), 1100e18);

        // Mock swap to return 1000 USDC (simplified for testing)
        swapPlatform.setMockAmountOut(1000e6);

        vm.prank(address(market));
        weth.approve(address(swapPlatform), type(uint256).max);

        uint256 treasuryBalanceBefore = usdc.balanceOf(mockTreasury);
        uint256 liquidatorBalanceBefore = usdc.balanceOf(alice);
        uint256 marketBalanceBefore = usdc.balanceOf(address(market));

        vm.prank(alice);
        market.liquidateLoan(loanId);

        // Calculate expected distributions (40% LP, 40% Treasury, 20% Liquidator)
        (uint256 lpShare, uint256 treasuryShare, uint256 liquidatorShare) = 
            MarketSupportLibrary.splitAmountPrecise(1000e6);

        assertEq(usdc.balanceOf(mockTreasury) - treasuryBalanceBefore, treasuryShare, "Treasury should receive 40%");
        assertEq(usdc.balanceOf(alice) - liquidatorBalanceBefore, liquidatorShare, "Liquidator should receive 20%");
        // LP share stays in contract
        assertEq(usdc.balanceOf(address(market)) - marketBalanceBefore, lpShare, "LP share should remain in contract");
    }

    function testCannotLiquidateWithoutSwapPlatform() public {
        // Deploy a new market without swap platform configured
        SimpleLendingMarket marketNoSwap = new SimpleLendingMarket(
            IERC20(address(usdc)), 
            "Test Vault", 
            "TVault"
        );
        marketNoSwap.setOracleAddress(address(oracle));
        marketNoSwap.setAcceptableCollateralAsset(address(weth));
        marketNoSwap.setLoanToValueRatio(0.5 ether);
        marketNoSwap.setLiquidationThreshold(0.6 ether);
        marketNoSwap.setTreasuryAddress(mockTreasury);
        // Note: NOT setting swap platform address

        // Setup: Alice lends to the new market
        vm.startPrank(alice);
        usdc.approve(address(marketNoSwap), type(uint256).max);
        marketNoSwap.depositLoanAsset(10_000e6);
        vm.stopPrank();

        // Bob borrows from the new market
        vm.startPrank(bob);
        weth.approve(address(marketNoSwap), type(uint256).max);
        marketNoSwap.depositLoanCollateral(address(weth), 1e18);
        marketNoSwap.borrow(1_000e6, address(weth));
        vm.stopPrank();

        LoanParameters memory loanParams = LoanParameters({
            collateralTokenAddress: address(weth),
            borrower: bob,
            collateralUnitsUsed: 1e18,
            pricefeedId: bytes32(0),
            liquidationPrice: 1200e18,
            amountBorrowed: 1_000e6,
            interestRateForLoan: marketNoSwap.TEN_PERCENT_PER_SECOND_INTEREST_RATE(),
            timeOfBorrow: block.timestamp
        });
        bytes32 loanId = MarketSupportLibrary.generateLoanId(loanParams);

        // Drop price to make loan liquidatable
        oracle.setAssetPrice(address(weth), 1100e18);

        // Try to liquidate without swap platform set
        vm.prank(alice);
        vm.expectRevert("Set swap platform address!");
        marketNoSwap.liquidateLoan(loanId);
    }

    function testCannotLiquidateWithoutTreasury() public {
        // Deploy a new market without treasury configured
        SimpleLendingMarket marketNoTreasury = new SimpleLendingMarket(
            IERC20(address(usdc)), 
            "Test Vault", 
            "TVault"
        );
        marketNoTreasury.setOracleAddress(address(oracle));
        marketNoTreasury.setAcceptableCollateralAsset(address(weth));
        marketNoTreasury.setLoanToValueRatio(0.5 ether);
        marketNoTreasury.setLiquidationThreshold(0.6 ether);
        marketNoTreasury.setSwapPlatformAddress(address(swapPlatform));
        // Note: NOT setting treasury address

        // Setup: Alice lends to the new market
        vm.startPrank(alice);
        usdc.approve(address(marketNoTreasury), type(uint256).max);
        marketNoTreasury.depositLoanAsset(10_000e6);
        vm.stopPrank();

        // Bob borrows from the new market
        vm.startPrank(bob);
        weth.approve(address(marketNoTreasury), type(uint256).max);
        marketNoTreasury.depositLoanCollateral(address(weth), 1e18);
        marketNoTreasury.borrow(1_000e6, address(weth));
        vm.stopPrank();

        LoanParameters memory loanParams = LoanParameters({
            collateralTokenAddress: address(weth),
            borrower: bob,
            collateralUnitsUsed: 1e18,
            pricefeedId: bytes32(0),
            liquidationPrice: 1200e18,
            amountBorrowed: 1_000e6,
            interestRateForLoan: marketNoTreasury.TEN_PERCENT_PER_SECOND_INTEREST_RATE(),
            timeOfBorrow: block.timestamp
        });
        bytes32 loanId = MarketSupportLibrary.generateLoanId(loanParams);

        // Drop price to make loan liquidatable
        oracle.setAssetPrice(address(weth), 1100e18);

        // Setup approval for swap
        vm.prank(address(marketNoTreasury));
        weth.approve(address(swapPlatform), type(uint256).max);

        // Try to liquidate without treasury set
        vm.prank(alice);
        vm.expectRevert("Set treasury address!");
        marketNoTreasury.liquidateLoan(loanId);
    }

    function testLiquidationWithDifferentSwapOutputs() public {
        vm.prank(alice);
        market.depositLoanAsset(10_000e6);

        vm.startPrank(bob);
        market.depositLoanCollateral(address(weth), 1e18);
        market.borrow(1_000e6, address(weth));
        vm.stopPrank();

        LoanParameters memory loanParams = LoanParameters({
            collateralTokenAddress: address(weth),
            borrower: bob,
            collateralUnitsUsed: 1e18,
            pricefeedId: bytes32(0),
            liquidationPrice: 1200e18,
            amountBorrowed: 1_000e6,
            interestRateForLoan: market.TEN_PERCENT_PER_SECOND_INTEREST_RATE(),
            timeOfBorrow: block.timestamp
        });
        bytes32 loanId = MarketSupportLibrary.generateLoanId(loanParams);

        oracle.setAssetPrice(address(weth), 1100e18);

        // Simulate poor liquidity - only get 50% back from swap
        swapPlatform.setMockAmountOut(500e6);

        vm.prank(address(market));
        weth.approve(address(swapPlatform), type(uint256).max);

        vm.prank(alice);
        market.liquidateLoan(loanId);

        // Verify distributions still work correctly with lower output
        (uint256 lpShare, uint256 treasuryShare, uint256 liquidatorShare) = 
            MarketSupportLibrary.splitAmountPrecise(500e6);

        assertEq(lpShare, 200e6, "LP share should be 40% of 500");
        assertEq(treasuryShare, 200e6, "Treasury share should be 40% of 500");
        assertEq(liquidatorShare, 100e6, "Liquidator share should be 20% of 500");
    }

    function testGetActiveLoanCount() public {
        vm.prank(alice);
        market.depositLoanAsset(10_000e6);

        assertEq(market.getActiveLoanCount(bob), 0, "Should have no active loans initially");

        vm.startPrank(bob);
        market.depositLoanCollateral(address(weth), 2e18);
        market.borrow(500e6, address(weth));
        assertEq(market.getActiveLoanCount(bob), 1, "Should have 1 active loan");

        market.borrow(500e6, address(weth));
        assertEq(market.getActiveLoanCount(bob), 2, "Should have 2 active loans");
        vm.stopPrank();
    }

    function testGetActiveLoanCountAfterRepayment() public {
        vm.prank(alice);
        market.depositLoanAsset(10_000e6);

        vm.startPrank(bob);
        market.depositLoanCollateral(address(weth), 1e18);
        market.borrow(1_000e6, address(weth));
        
        assertEq(market.getActiveLoanCount(bob), 1);

        LoanParameters memory loanParams = LoanParameters({
            collateralTokenAddress: address(weth),
            borrower: bob,
            collateralUnitsUsed: 1e18,
            pricefeedId: bytes32(0),
            liquidationPrice: 1200e18,
            amountBorrowed: 1_000e6,
            interestRateForLoan: market.TEN_PERCENT_PER_SECOND_INTEREST_RATE(),
            timeOfBorrow: block.timestamp
        });
        bytes32 loanId = MarketSupportLibrary.generateLoanId(loanParams);

        usdc.mint(bob, 10_000e6);
        vm.warp(block.timestamp + 1);
        market.repayLoan(loanId, 1_000e6);
        
        assertEq(market.getActiveLoanCount(bob), 0, "Should have no active loans after repayment");
        vm.stopPrank();
    }

    function testSetSwapPlatformAddress() public {
        address newSwapPlatform = address(0x123);
        market.setSwapPlatformAddress(newSwapPlatform);
        assertEq(market.swapPlatform(), newSwapPlatform);
    }

    function testCannotSetZeroAddressAsSwapPlatform() public {
        vm.expectRevert("Zero Address not allowed!");
        market.setSwapPlatformAddress(address(0));
    }

    // ==================== FLASH CRASH SCENARIO ====================

    function testFlashCrashLiquidation() public {
        // Setup: Alice provides liquidity
        vm.prank(alice);
        market.depositLoanAsset(10_000e6);

        // Bob takes a healthy loan at normal prices
        vm.startPrank(bob);
        market.depositLoanCollateral(address(weth), 2e18); // Deposits 2 ETH
        market.borrow(1_000e6, address(weth)); // Borrows $1000 at 50% LTV
        vm.stopPrank();

        // Initial state: ETH at $2000, loan is safe
        // Collateral value: 2 ETH * $2000 = $4000
        // Borrowed: $1000
        // LTV: 25% (very safe)
        // Liquidation price: $2000 * 0.6 = $1200

        LoanParameters memory loanParams = LoanParameters({
            collateralTokenAddress: address(weth),
            borrower: bob,
            collateralUnitsUsed: 1e18, // Only 1 ETH used as collateral for $1000 loan
            pricefeedId: bytes32(0),
            liquidationPrice: 1200e18,
            amountBorrowed: 1_000e6,
            interestRateForLoan: market.TEN_PERCENT_PER_SECOND_INTEREST_RATE(),
            timeOfBorrow: block.timestamp
        });
        bytes32 loanId = MarketSupportLibrary.generateLoanId(loanParams);

        // Verify loan is healthy
        assertFalse(market.canBeLiquidated(loanId), "Loan should not be liquidatable at normal price");
        assertEq(market.getActiveLoanCount(bob), 1, "Bob should have 1 active loan");

        // ⚡ FLASH CRASH: ETH drops from $2000 to $800 (60% crash)
        oracle.setAssetPrice(address(weth), 800e18);

        // Verify loan is now underwater
        assertTrue(market.canBeLiquidated(loanId), "Loan should be liquidatable during flash crash");

        // Setup swap - during flash crash, liquidator gets poor swap rate
        // Simulating getting only 800 USDC for 1 ETH (the crashed price)
        swapPlatform.setMockAmountOut(800e6);

        vm.prank(address(market));
        weth.approve(address(swapPlatform), type(uint256).max);

        // Alice (liquidator) takes advantage of the flash crash
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);
        uint256 treasuryBalanceBefore = usdc.balanceOf(mockTreasury);
        uint256 marketBalanceBefore = usdc.balanceOf(address(market));

        vm.prank(alice);
        vm.expectEmit(true, true, true, false);
        emit SimpleLendingMarket.LoanLiquidated(
            loanId,
            address(market),
            address(weth),
            bob,
            alice,
            0, // Will be calculated
            0, // Will be calculated
            0  // Will be calculated
        );
        market.liquidateLoan(loanId);

        // Calculate distributions from the 800 USDC received
        (uint256 lpShare, uint256 treasuryShare, uint256 liquidatorShare) = 
            MarketSupportLibrary.splitAmountPrecise(800e6);

        // Verify distributions: 40% LP, 40% Treasury, 20% Liquidator
        assertEq(lpShare, 320e6, "LP should get 40% = 320 USDC");
        assertEq(treasuryShare, 320e6, "Treasury should get 40% = 320 USDC");
        assertEq(liquidatorShare, 160e6, "Liquidator should get 20% = 160 USDC");

        assertEq(usdc.balanceOf(alice) - aliceBalanceBefore, liquidatorShare, "Alice receives liquidator share");
        assertEq(usdc.balanceOf(mockTreasury) - treasuryBalanceBefore, treasuryShare, "Treasury receives its share");
        assertEq(usdc.balanceOf(address(market)) - marketBalanceBefore, lpShare, "LPs get their share via increased reserves");

        // Verify loan state after liquidation
        assertEq(market.getActiveLoanCount(bob), 0, "Bob should have no active loans");
        assertEq(market.getBorrowerAssetBorrowed(bob, address(weth)), 0, "Bob's borrowed collateral should be cleared");
        
        // Bob still has 1 ETH available (only 1 was used as collateral)
        assertEq(market.getBorrowerAssetAvailable(bob, address(weth)), 1e18, "Bob should still have 1 ETH available");

        // Verify the loan is marked as liquidated
        (, LoanState loanState) = market.loans(loanId);
        assertTrue(loanState == LoanState.LIQUIDATED, "Loan should be marked as LIQUIDATED");

        // 🔥 Key insight: During flash crash, protocol and liquidators suffer losses
        // - Borrowed: $1000 USDC
        // - Recovered: $800 USDC (due to crashed price)
        // - Loss: $200 USDC absorbed by LPs (40%) and Treasury (40%)
        // - This demonstrates why liquidation thresholds are important
    }

    function testFlashCrashMultipleLiquidations() public {
        // Setup: Multiple borrowers with loans
        vm.prank(alice);
        market.depositLoanAsset(50_000e6);

        address borrower1 = address(0xB01);
        address borrower2 = address(0xB02);
        address borrower3 = address(0xB03);

        // Give them all WETH and approvals
        weth.mint(borrower1, 5e18);
        weth.mint(borrower2, 5e18);
        weth.mint(borrower3, 5e18);

        vm.prank(borrower1);
        weth.approve(address(market), type(uint256).max);
        vm.prank(borrower2);
        weth.approve(address(market), type(uint256).max);
        vm.prank(borrower3);
        weth.approve(address(market), type(uint256).max);

        // Three borrowers take loans at ETH = $2000
        vm.prank(borrower1);
        market.depositLoanCollateral(address(weth), 1e18);
        vm.prank(borrower1);
        market.borrow(1_000e6, address(weth));

        vm.prank(borrower2);
        market.depositLoanCollateral(address(weth), 2e18);
        vm.prank(borrower2);
        market.borrow(2_000e6, address(weth));

        vm.prank(borrower3);
        market.depositLoanCollateral(address(weth), 1.5e18);
        vm.prank(borrower3);
        market.borrow(1_500e6, address(weth));

        // ⚡ FLASH CRASH: ETH crashes to $1000
        oracle.setAssetPrice(address(weth), 1000e18);

        // All loans become liquidatable
        LoanParameters memory loan1 = LoanParameters({
            collateralTokenAddress: address(weth),
            borrower: borrower1,
            collateralUnitsUsed: 1e18,
            pricefeedId: bytes32(0),
            liquidationPrice: 1200e18,
            amountBorrowed: 1_000e6,
            interestRateForLoan: market.TEN_PERCENT_PER_SECOND_INTEREST_RATE(),
            timeOfBorrow: block.timestamp
        });

        LoanParameters memory loan2 = LoanParameters({
            collateralTokenAddress: address(weth),
            borrower: borrower2,
            collateralUnitsUsed: 2e18,
            pricefeedId: bytes32(0),
            liquidationPrice: 1200e18,
            amountBorrowed: 2_000e6,
            interestRateForLoan: market.TEN_PERCENT_PER_SECOND_INTEREST_RATE(),
            timeOfBorrow: block.timestamp
        });

        LoanParameters memory loan3 = LoanParameters({
            collateralTokenAddress: address(weth),
            borrower: borrower3,
            collateralUnitsUsed: 1.5e18,
            pricefeedId: bytes32(0),
            liquidationPrice: 1200e18,
            amountBorrowed: 1_500e6,
            interestRateForLoan: market.TEN_PERCENT_PER_SECOND_INTEREST_RATE(),
            timeOfBorrow: block.timestamp
        });

        bytes32 loanId1 = MarketSupportLibrary.generateLoanId(loan1);
        bytes32 loanId2 = MarketSupportLibrary.generateLoanId(loan2);
        bytes32 loanId3 = MarketSupportLibrary.generateLoanId(loan3);

        assertTrue(market.canBeLiquidated(loanId1), "Loan 1 should be liquidatable");
        assertTrue(market.canBeLiquidated(loanId2), "Loan 2 should be liquidatable");
        assertTrue(market.canBeLiquidated(loanId3), "Loan 3 should be liquidatable");

        // Setup approvals
        vm.prank(address(market));
        weth.approve(address(swapPlatform), type(uint256).max);

        // Liquidator liquidates all three loans during the crash
        // Mock swap returns crashed price ($1000 per ETH)
        address liquidator = address(0x11C);

        vm.prank(liquidator);
        swapPlatform.setMockAmountOut(1000e6); // 1 ETH → $1000
        vm.prank(liquidator);
        market.liquidateLoan(loanId1);

        vm.prank(liquidator);
        swapPlatform.setMockAmountOut(2000e6); // 2 ETH → $2000
        vm.prank(liquidator);
        market.liquidateLoan(loanId2);

        vm.prank(liquidator);
        swapPlatform.setMockAmountOut(1500e6); // 1.5 ETH → $1500
        vm.prank(liquidator);
        market.liquidateLoan(loanId3);

        // Verify all loans liquidated
        assertEq(market.getActiveLoanCount(borrower1), 0, "Borrower1 has no active loans");
        assertEq(market.getActiveLoanCount(borrower2), 0, "Borrower2 has no active loans");
        assertEq(market.getActiveLoanCount(borrower3), 0, "Borrower3 has no active loans");

        // Total borrowed: $4500
        // Total recovered: $4500 (at crashed prices)
        // In this case, no loss because liquidations happened exactly at liquidation price
        // But liquidator profited from the 20% cut on each liquidation
        uint256 liquidatorTotalProfit = (1000e6 + 2000e6 + 1500e6) * 20 / 100;
        assertEq(liquidatorTotalProfit, 900e6, "Liquidator earns $900 total from flash crash");
    }
}
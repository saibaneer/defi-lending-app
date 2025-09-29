// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IMarket} from "./IMarket.sol";


contract SimpleLendingMarket is IMarket {

    // -------------------------------
    // Global State
    // -------------------------------
    uint256 public liquidationThreshold;
    uint256 public loanToValueRatio;
    uint256 public baseInterestRatePerSecond;

    enum LoanState {
        ACTIVE,
        REPAID,
        LIQUIDATED
    }

    struct Loan {
        address collateralTokenAddress; 
        uint256 collateralAmountDeposited;
        bytes32 pricefeedId; // oracle Id
        uint256 liquidationPrice;
        uint256 amountBorrowed;
        uint256 interestRateForLoan;
        LoanState currentStatus;
        // uint256 amountRepaid;
    }

    mapping(bytes32 => Loan) public loans;


    // -------------------------------
    // Lender State
    // -------------------------------
    struct LenderAccount {
        uint256 lenderBalance;
        uint256 lastRewardCheckpoint;
        uint256 pendingRewards;
    }

    mapping(address => LenderAccount) public lenderInfo;



    // -------------------------------
    // Borrower State
    // -------------------------------
    struct BorrowerAccount {
        mapping(address collateralAssetAddress => uint256 amount) borrowerAsset;
        uint256 activeLoanCount;
        uint256 liquidatedLoanCount;
    }

    mapping(address borrowerAddress => BorrowerAccount) public borrowerInfo;


    function depositLoanAsset(uint256 amount) external {}
    function claimShareRewards() external {}
    function withdrawLoanAsset(uint256 amount) external {}


    // BORROWER
    function depositLoanCollateral(address loanAssetAddress, uint256 amount) external{}
    function borrow(uint256 amount, address collateralTokenAddress) external {}
    function repayLoan(bytes32 loanId, uint256 amount) external{}

    // PLATFORM
    function liquidateLoan(bytes32 loanId) external{}
    function setLiquidationThreshold(uint256 _liquidationThreshold) external{}
    function setLoanToValueRatio(uint256 _loanToValueRatio) external{}
    function setBaseInterestRatePerSecond(uint256 _baseInterestRatePerSecond) external {}
    function calculatePriceTimesQuantity(uint256 price, uint256 quantity) internal view returns(uint256) {}
    function canBeLiquidated(bytes32 loanId) external view returns (bool){}
}
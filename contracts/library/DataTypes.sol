// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

    enum LoanState {
        ACTIVE,
        REPAID,
        LIQUIDATED
    }

    struct LoanParameters {
        address collateralTokenAddress;
        address borrower;
        uint256 collateralUnitsUsed;
        bytes32 pricefeedId; // oracle Id
        uint256 liquidationPrice;
        uint256 amountBorrowed;
        uint256 interestRateForLoan;
        uint256 timeOfBorrow;
    }

      struct Loan {
        LoanParameters params;
        LoanState currentStatus;
        // uint256 amountRepaid;
    }
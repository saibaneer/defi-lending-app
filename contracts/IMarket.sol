// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;


interface IMarket {

    // LENDER
    function depositLoanAsset(uint256 amount) external;
    function claimShareRewards() external;
    function withdrawLoanAsset(uint256 amount) external;


    // BORROWER
    function depositLoanCollateral(address loanAssetAddress, uint256 amount) external;
    function repayLoan(bytes32 loanId, uint256 amount) external;

    // PLATFORM
    function liquidateLoan(bytes32 loanId) external;
    function setLiquidationThreshold(uint256 _liquidationThreshold) external;
    function setLoanToValueRatio(uint256 _loanToValueRatio) external;
    
    
}
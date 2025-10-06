// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IMarket} from "./IMarket.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

// import {Initializable} from "@openzeppelin/contracts/proxy/utils";

contract SimpleLendingMarket is IMarket, ERC4626 {

    event Deposited(address indexed caller, uint256 depositAmount, uint256 sharesReceived);
    
    // -------------------------------
    // Global State
    // -------------------------------
    IERC20 public stableAsset;
    uint256 public liquidationThreshold;
    uint256 public loanToValueRatio;
    uint256 public baseInterestRatePerSecond;
    uint256 public lastUpdatedTime;
    uint256 public totalBorrows;

    uint256 public constant TEN_PERCENT_PER_SECOND_INTEREST_RATE = 3168808781;

    uint256 public rewardPerShare;

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
    mapping(address => bytes32) public collateralAddressToPricefeedId;

    // -------------------------------
    // Lender State
    // -------------------------------
    struct LenderAccount {
        uint256 pendingRewards;
        uint256 checkpointRewardPerShare;
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

    constructor(IERC20 _asset, string memory _name, string memory _symbol) ERC4626(_asset) ERC20(_name, _symbol) {
        stableAsset = _asset; // TODO check if neccesary
    } 

    // LENDER
    function depositLoanAsset(uint256 amount) external {
        updateGrowthRPS();
        _settleOutstandings(msg.sender);
        uint256 sharesReceived = deposit(amount, msg.sender);
        emit Deposited(msg.sender, balanceOf(msg.sender), sharesReceived);
    }

    function claimShareRewards() external {}

    function withdrawLoanAsset(uint256 amount) external {}

    // BORROWER
    function depositLoanCollateral(
        address loanAssetAddress,
        uint256 amount
    ) external {}

    function borrow(uint256 amount, address collateralTokenAddress) external {}

    function repayLoan(bytes32 loanId, uint256 amount) external {}

    // PLATFORM
    function liquidateLoan(bytes32 loanId) external {}

    function maximumBorrowableAmount() external {}

    function setLiquidationThreshold(uint256 _liquidationThreshold) external {}

    function setLoanToValueRatio(uint256 _loanToValueRatio) external {}

    function setBaseInterestRatePerSecond(
        uint256 _baseInterestRatePerSecond
    ) external {}

    function calculatePriceTimesQuantity(
        uint256 price,
        uint256 quantity
    ) internal view returns (uint256) {}

    function canBeLiquidated(bytes32 loanId) external view returns (bool) {}

    function estimateGrowthRPS() public view returns (uint256 accRPSDelta) {
        // STEP 1: elapsed time since last accrual
        uint256 dt = block.timestamp - lastUpdatedTime;
        // STEP 2: if no time passed or nothing is borrowed, nothing to accrue
        if(dt == 0 || totalBorrows == 0) return 0;
        // STEP 3: compute current per-second borrow rate from utilization (or fixed rate)
        uint256 interestRate = borrowRatePerSecond();
        // STEP 4: interest accrued over [lastAccrual, now]
        uint256 interestAccrued = (totalBorrows * dt * interestRate)/1e18;
        // (Note: accrues on *current outstanding principal*, not Δborrows)

        // STEP 5: distribute to LPs by increasing rewards-per-share
        uint256 currentTotalShares = totalSupply();

        if(currentTotalShares == 0) return 0;

        return interestAccrued * 1e18 / currentTotalShares;
    }

    function updateGrowthRPS() internal {
        rewardPerShare += estimateGrowthRPS();
    }

    function _settleOutstandings(address user) internal {
        uint256 lastRewardCheckpoint = lenderInfo[user].checkpointRewardPerShare;
        uint256 globalRewardPerShare = rewardPerShare;

        if(globalRewardPerShare == lastRewardCheckpoint) return ;

        uint256 deltaRPS = globalRewardPerShare - lastRewardCheckpoint;
        uint256 userShareBalance = balanceOf(user);
        if(userShareBalance != 0 && deltaRPS != 0) {
            uint256 owed = (userShareBalance * deltaRPS) / 1e18;
            lenderInfo[user].pendingRewards += owed; 
        }
        lenderInfo[user].checkpointRewardPerShare = globalRewardPerShare;
    }

  

    function borrowRatePerSecond() public pure returns(uint256) {
        return TEN_PERCENT_PER_SECOND_INTEREST_RATE;
    }
}

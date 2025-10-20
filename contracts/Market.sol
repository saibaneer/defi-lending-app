// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IMarket} from "./IMarket.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IMockOracle} from "./IMockOracle.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {MarketSupportLibrary} from "./library/MarketSupportLibrary.sol";
import {LoanParameters, LoanState, Loan} from "./library/DataTypes.sol";
import {ISwap} from "./ISwap.sol";

// import {Initializable} from "@openzeppelin/contracts/proxy/utils";

contract SimpleLendingMarket is IMarket, ERC4626 {
    event Deposited(
        address indexed caller,
        uint256 depositAmount,
        uint256 sharesReceived
    );
    event ClaimedRewards(
        address indexed caller,
        address indexed market,
        uint256 rewards
    );
    event Withdrawn(
        address indexed caller,
        address indexed market,
        uint256 liquidityProvided
    );
    event DepositedCollateralAsset(
        address indexed caller,
        address indexed market,
        address indexed collateralAsset,
        uint256 amount
    );
    event Borrowed(
        address indexed market,
        bytes32 indexed loandId,
        uint256 indexed liquidationPrice,
        LoanState loanStatus,
        address caller,
        address collateralAsset,
        uint256 amount,
        uint256 activeLoanCount,
        uint256 currentRepaymentCount
    );

    event LoanRepaid(
        bytes32 indexed loanId,
        address indexed borrower,
        LoanState indexed loanStatus,
        address market,
        address collateralAsset,
        uint256 amountRepaid,
        uint256 activeLoanCount,
        uint256 currentRepaymentCount
    );

    event WithdrewCollateral(address indexed collateralAddress, address indexed market, address caller, uint256 amount);
    event LoanLiquidated(
        bytes32 indexed loanId,
        address indexed market,
        address indexed collateralAsset,
        address borrower,
        address liquidator,
        uint256 lpEarnings,
        uint256 treasuryEarnings,
        uint256 liquidatorEarnings
    );

    // -------------------------------
    // Global State
    // -------------------------------
    IERC20 public stableAsset;
    uint256 public liquidationThreshold;
    uint256 public loanToValueRatio; //0 to 1
    // uint256 public baseInterestRatePerSecond;
    uint256 public lastUpdatedTime;
    uint256 public totalBorrows;

    uint256 public constant TEN_PERCENT_PER_SECOND_INTEREST_RATE = 3168808781;

    uint256 public rewardPerShare;


    mapping(bytes32 => Loan) public loans;
    mapping(address => bytes32) public collateralAddressToPricefeedId;
    mapping(address => bool) public acceptableCollateralTokens;

    address public oracle;
    address public swapPlatform;
    address public treasury;
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
        mapping(address collateralAssetAddress => uint256 amount) borrowerAssetAvailable;
        mapping(address collateralAssetAddress => uint256 amount) borrowed;
        uint256 activeLoanCount;
        uint256 liquidatedLoanCount;
        uint256 repaymentCount;
    }

    mapping(address borrowerAddress => BorrowerAccount) public borrowerInfo;

    constructor(
        IERC20 _asset,
        string memory _name,
        string memory _symbol
    ) ERC4626(_asset) ERC20(_name, _symbol) {
        stableAsset = _asset; // TODO check if neccesary
        lastUpdatedTime = block.timestamp;
    }

    function getBorrowerAssetAvailable(address _borrower, address _collateralToken) external view returns(uint256){
        _addressCheck(_borrower);
        _addressCheck(_collateralToken);
        return borrowerInfo[_borrower].borrowerAssetAvailable[_collateralToken];
    }

    function getBorrowerAssetBorrowed(address _borrower, address _collateralToken) external view returns(uint256){
        _addressCheck(_borrower);
        _addressCheck(_collateralToken);
        return borrowerInfo[_borrower].borrowed[_collateralToken];
    }

    function getActiveLoanCount(address _borrower) external view returns(uint256) {
        _addressCheck(_borrower);
        return borrowerInfo[_borrower].activeLoanCount;
    }

    // LENDER
    function depositLoanAsset(uint256 amount) external {
        _updateGrowthRPS();
        _settleOutstandings(msg.sender);
        uint256 sharesReceived = deposit(amount, msg.sender);
        emit Deposited(msg.sender, balanceOf(msg.sender), sharesReceived);
    }

    function claimShareRewards() external {
        _updateGrowthRPS();
        _settleOutstandings(msg.sender);
        uint256 rewards = lenderInfo[msg.sender].pendingRewards;
        if (rewards == 0) return;
        lenderInfo[msg.sender].pendingRewards = 0;
        stableAsset.transfer(msg.sender, rewards);
        emit ClaimedRewards(msg.sender, address(this), rewards);
    }

    function withdrawLoanAsset(uint256 amount, bool claimRewards) external {
        _updateGrowthRPS();
        _settleOutstandings(msg.sender);
        if (claimRewards) {
            _claimPending(msg.sender, true);
        }

        withdraw(amount, msg.sender, msg.sender);
        lenderInfo[msg.sender].checkpointRewardPerShare = rewardPerShare;
        emit Withdrawn(msg.sender, address(this), amount);
    }

    // BORROWER
    function depositLoanCollateral(
        address collateralTokenAddress,
        uint256 amount
    ) external {
        _addressCheck(collateralTokenAddress);
        require(
            isAcceptableCollateralAsset(collateralTokenAddress),
            "Unacceptable collateral asset!"
        );
        require(amount > 0, "Invalid amount");

        borrowerInfo[msg.sender].borrowerAssetAvailable[
            collateralTokenAddress
        ] += amount;
        IERC20(collateralTokenAddress).transferFrom(
            msg.sender,
            address(this),
            amount
        );

        emit DepositedCollateralAsset(
            msg.sender,
            address(this),
            collateralTokenAddress,
            amount
        );
    }

    function withdrawFromAvailableCollateral(uint256 amount, address collateralAddress) external {
        require(amount > 0, "Must be greater than zero!");
        _addressCheck(collateralAddress);
        require(borrowerInfo[msg.sender].borrowerAssetAvailable[collateralAddress] >= amount, "Cannot withdraw this amount!");

        borrowerInfo[msg.sender].borrowerAssetAvailable[collateralAddress] -= amount;
        IERC20(collateralAddress).transfer(msg.sender, amount);
        emit WithdrewCollateral(collateralAddress, address(this), msg.sender, amount);
    }

    function borrow(
        uint256 amountInStableToken,
        address collateralTokenAddress
    ) external {
        _addressCheck(collateralTokenAddress);
        require(amountInStableToken > 0, "Invalid amount!");
        require(loanToValueRatio > 0, "Loan to value ratio not set!");

        uint256 unitsOfCollateralNeeded = estimateUnitsOfCollateralNeededForLoan(
                amountInStableToken,
                collateralTokenAddress
            );
        require(
            borrowerInfo[msg.sender].borrowerAssetAvailable[
                collateralTokenAddress
            ] >= unitsOfCollateralNeeded,
            "Insufficient collateral available!"
        );

        borrowerInfo[msg.sender].borrowerAssetAvailable[
                collateralTokenAddress
            ] -= unitsOfCollateralNeeded;
        borrowerInfo[msg.sender].borrowed[
            collateralTokenAddress
        ] += unitsOfCollateralNeeded;
        borrowerInfo[msg.sender].activeLoanCount++;
        uint256 assetPrice = IMockOracle(oracle).getAssetPrice(
            collateralTokenAddress
        );
        uint256 liquidationPrice = MarketSupportLibrary.getLiquidationPrice(
            liquidationThreshold,
            assetPrice
        );
        LoanParameters memory loanParams = LoanParameters(
            collateralTokenAddress,
            msg.sender,
            unitsOfCollateralNeeded,
            bytes32(0),
            liquidationPrice,
            amountInStableToken,
            TEN_PERCENT_PER_SECOND_INTEREST_RATE,
            block.timestamp
        );

        bytes32 loanId = MarketSupportLibrary.generateLoanId(loanParams);

        loans[loanId] = Loan(loanParams, LoanState.ACTIVE);
        totalBorrows += amountInStableToken;
        stableAsset.transfer(msg.sender, amountInStableToken);
        emit Borrowed(
            address(this),
            loanId,
            liquidationPrice,
            loans[loanId].currentStatus,
            msg.sender,
            collateralTokenAddress,
            amountInStableToken,
            borrowerInfo[msg.sender].activeLoanCount,
            borrowerInfo[msg.sender].repaymentCount
        );
    }

    function repayLoan(bytes32 loanId, uint256 amountBorrowed) external {
        // Run checks
        require(loanId != bytes32(0), "Invalid bytes Id!");
        require(
            loans[loanId].params.borrower == msg.sender,
            "You are not the borrower!"
        );
        require(
            loans[loanId].currentStatus == LoanState.ACTIVE,
            "Only active loans can be repaid!"
        );
        require(
            amountBorrowed >= loans[loanId].params.amountBorrowed,
            "Amount repaid must be greater or equal to amountBorrowed"
        );

        uint256 repaymentDue = estimateRepaymentDue(loanId, amountBorrowed);
        address collateral = loans[loanId].params.collateralTokenAddress;

        uint256 borrowedAgainst = loans[loanId].params.collateralUnitsUsed;
        borrowerInfo[msg.sender].borrowed[collateral] -= borrowedAgainst;
        borrowerInfo[msg.sender].borrowerAssetAvailable[
            collateral
        ] += borrowedAgainst;
        borrowerInfo[msg.sender].repaymentCount++;
        borrowerInfo[msg.sender].activeLoanCount--;
        loans[loanId].currentStatus = LoanState.REPAID;
        totalBorrows -= loans[loanId].params.amountBorrowed;
        stableAsset.transferFrom(msg.sender, address(this), repaymentDue);

        emit LoanRepaid(
            loanId,
            msg.sender,
            loans[loanId].currentStatus,
            address(this),
            collateral,
            repaymentDue,
            borrowerInfo[msg.sender].activeLoanCount,
            borrowerInfo[msg.sender].repaymentCount
        );
    }

    function estimateRepaymentDue(
        bytes32 loanId,
        uint256 amountBorrowed
    ) public view returns (uint256) {
        uint256 secondsPassed = block.timestamp -
            loans[loanId].params.timeOfBorrow;

        uint256 repaymentDue = MarketSupportLibrary.getRepaymentDue(
            amountBorrowed,
            TEN_PERCENT_PER_SECOND_INTEREST_RATE,
            secondsPassed
        );

        return repaymentDue;
    }

    

    // PLATFORM
    function setAcceptableCollateralAsset(address token) external {
        _addressCheck(token);
        acceptableCollateralTokens[token] = true;
        //TODO - add an event
    }

    function setOracleAddress(address _oracle) external {
        _addressCheck(_oracle);
        oracle = _oracle;
    }

    function isAcceptableCollateralAsset(
        address token
    ) public view returns (bool) {
        _addressCheck(token);
        return acceptableCollateralTokens[token];
    }

    function liquidateLoan(bytes32 loanId) external {
        require(canBeLiquidated(loanId), "Loan cannot be liquidated!");
        require(swapPlatform != address(0), "Set swap platform address!");
        require(treasury != address(0), "Set treasury address!");

        address collateralToken = loans[loanId].params.collateralTokenAddress;
        uint256 collateralTokenQty = loans[loanId].params.collateralUnitsUsed;
        // swap the collateral assets for a stable asset
        uint256 amountOut = ISwap(swapPlatform).swapExactInputSingle(collateralToken, address(stableAsset), collateralTokenQty);
        address borrower = loans[loanId].params.borrower;
        require(borrower != msg.sender, "Cannot liquidate your own loan!");
        loans[loanId].currentStatus = LoanState.LIQUIDATED;
        if(borrowerInfo[borrower].activeLoanCount > 0){
            borrowerInfo[borrower].activeLoanCount--;
        }
        borrowerInfo[borrower].liquidatedLoanCount++;
        borrowerInfo[borrower].borrowed[collateralToken] -= collateralTokenQty;
      
        // distribute earnings
        // -- LPs get 40%
        // -- Treasury 40%
        // -- Liquidator 20%
        (, uint256 treasuryEarnings, uint256 liquidatorEarnings) = MarketSupportLibrary.splitAmountPrecise(amountOut);
        stableAsset.transfer(treasury, treasuryEarnings);
        stableAsset.transfer(msg.sender, liquidatorEarnings);

        // emit an event
        emit LoanLiquidated(loanId, address(this), collateralToken, borrower, msg.sender, treasuryEarnings, treasuryEarnings, liquidatorEarnings);
    }



    function setLiquidationThreshold(uint256 _liquidationThreshold) external {
        require(_liquidationThreshold >= 0.6 ether, "Amount must be greater than or equal to 0.6 ether");
        liquidationThreshold = _liquidationThreshold;
    }

    function setLoanToValueRatio(uint256 _loanToValueRatio) external {
        require(_loanToValueRatio >= 0.4 ether, "Amount must be greater than or equal to 0.4 ether");
        loanToValueRatio = _loanToValueRatio;
    }

    // function setBaseInterestRatePerSecond(
    //     uint256 _baseInterestRatePerSecond
    // ) external {

    // }


    function setTreasuryAddress(address _treasury) external {
        _addressCheck(_treasury);
        treasury = _treasury;
    }

    function setSwapPlatformAddress(address _swapPlatform) external {
        _addressCheck(_swapPlatform);
        swapPlatform = _swapPlatform;
    }



    function canBeLiquidated(bytes32 loanId) public view returns (bool) {
        require(loans[loanId].params.timeOfBorrow > 0, "Invalid borrow time");
        require(loans[loanId].params.collateralTokenAddress != address(0), "Invalid collateral token");
        require(loans[loanId].params.liquidationPrice > 0, "Invalid liquidation price");

        address collateralToken = loans[loanId].params.collateralTokenAddress;
        uint256 liquidationPrice = loans[loanId].params.liquidationPrice;

        uint256 currentAssetPrice = IMockOracle(oracle).getAssetPrice(collateralToken);
        bool isActive = loans[loanId].currentStatus == LoanState.ACTIVE;
        return currentAssetPrice <= liquidationPrice && isActive ? true : false; 
    }

    function estimateGrowthRPS() public view returns (uint256 accRPSDelta) {
        // STEP 1: elapsed time since last accrual
        uint256 dt = block.timestamp - lastUpdatedTime;
        // STEP 2: if no time passed or nothing is borrowed, nothing to accrue
        if (dt == 0 || totalBorrows == 0) return 0;
        // STEP 3: compute current per-second borrow rate from utilization (or fixed rate)
        uint256 interestRate = borrowRatePerSecond();
        // STEP 4: interest accrued over [lastAccrual, now]
        uint256 interestAccrued = (totalBorrows * dt * interestRate) / 1e18;
        // (Note: accrues on *current outstanding principal*, not Δborrows)

        // STEP 5: distribute to LPs by increasing rewards-per-share
        uint256 currentTotalShares = totalSupply();

        if (currentTotalShares == 0) return 0; //50000000000000000 | 0.05 ether | 0.05e18

        return (interestAccrued * 1e18) / currentTotalShares;
    }

    function _updateGrowthRPS() internal {
        rewardPerShare += estimateGrowthRPS();
        lastUpdatedTime = block.timestamp;
    }

    function _settleOutstandings(address user) internal {
        uint256 lastRewardCheckpoint = lenderInfo[user]
            .checkpointRewardPerShare;
        uint256 globalRewardPerShare = rewardPerShare;

        if (globalRewardPerShare == lastRewardCheckpoint) return;

        uint256 deltaRPS = globalRewardPerShare - lastRewardCheckpoint;
        uint256 userShareBalance = balanceOf(user);
        if (userShareBalance != 0 && deltaRPS != 0) {
            uint256 owed = (userShareBalance * deltaRPS) / 1e18;
            lenderInfo[user].pendingRewards += owed;
        }
        lenderInfo[user].checkpointRewardPerShare = globalRewardPerShare;
    }

    function borrowRatePerSecond() public pure returns (uint256) {
        return TEN_PERCENT_PER_SECOND_INTEREST_RATE;
    }

    function _cashOnHandInternal() internal view returns (uint256) {
        return stableAsset.balanceOf(address(this));
    }

    function _claimPending(address _user, bool allowPartial) internal {
        uint256 amount = lenderInfo[_user].pendingRewards;
        if (amount == 0) return;
        uint256 cash = _cashOnHandInternal();
        if (cash == 0) return;
        uint256 pay = allowPartial ? (amount <= cash ? amount : cash) : amount;
        require(
            allowPartial || cash >= amount,
            "Insufficient funds in the contract, try again later!"
        );
        lenderInfo[_user].pendingRewards = amount - pay;
        stableAsset.transfer(msg.sender, pay);
        emit ClaimedRewards(msg.sender, address(this), pay);
    }

    function _isNonZeroAddress(address _address) internal pure returns (bool) {
        return _address != address(0);
    }

    function _addressCheck(address _address) internal pure {
        require(_isNonZeroAddress(_address), "Zero Address not allowed!");
    }

    function estimateValueNeedForLoan(
        uint256 amountInStableToken
    ) public view returns (uint256) {
        require(loanToValueRatio > 0, "Loan to value ratio not set!");

        uint8 decimalsForStableAsset = IERC20Metadata(address(stableAsset))
            .decimals();
        uint256 borrowValueScaledTo18 = MarketSupportLibrary._to18(
            amountInStableToken,
            decimalsForStableAsset
        );

        uint256 value = _ceilingDivision(
            borrowValueScaledTo18 * 1e18,
            loanToValueRatio
        );
        return value;
    }

    function estimateUnitsOfCollateralNeededForLoan(
        uint256 amountInStableToken,
        address collateralToken
    ) public view returns (uint256) {
        uint256 totalValueRequired = estimateValueNeedForLoan(
            amountInStableToken
        );
        uint256 assetPrice = IMockOracle(oracle).getAssetPrice(collateralToken);

        //(a + b - 1)/b
        uint256 unitsNeeded18 = _ceilingDivision(
            totalValueRequired * 1e18,
            assetPrice
        );

        uint8 collateralDecimalValue = IERC20Metadata(collateralToken)
            .decimals();
        return
            MarketSupportLibrary._from18(unitsNeeded18, collateralDecimalValue);
    }

    function _ceilingDivision(
        uint256 numerator,
        uint256 denominator
    ) internal pure returns (uint256) {
        return (numerator + denominator - 1) / denominator;
    }
}

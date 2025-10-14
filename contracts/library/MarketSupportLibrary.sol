// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {LoanParameters} from "./DataTypes.sol";

library MarketSupportLibrary {
    function generateLoanId(
        LoanParameters memory _loan
    ) internal pure returns (bytes32) {
        require(
            _loan.collateralTokenAddress != address(0),
            "Collateral Address cannot be empty"
        );
        require(
            _loan.borrower != address(0),
            "Borrower Address cannot be empty"
        );
        require(
            _loan.collateralUnitsUsed > 0,
            "Collateral must be greater than zero!"
        );
        require(
            _loan.amountBorrowed > 0,
            "Amount borrowed must be greater than zero!"
        );

        bytes memory encodedParams = abi.encode(
            _loan.collateralTokenAddress,
            _loan.borrower,
            _loan.collateralUnitsUsed,
            _loan.amountBorrowed
        );
        return keccak256(encodedParams);
    }

    function getLiquidationPrice(
        uint256 liquidationThreshold,
        uint256 assetPrice
    ) internal pure returns (uint256) {
        return (liquidationThreshold * assetPrice) / 1e18;
    }

    function getRepaymentDue(
        uint256 amountInStableCoinBorrowed,
        uint256 interestRatePerSecond,
        uint256 secondsPassed
    ) internal pure returns (uint256) {
        //P*R*T
        uint256 perDollarAmountDue = interestRatePerSecond * secondsPassed;

        uint256 interestDue = (amountInStableCoinBorrowed * perDollarAmountDue)/1e18;

        return amountInStableCoinBorrowed + interestDue;
    }

    function _to18(uint256 amt, uint8 dec) internal pure returns (uint256) {
        return
            dec == 18
                ? amt
                : (dec < 18 ? amt * 10 ** (18 - dec) : amt / 10 ** (dec - 18));
    }

    function _from18(uint256 amt18, uint8 dec) internal pure returns (uint256) {
        return
            dec == 18
                ? amt18
                : (
                    dec < 18
                        ? amt18 / 10 ** (18 - dec)
                        : amt18 * 10 ** (dec - 18)
                );
    }
}

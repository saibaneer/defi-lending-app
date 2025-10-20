// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

interface ISwap {
    function swapExactInputSingle(
        address collateralTokenAsset,
        address stableTokenOut,
        uint256 collateralTokenQty
        // uint256 minAmountOut,
        // uint24 poolFee
    ) external returns (uint256 amountOut);
}
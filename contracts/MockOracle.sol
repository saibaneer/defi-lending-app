// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IMockOracle} from "./IMockOracle.sol";

contract MockOracle is IMockOracle {
    function setAssetPrice(address _asset, uint256 _assetPrice) external {}
    function getAssetPrice(address _asset) external view returns(uint256) {}
}
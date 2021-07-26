// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.6.0 <0.7.0;

import "../price/PriceInterface.sol";
import "../token/HIFarmToken.sol";

interface ComptrollerInterface {

    function hifToken() external view returns (HIFarmToken);

    function priceProvider() external view returns (PriceInterface);

    function preSaleLauncher() external view returns (address);
    function preSaleReleaseAt() external view returns (uint256);

    function getAllMarkets() external view returns (address[] memory);

    function isInMarket(address _pool) external view returns (bool);

    function isInWhiteList(address _addr) external view returns (bool);

    function isMinter(address _addr) external view returns (bool);

    function amountHifOfUSD(uint256 _bnbAmount) external view returns (uint256);

    function amountHifOfToken(address _token, uint256 _amount) external view returns (uint256);

    function earned(address _pool, address _user) external view returns (uint256);

    function mintNewFarmReward(address _pool, uint256 _amount) external;

    function mintNewRewardForLauncher(address _to, uint256 _amount) external;

    function mintNewRewardForUserInToken(address _user, address _token, uint256 _amount) external;

    function beforeSupply(address _user, uint256 _amount) external;

    function beforeRedeem(address _user, uint256 _amount) external;

    function claim(address _user) external;
}


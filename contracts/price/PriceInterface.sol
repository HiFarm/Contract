// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.6.12;

interface PriceInterface {

    function getBNBPrice() external view returns (uint256);

    function getTokenPrice(address token) external view returns (uint256);

    function getBNBPerToken(address token) external view returns (uint256);

    function valueOfToken(address token, uint256 amount) external view returns (uint256 valueInBNB, uint256 valueInUSD);
}


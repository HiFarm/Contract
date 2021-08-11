// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.6.12;

interface ZapInterface {

    function zapIn(address _fromToken, uint256 _amount, address _pairAddress) external payable;

    function swapTokenForToken(address _fromToken, uint256 _amount, address _toToken) external returns (uint256);

    function swapForToken(address _token) external payable returns (uint256);

    function zapOut(address _pairAddress, uint256 _amount, address _to) external returns (uint256);

    function zapOutUSD(address _pairAddress, uint256 _amount, address _to) external returns (uint256);

    function zapOutForToken(address _pairAddress, uint256 _amount, address _to) external returns (uint256, uint256);
}


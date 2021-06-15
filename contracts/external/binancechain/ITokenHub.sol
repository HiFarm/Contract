// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.6.0 <0.7.0;

interface ITokenHub {

  function getMiniRelayFee() external view returns(uint256);

  function getContractAddrByBEP2Symbol(bytes32 bep2Symbol) external view returns(address);

  function getBep2SymbolByContractAddr(address contractAddr) external view returns(bytes32);

  function bindToken(bytes32 bep2Symbol, address contractAddr, uint256 decimals) external;

  function unbindToken(bytes32 bep2Symbol, address contractAddr) external;

  function transferOut(address contractAddr, address recipient, uint256 amount, uint64 expireTime)
    external payable returns (bool);

  /* solium-disable-next-line */
  function batchTransferOutBNB(address[] calldata recipientAddrs, uint256[] calldata amounts, address[] calldata refundAddrs,
    uint64 expireTime) external payable returns (bool);

}



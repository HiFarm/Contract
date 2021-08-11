// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.6.12;

import "../libraries/TransferHelper.sol";
import "../libraries/FixedPoint.sol";
import "../zap/ZapInterface.sol";
import "./Pool.sol";

abstract contract TokenPool is Pool {
    //events

    //variables
    uint256 public constant DUST = 1000;
    address public stakedPoolToken;
    address public rewardPoolToken;

    address public zap;
    address public hifPool;

    //initializer
    function __TokenPool_init(address _comptroller, address _stakedPoolToken, address _rewardPoolToken) public initializer {
        __Pool_init(_comptroller);
        stakedPoolToken = _stakedPoolToken;
        rewardPoolToken = _rewardPoolToken;
    }

    //view functions
    //restricted functions
    function setZap(address _zap) external onlyOwner {
        zap = _zap;
    }
    function setHIFPool(address _hifPool) external onlyOwner {
        hifPool = _hifPool;
    }

    //public functions
    //private functions
    function _stakedToken() internal virtual override view returns (IERC20Upgradeable) {
        return IERC20Upgradeable(stakedPoolToken);
    }

    function _rewardToken() internal virtual override view returns (IERC20Upgradeable) {
        return IERC20Upgradeable(rewardPoolToken);
    }

    function _tokenBalance(IERC20Upgradeable token) internal virtual view returns (uint256) {
        if (address(token) == address(0)) {
            return address(this).balance;
        }
        return token.balanceOf(address(this));
    }

    function _doTransferIn(IERC20Upgradeable token, address from, uint256 amount) internal virtual override returns (uint256) {
        if (address(token) == address(0)) {
            require(msg.sender == from, "sender mismatch");
            require(msg.value == amount, "value mismatch");
        } else {
            token.safeTransferFrom(from, address(this), amount);
        }
        return amount;
    }

    function _doTransferOut(IERC20Upgradeable token, address to, uint amount) internal virtual override {
        if (amount == 0) {
            return;
        }
        if (address(token) == address(0)) {
            TransferHelper.safeTransferETH(to, amount);
        } else {
            token.safeTransfer(to, amount);
        }
    }

    function _zapInToken(address token, uint256 amount, address pairAddress) internal virtual returns (uint256) {
        uint256 before = IERC20Upgradeable(pairAddress).balanceOf(address(this));
        if (token == address(0)) {
            ZapInterface(zap).zapIn{value: amount}(token, amount, pairAddress);
        } else {
            _approveTokenIfNeeded(IERC20Upgradeable(token), zap, amount);
            ZapInterface(zap).zapIn(token, amount, pairAddress);
        }
        uint256 outAmount = IERC20Upgradeable(pairAddress).balanceOf(address(this)).sub(before);
        return outAmount;
    }

    function _checkMinFeeAmount(uint256 feeAmount) internal view virtual returns (bool) {
        if (zap == address(0) || hifPool == address(0)) {
            return false;
        }
        if (feeAmount <= DUST) {
            return false;
        }
        return true;
    }

    //modifier
    uint256[50] private __gap;
}


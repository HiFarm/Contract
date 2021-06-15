// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.6.0 <0.7.0;

import "../libraries/TransferHelper.sol";
import "./RewardTokenFarmPool.sol";

contract HIFarmRewardTokenPool is RewardTokenFarmPool {
    //events
    //structs

    //variables
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    //initializer
    function initialize(address _comptroller, address _stakedToken, address _rewardToken) public initializer {
        __RewardTokenFarmPool_init(_comptroller, _stakedToken, _rewardToken, 90 days);
    }

    //view functions
    function apRY() public view virtual override returns (uint256, uint256) {
        PriceInterface priceProvider = comptroller.priceProvider();
        uint256 measureTotalSupply = totalShare();
        uint256 accRewardPerSecondPerShareMantissa = FixedPoint.calculateMantissa(rewardInfo.accPerSecond, measureTotalSupply > 0 ? measureTotalSupply : FixedPoint.SCALE);

        uint256 bnbPerShare = priceProvider.getBNBPerToken(stakedToken()); //scale e18
        uint256 bnbPerRewardToken = priceProvider.getBNBPerToken(rewardToken()); //scale e18

        //accBNBPerSecondPerShare = FixedPoint.multiplyUintByMantissa(accPerSecondPerShareMantissa, bnbPerRewardToken)
        uint256 rewardAPR = FixedPoint.multiplyUintByMantissa(bnbPerRewardToken, accRewardPerSecondPerShareMantissa).mul(1e18).mul(365 days).div(bnbPerShare);
        return (rewardAPR, 0);
    }

    //restricted functions

    //public functions
    function receiveRewardToken(uint256 amount) external override whenNotPaused nonReentrant {
        require(amount > 0, "HIFarmTokenPool: invalid amount");

        _rewardToken().safeTransferFrom(msg.sender, address(this), amount);
        _notifyReward(amount);
    }

    //private functions
    function _stakeToFarm(uint256 amount) internal override returns (uint256) {
        return amount;
    }
    function _unStakeForWithdraw(uint256 amount) internal override returns (uint256) {
        return amount;
    }
    function _balanceOfFarm() internal view override returns (uint256) {
        return 0;
    }

    function _transferOutReward(address user, uint256 amount) internal override returns (uint256) {
        if (amount == 0) {
            return 0;
        }
        if (zap == address(0)) {
            _rewardToken().safeTransfer(user, amount);
            return amount;
        }
        //claim busd
        _approveTokenIfNeeded(_rewardToken(), zap, amount);
        uint256 outAmount = ZapInterface(zap).zapOutUSD(address(_rewardToken()), amount, user);
        return outAmount;
    }

    function _dealWithWithdrawFee(uint256 withdrawFeeAmount) internal override returns (uint256) {
        if (withdrawFeeAmount == 0) {
            return 0;
        }
        _stakedToken().safeTransfer(DEAD, withdrawFeeAmount);
        return withdrawFeeAmount;
    }

    function _dealWithPerformanceFee(address user, uint256 performanceFeeAmount) internal override returns (uint256) {
        return 0;
    }

    //modifier
}


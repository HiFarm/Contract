// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.6.12;

import "@openzeppelin/contracts-upgradeable/math/MathUpgradeable.sol";

import "../libraries/FixedPoint.sol";
import "./TokenPool.sol";

abstract contract ShareTokenFarmPool is TokenPool {
    //events

    //struct
    struct UserStakeInfo {
        uint256 share;
        uint256 principal;
        uint256 lastTimestamp;
    }

    //variables
    uint256 public override totalShare;
    mapping (address => UserStakeInfo) public accountStake;

    //initializer
    function __ShareTokenFarmPool_init(address _comptroller, address _token) public initializer {
        __TokenPool_init(_comptroller, _token, _token);
    }

    //view functions
    function balanceOf(address user) public override view returns (uint256) {
        return _balanceOf(user);
    }

    function shareOf(address user) public override view returns (uint256) {
        return accountStake[user].share;
    }

    function principalOf(address user) public override view returns (uint256) {
        return accountStake[user].principal;
    }

    function availableOf(address user) public override view returns (uint256) {
        return principalOf(user);
    }

    function earned(address user) public override view returns (uint256) {
        uint256 userBalance = _balanceOf(user);
        if (userBalance >= accountStake[user].principal + DUST) {
            return userBalance.sub(accountStake[user].principal);
        }
        return 0;
    }

    function tvl() public view virtual override returns (uint256) {
        PriceInterface priceProvider = comptroller.priceProvider();
        (,uint256 valueInUSD) = priceProvider.valueOfToken(stakedToken(), _balance());
        return valueInUSD;
    }

    function estimateWithdrawalFee(address user, uint256 amount) public view returns (uint256) {
        if (amount > 0 && withdrawalFeeFactorMantissa > 0) {
            if (accountStake[user].lastTimestamp.add(withdrawalFeeFreePeriod) > _currentTime()) {
                return FixedPoint.multiplyUintByMantissa(amount, withdrawalFeeFactorMantissa);
            }
        }
        return 0;
    }

    function shareOfAmount(uint256 amount) public view returns (uint256) {
        uint256 exchangeRateMantissa = _exchangeRate();
        return FixedPoint.divideUintByMantissa(amount, exchangeRateMantissa);
    }

    function amountOfShare(uint256 share) public view returns (uint256) {
        return FixedPoint.multiplyUintByMantissa(share, _exchangeRate());
    }

    //restricted functions

    //public functions
    function withdrawAll() external virtual override notContract whenNotPaused nonReentrant {
        address user = msg.sender;

        uint256 userBalance = _balanceOf(user);
        uint256 profit = userBalance > accountStake[user].principal ? userBalance.sub(accountStake[user].principal) : 0;
        uint256 amount = _redeemSeparate(user, accountStake[user].principal, profit);

        _doTransferOut(_stakedToken(), user, amount);
        emit Withdraw(user, amount);

        //comptroller claim
        comptroller.claim(user);
    }

    function claimReward() external virtual override notContract whenNotPaused nonReentrant {
        address user = msg.sender;
        uint256 profit = earned(user);
        uint256 amount = _redeemSeparate(user, 0, profit);

        _doTransferOut(_stakedToken(), user, amount);
        emit ClaimReward(user, amount);

        //comptroller claim
        comptroller.claim(user);
    }

    //private functions
    function _stakeToFarm(uint256 amount) internal virtual returns (uint256);
    function _unStakeForWithdraw(uint256 amount) internal virtual returns (uint256);

    function _supplyAllowed(uint256 amount) internal virtual returns (uint256) {
        return amount;
    }

    function _balanceOf(address user) internal view returns (uint256) {
        return amountOfShare(accountStake[user].share);
    }

    function _exchangeRate() internal view returns (uint256) {
        uint256 _totalShare = totalShare;
        if (_totalShare == 0) {
            return FixedPoint.SCALE;
        }
        //exchangeRate = _balance() / _totalShare
        uint256 exchangeRateMantissa = FixedPoint.calculateMantissa(_balance(), _totalShare);
        return exchangeRateMantissa;
    }

    function _supply(address from, address minter, uint256 amount) internal virtual override returns (uint256) {
        comptroller.beforeSupply(minter, amount);

        uint256 stakeAmount = _supplyAllowed(amount);

        uint256 mintShare = shareOfAmount(stakeAmount);
        UserStakeInfo storage userStake = accountStake[minter];
        userStake.share = userStake.share.add(mintShare);
        totalShare = totalShare.add(mintShare);

        //if minter is in whitelist (pools), only interact with withdrawShare
        if (!comptroller.isInWhiteList(minter)) {
            userStake.principal = userStake.principal.add(stakeAmount);
            userStake.lastTimestamp = _currentTime();
        }

        stakeAmount = _stakeToFarm(stakeAmount);

        return stakeAmount;
    }

    function _redeem(address user, uint256 amount) internal virtual override returns (uint256) {
        return _redeemSeparate(user, amount, 0);
    }

    function _redeemShare(address user, uint256 share) internal virtual override returns (uint256) {
        require(comptroller.isInMarket(user), "invalid operation");

        UserStakeInfo storage userStake = accountStake[user];
        uint256 currentShare = MathUpgradeable.min(share, userStake.share);

        uint256 amount = amountOfShare(currentShare);

        userStake.share = userStake.share.sub(currentShare);
        totalShare = totalShare.sub(currentShare);

        comptroller.beforeRedeem(user, amount);

        uint256 outAmount = _unStakeForWithdraw(amount);

        return outAmount;
    }

    function _redeemSeparate(address user, uint256 principalAmount, uint256 profitAmount) internal virtual returns (uint256) {
        uint256 userBalance = _balanceOf(user);
        UserStakeInfo storage userStake = accountStake[user];

        principalAmount = MathUpgradeable.min(principalAmount, userStake.principal);
        uint256 amount = principalAmount.add(profitAmount);
        amount = MathUpgradeable.min(amount, userBalance);

        comptroller.beforeRedeem(user, amount);

        uint256 share = shareOfAmount(amount);

        userStake.principal = userStake.principal.sub(principalAmount);

        share = MathUpgradeable.min(share, userStake.share);
        userStake.share = userStake.share.sub(share);
        totalShare = totalShare.sub(share);

        //cleanup dust
        if (userStake.principal == 0 && userStake.share > 0 && userStake.share < DUST) {
            totalShare = totalShare.sub(userStake.share);
            userStake.share = 0;
        }

        uint256 outAmount = _unStakeForWithdraw(amount);

        uint256 withdrawFeeAmount = principalAmount > 0 ? estimateWithdrawalFee(user, principalAmount) : 0;
        uint256 performanceFeeAmount = profitAmount > 0 ? FixedPoint.multiplyUintByMantissa(profitAmount, performanceFeeFactorMantissa) : 0;
        uint256 dealWithFeeAmount = _dealWithFee(user, withdrawFeeAmount, performanceFeeAmount);

        outAmount = outAmount.sub(dealWithFeeAmount);

        return outAmount;
    }

    function _dealWithFee(address user, uint256 withdrawFeeAmount, uint256 performanceFeeAmount) internal virtual returns (uint256) {
        uint256 exchangeAmount = withdrawFeeAmount.add(performanceFeeAmount);
        if (!_checkMinFeeAmount(exchangeAmount)) {
            return 0;
        }
        address pairHIFUSDAddress = PoolInterface(hifPool).rewardToken();
        //zapin
        uint256 amount = _zapInToken(stakedToken(), exchangeAmount, pairHIFUSDAddress);

        //send reward to hif pool
        if (amount > 0) {
            _approveTokenIfNeeded(IERC20Upgradeable(pairHIFUSDAddress), hifPool, amount);
            PoolInterface(hifPool).receiveRewardToken(amount);

            //mint hif token
            if (performanceFeeAmount > 0) {
                comptroller.mintNewRewardForUserInToken(user, rewardToken(), performanceFeeAmount);
            }
        }

        return exchangeAmount;
    }

    //modifier
    uint256[50] private __gap;
}



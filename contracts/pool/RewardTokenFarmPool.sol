// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.6.12;

import "@openzeppelin/contracts-upgradeable/math/MathUpgradeable.sol";

import "../libraries/TransferHelper.sol";
import "./TokenPool.sol";

abstract contract RewardTokenFarmPool is TokenPool {
    //events

    //structs
    struct UserStakeInfo {
        uint256 amount;
        uint256 lastTimestamp;
    }

    struct RewardInfo {
        uint256 accPerSecond;
        uint256 accPerShareMantissa;
        uint256 lastTime;
        uint256 lastPeriodEndTime;
        uint256 duration;
    }
    struct UserRewardState {
        uint256 lastAccPerShareMantissa;
        uint256 accrued;
    }

    //variables
    uint256 public totalSupply;
    mapping (address => UserStakeInfo) public accountStake;
    mapping (address => UserRewardState) public userRewardStates;
    mapping (address => uint256) public userPreSale;

    RewardInfo public rewardInfo;

    //initializer
    function __RewardTokenFarmPool_init(address _comptroller, address _stakedToken, address _rewardToken, uint256 duration) public initializer {
        require(_stakedToken != _rewardToken, "RewardTokenPool: error token");
        __TokenPool_init(_comptroller, _stakedToken, _rewardToken);
        rewardInfo.duration = duration;
    }

    //view functions
    function balanceOf(address user) public override view returns (uint256) {
        return accountStake[user].amount;
    }

    function shareOf(address user) public override view returns (uint256) {
        return accountStake[user].amount;
    }

    function principalOf(address user) public override view returns (uint256) {
        return accountStake[user].amount;
    }

    function availableOf(address user) public override view returns (uint256) {
        uint256 releaseAt = comptroller.preSaleReleaseAt();
        if (_currentTime() > releaseAt) {
            return accountStake[user].amount;
        }
        return accountStake[user].amount.sub(userPreSale[user]);
    }

    function totalShare() public override view returns (uint256) {
        return _balance();
    }

    function earned(address user) public virtual override view returns (uint256) {
        UserRewardState storage userRewardState = userRewardStates[user];
        uint256 userAccrued = userRewardState.accrued;

        uint256 accPerShareMantissa = rewardPerShare();
        uint256 deltaAccPerShareMantissa = accPerShareMantissa.sub(userRewardState.lastAccPerShareMantissa);
        uint256 newAccrued = FixedPoint.multiplyUintByMantissa(shareOf(user), deltaAccPerShareMantissa);
        userAccrued = userAccrued.add(newAccrued);
        return userAccrued;
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

    function lastTimeRewardApplicable() public view returns (uint256) {
        return MathUpgradeable.min(block.timestamp, rewardInfo.lastPeriodEndTime);
    }

    function rewardPerShare() public view returns (uint256) {
        uint256 currentEndTime = lastTimeRewardApplicable();
        uint256 deltaTimes = currentEndTime.sub(rewardInfo.lastTime);
        uint256 accPerShareMantissa = rewardInfo.accPerShareMantissa;
        uint256 measureTotalSupply = totalShare();
        if (deltaTimes > 0 && measureTotalSupply > 0) {
            uint256 accrued = deltaTimes.mul(rewardInfo.accPerSecond);
            uint256 newAccPerShareMantissa = FixedPoint.calculateMantissa(accrued, measureTotalSupply);
            accPerShareMantissa = accPerShareMantissa.add(newAccPerShareMantissa);
        }
        return accPerShareMantissa;
    }

    //restricted functions
    function setRewardsDuration(uint256 _duration) external onlyOwner {
        require(rewardInfo.lastPeriodEndTime == 0 || block.timestamp > rewardInfo.lastPeriodEndTime, "RewardTokenFarmPool: period");
        rewardInfo.duration = _duration;
    }

    //public functions
    function withdrawAll() external virtual override notContract whenNotPaused nonReentrant {
        address user = msg.sender;
        _withdrawAll(user);
    }

    function claimReward() public virtual override notContract whenNotPaused nonReentrant {
        address user = msg.sender;

        _claimReward(user);
    }

    //private functions
    function _stakeToFarm(uint256 amount) internal virtual returns (uint256);
    function _unStakeForWithdraw(uint256 amount) internal virtual returns (uint256);
    function _balanceOfFarm() internal view virtual returns (uint256);

    function _transferOutReward(address user, uint256 amount) internal virtual returns (uint256);

    function _balance() internal override view returns (uint256) {
        return totalSupply;
    }

    function _rewardBalance() internal view virtual returns (uint256) {
        return _rewardToken().balanceOf(address(this));
    }

    function _convertAccrued(uint256 amount) internal virtual returns (uint256) {
        return amount;
    }

    function _withdrawAll(address user) internal virtual {
        uint256 userBalance = balanceOf(user);
        _redeemInternal(user, userBalance);

        _claimReward(user);
    }

    function _claimReward(address user) internal virtual {
        _updateReward();
        _distributeNewForUser(user);

        UserRewardState storage userRewardState = userRewardStates[user];

        uint256 accruedAmount = userRewardState.accrued;
        userRewardState.accrued = 0;

        uint256 amount = _convertAccrued(accruedAmount);

        uint256 performanceFeeAmount = amount > 0 ? FixedPoint.multiplyUintByMantissa(amount, performanceFeeFactorMantissa) : 0;
        performanceFeeAmount = _dealWithPerformanceFee(user, performanceFeeAmount);
        amount = amount.sub(performanceFeeAmount);

        uint256 rewardAmount = _transferOutReward(user, amount);
        emit ClaimReward(user, rewardAmount);

        //claim hif
        comptroller.claim(user);
    }

    function _supply(address from, address minter, uint256 amount) internal override returns (uint256) {
        comptroller.beforeSupply(minter, amount);

        _updateReward();
        _distributeNewForUser(minter);

        UserStakeInfo storage userStake = accountStake[minter];
        totalSupply = totalSupply.add(amount);
        userStake.amount = userStake.amount.add(amount);
        userStake.lastTimestamp = _currentTime();

        if (from == comptroller.preSaleLauncher()) {
            userPreSale[minter] = userPreSale[minter].add(amount);
        }

        uint256 stakeAmount = _stakeToFarm(amount);
        return stakeAmount;
    }

    function _redeem(address user, uint256 amount) internal override returns (uint256) {
        require(amount <= availableOf(user), "insufficient available user balance");
        //require(amount <= accountStake[user].amount, "insufficient user balance");
        require(amount <= totalSupply, "insufficient total supply");

        comptroller.beforeRedeem(user, amount);

        _updateReward();
        _distributeNewForUser(user);

        totalSupply = totalSupply.sub(amount);
        accountStake[user].amount = accountStake[user].amount.sub(amount);

        uint256 outAmount = _unStakeForWithdraw(amount);

        uint256 withdrawFeeAmount = outAmount > 0 ? estimateWithdrawalFee(user, outAmount) : 0;
        withdrawFeeAmount = _dealWithWithdrawFee(withdrawFeeAmount);
        outAmount = outAmount.sub(withdrawFeeAmount);

        return outAmount;
    }

    function _notifyReward(uint256 amount) internal {
        _updateReward();

        if (block.timestamp >= rewardInfo.lastPeriodEndTime) {
            rewardInfo.accPerSecond = amount.div(rewardInfo.duration);
        } else {
            uint256 remaining = rewardInfo.lastPeriodEndTime.sub(block.timestamp);
            uint256 leftover = remaining.mul(rewardInfo.accPerSecond);
            rewardInfo.accPerSecond = amount.add(leftover).div(rewardInfo.duration);
        }

        uint256 rewardBalance = _rewardBalance();
        require(rewardInfo.accPerSecond <= rewardBalance.div(rewardInfo.duration), "RewardTokenFarmPool: accPerSecond error");

        rewardInfo.lastTime = block.timestamp;
        rewardInfo.lastPeriodEndTime = block.timestamp.add(rewardInfo.duration);
        emit ReceiveReward(amount);
    }

    function _updateReward() internal {
        rewardInfo.accPerShareMantissa = rewardPerShare();
        rewardInfo.lastTime = lastTimeRewardApplicable();
    }

    function _distributeNewForUser(address _user) internal {
        UserRewardState storage userRewardState = userRewardStates[_user];
        if (rewardInfo.accPerShareMantissa == userRewardState.lastAccPerShareMantissa) {
            return;
        }

        uint256 deltaAccPerShareMantissa = rewardInfo.accPerShareMantissa.sub(userRewardState.lastAccPerShareMantissa);
        uint256 userMeasureBalance = shareOf(_user);
        uint256 newAccrued = FixedPoint.multiplyUintByMantissa(userMeasureBalance, deltaAccPerShareMantissa);
        userRewardState.accrued = userRewardState.accrued.add(newAccrued);
        userRewardState.lastAccPerShareMantissa = rewardInfo.accPerShareMantissa;
    }

    function _dealWithWithdrawFee(uint256 withdrawFeeAmount) internal virtual returns (uint256) {
        if (!_checkMinFeeAmount(withdrawFeeAmount)) {
            return 0;
        }
        address pairHIFUSDAddress = PoolInterface(hifPool).rewardToken();
        //zapin
        uint256 amount = _zapInToken(stakedToken(), withdrawFeeAmount, pairHIFUSDAddress);
        //send reward to hif pool
        if (amount > 0) {
            _approveTokenIfNeeded(IERC20Upgradeable(pairHIFUSDAddress), hifPool, amount);
            PoolInterface(hifPool).receiveRewardToken(amount);
        }
        return withdrawFeeAmount;
    }

    function _dealWithPerformanceFee(address user, uint256 performanceFeeAmount) internal virtual returns (uint256) {
        if (!_checkMinFeeAmount(performanceFeeAmount)) {
            return 0;
        }
        address pairHIFUSDAddress = PoolInterface(hifPool).rewardToken();
        //zapin
        uint256 amount = _zapInToken(rewardToken(), performanceFeeAmount, pairHIFUSDAddress);
        //send reward to hif pool
        if (amount > 0) {
            _approveTokenIfNeeded(IERC20Upgradeable(pairHIFUSDAddress), hifPool, amount);
            PoolInterface(hifPool).receiveRewardToken(amount);

            //mint hif token
            comptroller.mintNewRewardForUserInToken(user, rewardToken(), performanceFeeAmount);
        }
        return performanceFeeAmount;
    }

    //modifier
    uint256[50] private __gap;
}


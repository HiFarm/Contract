// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.6.0 <0.7.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";

import "../pool/TokenPool.sol";
import "../pool/RewardTokenFarmPool.sol";
import "../pool/ShareTokenFarmPool.sol";
import "../comptroller/Comptroller.sol";
import "../price/PriceInterface.sol";
import "../libraries/Helper.sol";

contract DashBoard is OwnableUpgradeable {
    using SafeMathUpgradeable for uint256;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    //events

    //structs
    struct PoolInfo {
        uint256 tvl;
        uint256 rewardAPR;
        uint256 rewardAPY;
        uint256 rewardHifAPR;
        uint256 rewardHifAPY;
        uint256 hifAPR;
        uint256 hifAPY;

        uint256 baseProfitDaily;
        uint256 hifProfitDaily;

        uint256 balance;
        uint256 totalShare;

        uint256 withdrawalFeeFactorMantissa;
        uint256 withdrawalFeeFreePeriod;
        uint256 performanceFeeFactorMantissa;
    }
    struct UserInfo {
        uint256 balance;
        uint256 balanceUSD;
        uint256 principal;
        uint256 principalUSD;
        uint256 available;
        uint256 availableUSD;
        uint256 totalBalanceUSD;
        uint256 lastTimestamp;
        uint256 baseProfit;
        uint256 hifProfit;
        uint256 hifFarmProfit;
    }
    struct PoolUserInfo {
        PoolInfo poolInfo;
        UserInfo userInfo;
    }
    struct SummaryInfo {
        uint256 marketCap;
        uint256 hifPrice;
    }


    //variables
    uint256 public constant DUST = 1000;

    //initializer
    function initialize() internal initializer {
        __Ownable_init();
    }

    //view functions
    function summary(address _comptroller) public view returns (SummaryInfo memory) {
        Comptroller comptroller = Comptroller(_comptroller);
        PriceInterface priceProvider = comptroller.priceProvider();
        IERC20Upgradeable hifToken = IERC20Upgradeable(comptroller.hifToken());
        SummaryInfo memory sInfo;
        (, sInfo.hifPrice) = priceProvider.valueOfToken(address(hifToken), 1e18);
        (, sInfo.marketCap) = priceProvider.valueOfToken(address(hifToken), hifToken.totalSupply());
        return sInfo;
    }

    function poolUserInfos(address[] memory _pools, address _user) public view returns (PoolUserInfo[] memory) {
        PoolUserInfo[] memory results = new PoolUserInfo[](_pools.length);
        for (uint i = 0; i < _pools.length; i++) {
            results[i] = poolUserInfo(_pools[i], _user);
        }
        return results;
    }

    function poolUserInfo(address _pool, address _user) public view returns (PoolUserInfo memory) {
        PoolUserInfo memory puInfo;
        puInfo.poolInfo = poolInfo(_pool);
        puInfo.userInfo = userInfo(_pool, _user);
        return puInfo;
    }

    function poolInfo(address _pool) public view returns (PoolInfo memory) {
        TokenPool pool = TokenPool(_pool);
        Comptroller comptroller = Comptroller(address(pool.comptroller()));
        PriceInterface priceProvider = comptroller.priceProvider();
        IERC20Upgradeable hifToken = IERC20Upgradeable(comptroller.hifToken());

        PoolInfo memory pInfo;
        pInfo.tvl = pool.tvl();
        (uint256 apr, uint256 apy) = pool.apRY();
        (pInfo.rewardAPR, pInfo.rewardHifAPR) = _splitRewardAPR(_pool, apr);
        (pInfo.rewardAPY, pInfo.rewardHifAPY) = _splitRewardAPR(_pool, apy);

        uint256 baseAPY = apr > 0 ? pInfo.rewardAPR.add(pInfo.rewardHifAPR) : pInfo.rewardAPY.add(pInfo.rewardHifAPY);
        pInfo.baseProfitDaily = pInfo.tvl.mul(baseAPY).div(1e18).div(365);

        pInfo.hifAPR = comptroller.apr(_pool);
        pInfo.hifAPY = 0;
        //pInfo.hifAPY = Helper.compoundingAPY(pInfo.hifAPR, 1 days);

        pInfo.hifProfitDaily = pInfo.tvl.mul(pInfo.hifAPR).div(1e18).div(365);

        pInfo.balance = pool.balance();
        pInfo.totalShare = pool.totalShare();

        pInfo.withdrawalFeeFactorMantissa = pool.withdrawalFeeFactorMantissa();
        pInfo.withdrawalFeeFreePeriod = pool.withdrawalFeeFreePeriod();
        pInfo.performanceFeeFactorMantissa = pool.performanceFeeFactorMantissa();

        return pInfo;
    }

    function userInfo(address _pool, address _user) public view returns (UserInfo memory) {
        TokenPool pool = TokenPool(_pool);
        Comptroller comptroller = Comptroller(address(pool.comptroller()));
        PriceInterface priceProvider = comptroller.priceProvider();

        UserInfo memory uInfo;
        uInfo.balance = pool.balanceOf(_user);
        (, uInfo.balanceUSD) = priceProvider.valueOfToken(pool.stakedToken(), uInfo.balance);
        uInfo.principal = pool.principalOf(_user);
        (, uInfo.principalUSD) = priceProvider.valueOfToken(pool.stakedToken(), uInfo.principal);
        uInfo.available = pool.availableOf(_user);
        (, uInfo.availableUSD) = priceProvider.valueOfToken(pool.stakedToken(), uInfo.available);
        if (pool.stakedToken() == pool.rewardToken()) {
            (, , uInfo.lastTimestamp) = ShareTokenFarmPool(_pool).accountStake(_user);
        } else {
            (, uInfo.lastTimestamp) = RewardTokenFarmPool(_pool).accountStake(_user);
        }
        (uInfo.baseProfit, uInfo.hifProfit) = userProfit(_pool, _user);
        uInfo.hifFarmProfit = comptroller.earned(_pool, _user);
        (, uint256 baseProfitUSD) = priceProvider.valueOfToken(pool.rewardToken(), uInfo.baseProfit);
        (, uint256 hifProfitUSD) = priceProvider.valueOfToken(address(comptroller.hifToken()), uInfo.hifProfit.add(uInfo.hifFarmProfit));
        uInfo.totalBalanceUSD = uInfo.principalUSD.add(baseProfitUSD).add(hifProfitUSD);
        return uInfo;
    }

    function userProfit(address _pool, address _user) public view returns (uint256 profit, uint256 hif) {
        TokenPool pool = TokenPool(_pool);
        Comptroller comptroller = Comptroller(address(pool.comptroller()));
        PriceInterface priceProvider = comptroller.priceProvider();
        uint256 performanceFeeFactorMantissa = pool.performanceFeeFactorMantissa();

        profit = pool.earned(_user);
        if (_checkMinFeeAmount(_pool, profit)) {
            uint256 performanceFeeAmount = FixedPoint.multiplyUintByMantissa(profit, performanceFeeFactorMantissa);
            (, uint256 valueInUSD) = priceProvider.valueOfToken(pool.rewardToken(), performanceFeeAmount);
            hif = comptroller.amountHifOfUSD(valueInUSD);
            profit = profit.sub(performanceFeeAmount);
        }
    }

    //restricted functions

    //public functions

    //private functions
    function _splitRewardAPR(address _pool, uint256 _baseAPR) internal view returns (uint256, uint256) {
        TokenPool pool = TokenPool(_pool);
        if (pool.zap() == address(0) || pool.hifPool() == address(0)) {
            return (_baseAPR, 0);
        }
        Comptroller comptroller = Comptroller(address(pool.comptroller()));
        PriceInterface priceProvider = comptroller.priceProvider();
        uint256 performanceFeeFactorMantissa = pool.performanceFeeFactorMantissa();

        uint256 perfAPR = FixedPoint.multiplyUintByMantissa(_baseAPR, performanceFeeFactorMantissa);
        (, uint256 hifAPR) = priceProvider.valueOfToken(address(comptroller.hifToken()), comptroller.amountHifOfUSD(perfAPR));
        return (_baseAPR.sub(perfAPR), hifAPR);
    }

    function _checkMinFeeAmount(address _pool, uint256 _feeAmount) internal view returns (bool) {
        TokenPool pool = TokenPool(_pool);
        if (pool.zap() == address(0) || pool.hifPool() == address(0)) {
            return false;
        }
        if (_feeAmount <= DUST) {
            return false;
        }
        return true;
    }

    //modifier

}

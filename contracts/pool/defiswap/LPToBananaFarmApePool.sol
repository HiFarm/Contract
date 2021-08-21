// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.6.12;

import "@openzeppelin/contracts-upgradeable/math/MathUpgradeable.sol";

import "../../external/pancake/IMasterChef.sol";
import "../../libraries/FixedPoint.sol";
import "../../libraries/Helper.sol";
import "../RewardTokenFarmPool.sol";
import "./BananaFarmApePool.sol";

contract LPToBananaFarmApePool is RewardTokenFarmPool {
    //events
    event Harvested(uint256 amount);

    //struct
    //variables
    IERC20Upgradeable private constant BANANA = IERC20Upgradeable(0x603c7f932ED1fc6575303D8Fb018fDCBb0f39a95);
    IMasterChef private constant BANANA_MASTER_CHEF = IMasterChef(0x5c8D727b265DBAfaba67E050f2f739cAeEB4A6F9);
    uint256 public pid;
    BananaFarmApePool public hifBananaPool;
    uint256 private constant blockPerYear = 10512000;

    //initializer
    function initialize(address _comptroller, address _stakedToken, uint256 _pid, address _hifBananaPool) public initializer {
        __RewardTokenFarmPool_init(_comptroller, _stakedToken, address(BANANA), 4 hours);

        (address _token,,,) = BANANA_MASTER_CHEF.poolInfo(_pid);
        if (_token == _stakedToken) {
            pid = _pid;
        }

        hifBananaPool = BananaFarmApePool(_hifBananaPool);
        performanceFeeFactorMantissa = 3e17; //0.3
    }

    //view functions
    function earned(address user) public virtual override view returns (uint256) {
        uint256 shareAmount = super.earned(user);
        return hifBananaPool.amountOfShare(shareAmount);
    }
    
    function tvl() public view virtual override returns (uint256) {
        uint256 valueInUSD = super.tvl();

        uint256 shareAmount = _rewardBalance();
        uint256 cakeAmount = hifBananaPool.amountOfShare(shareAmount);
        PriceInterface priceProvider = comptroller.priceProvider();
        (,uint256 rewardValueInUSD) = priceProvider.valueOfToken(rewardToken(), cakeAmount);

        return valueInUSD.add(rewardValueInUSD);
    }

    function apRY() public view virtual override returns (uint256, uint256) {
        PriceInterface priceProvider = comptroller.priceProvider();
        if (pid == 0) {
            return (0, 0);
        }
        uint256 pAPR = poolAPR(pid);
        uint256 cakeAPR = poolAPR(0);

        uint256 dailyAPY = Helper.compoundingAPY(pAPR, 365 days).div(365);
        uint256 cakeAPY = Helper.compoundingAPY(cakeAPR, 1 days);
        uint256 cakeDailyAPY = Helper.compoundingAPY(cakeAPR, 365 days).div(365);

        uint256 rewardAPY = dailyAPY.mul(cakeAPY).div(cakeDailyAPY);
        return (0, rewardAPY);
    }

    function poolAPR(uint256 _pid) public view returns (uint256) {
        PriceInterface priceProvider = comptroller.priceProvider();
        (address token, uint256 allocPoint,,) = BANANA_MASTER_CHEF.poolInfo(_pid);
        uint256 cakePerYear = BANANA_MASTER_CHEF.cakePerBlock().mul(blockPerYear).mul(allocPoint).div(BANANA_MASTER_CHEF.totalAllocPoint());
        uint256 totalMasterStaked = IERC20Upgradeable(token).balanceOf(address(BANANA_MASTER_CHEF));
        if (totalMasterStaked == 0) {
            return 0;
        }
        (, uint256 totalStakedUSD) = priceProvider.valueOfToken(token, totalMasterStaked);
        (, uint256 totalRewardPerYearUSD) = priceProvider.valueOfToken(address(BANANA), cakePerYear);
        return totalRewardPerYearUSD.mul(1e18).div(totalStakedUSD);
    }

    //restricted functions
    function setPid(uint256 _pid) external onlyOwner {
        (address _token,,,) = BANANA_MASTER_CHEF.poolInfo(_pid);
        if (_token == stakedToken()) {
            pid = _pid;
            _stakeToFarm(_stakedToken().balanceOf(address(this)));
        }
    }

    //public functions
    function harvest() external {
        uint256 harvested = _unStakeFarm(0);
        emit Harvested(harvested);
        //stake harvest
        _stakeHarvest(harvested);
    }

    //private functions
    function _stakeToFarm(uint256 amount) internal override returns (uint256) {
        uint256 harvested = _stakeFarm(amount);
        //stake harvest
        _stakeHarvest(harvested);

        return amount;
    }
    function _unStakeForWithdraw(uint256 amount) internal override returns (uint256) {
        uint256 harvested = _unStakeFarm(amount);
        //stake harvest
        _stakeHarvest(harvested);
        return amount;
    }

    function _balanceOfFarm() internal view override returns (uint256) {
        if (pid > 0) {
            (uint256 amount,) = BANANA_MASTER_CHEF.userInfo(pid, address(this));
            return amount;
        }
        return 0;
    }

    function _rewardBalance() internal view override returns (uint256) {
        return hifBananaPool.shareOf(address(this));
    }

    function _convertAccrued(uint256 share) internal virtual override returns (uint256) {
        uint256 currentShare = MathUpgradeable.min(share, _rewardBalance());
        if (currentShare == 0) {
            return 0;
        }
        uint256 before = _rewardToken().balanceOf(address(this));
        hifBananaPool.withdrawShare(currentShare);
        uint256 userRewardAmount = _rewardToken().balanceOf(address(this)).sub(before);
        return userRewardAmount;
    }

    function _transferOutReward(address user, uint256 amount) internal override returns (uint256) {
        if (amount > 0) {
            _rewardToken().safeTransfer(user, amount);
        }
        return amount;
    }

    function _stakeFarm(uint256 amount) internal returns (uint256) {
        if (amount > 0 && pid > 0) {
            uint256 before = _rewardToken().balanceOf(address(this));
            _approveTokenIfNeeded(_stakedToken(), address(BANANA_MASTER_CHEF), amount);
            BANANA_MASTER_CHEF.deposit(pid, amount);
            uint256 harvested = _rewardToken().balanceOf(address(this)).sub(before);
            return harvested;
        }
        return 0;
    }
    function _unStakeFarm(uint256 amount) internal returns (uint256) {
        if (pid > 0) {
            uint256 before = _rewardToken().balanceOf(address(this));
            BANANA_MASTER_CHEF.withdraw(pid, amount);
            uint256 harvested = _rewardToken().balanceOf(address(this)).sub(before);
            return harvested;
        }
        return 0;
    }

    function _stakeHarvest(uint256 rewardAmount) internal {
        if (rewardAmount == 0) {
            return;
        }
        uint256 before = hifBananaPool.shareOf(address(this));
        _approveTokenIfNeeded(_rewardToken(), address(hifBananaPool), rewardAmount);
        hifBananaPool.depositTokenTo(address(this), rewardAmount);
        uint256 amount = hifBananaPool.shareOf(address(this)).sub(before);
        if (amount > 0) {
            _notifyReward(amount);
        }
    }
    //modifier
}



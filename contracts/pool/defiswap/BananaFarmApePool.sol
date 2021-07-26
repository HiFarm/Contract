// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.6.0 <0.7.0;

import "@openzeppelin/contracts-upgradeable/math/MathUpgradeable.sol";

import "../../external/pancake/IMasterChef.sol";
import "../../libraries/FixedPoint.sol";
import "../../libraries/Helper.sol";
import "../ShareTokenFarmPool.sol";

contract BananaFarmApePool is ShareTokenFarmPool {
    //events
    event Harvested(uint256 amount);

    //struct
    //variables
    uint256 private constant pid = 0;
    IERC20Upgradeable private constant BANANA = IERC20Upgradeable(0x603c7f932ED1fc6575303D8Fb018fDCBb0f39a95);
    IMasterChef private constant BANANA_MASTER_CHEF = IMasterChef(0x5c8D727b265DBAfaba67E050f2f739cAeEB4A6F9);
    uint256 private constant blockPerYear = 10512000;

    //initializer
    function initialize(address _comptroller) public initializer {
        __ShareTokenFarmPool_init(_comptroller, address(BANANA));
        performanceFeeFactorMantissa = 3e17; //0.3
    }

    //view functions
    function apRY() public view virtual override returns (uint256, uint256) {
        //PriceInterface priceProvider = comptroller.priceProvider();
        (, uint256 allocPoint,,) = BANANA_MASTER_CHEF.poolInfo(pid);
        uint256 cakePerYear = BANANA_MASTER_CHEF.cakePerBlock().mul(blockPerYear).mul(allocPoint).div(BANANA_MASTER_CHEF.totalAllocPoint());
        //scale e18
        uint256 totalMasterStaked = BANANA.balanceOf(address(BANANA_MASTER_CHEF));
        if (totalMasterStaked == 0) {
            return (0, 0);
        }
        uint256 rewardAPR = cakePerYear.mul(1e18).div(totalMasterStaked);
        uint256 rewardAPY = Helper.compoundingAPY(rewardAPR, 1 days);
        return (0, rewardAPY);
    }

    //restricted functions

    //public functions
    function harvest() external {
        uint256 balance = _unStakeFarm(0);
        emit Harvested(balance);
        _stakeFarm(balance);
    }

    //private functions
    function _stakeToFarm(uint256 amount) internal override returns (uint256) {
        uint256 harvested = _stakeFarm(amount);
        //restake harvest
        _stakeFarm(harvested);

        return amount;
    }

    function _unStakeForWithdraw(uint256 amount) internal override returns (uint256) {
        uint256 harvested = _unStakeFarm(amount);

        //restake harvest
        _stakeFarm(harvested);
        return amount;
    }

    function _balance() internal virtual override view returns (uint256) {
        (uint256 amount,) = BANANA_MASTER_CHEF.userInfo(pid, address(this));
        return amount;
    }

    function _pendingFarmReward() internal view returns (uint256) {
        return BANANA_MASTER_CHEF.pendingCake(pid, address(this));
    }

    function _stakeFarm(uint256 amount) internal returns (uint256) {
        if (amount > 0) {
            uint256 before = _stakedToken().balanceOf(address(this));
            _approveTokenIfNeeded(_stakedToken(), address(BANANA_MASTER_CHEF), amount);
            BANANA_MASTER_CHEF.enterStaking(amount);
            uint256 harvested = _stakedToken().balanceOf(address(this)).add(amount).sub(before);
            return harvested;
        }
        return 0;
    }

    function _unStakeFarm(uint256 amount) internal returns (uint256) {
        uint256 before = _stakedToken().balanceOf(address(this));
        BANANA_MASTER_CHEF.leaveStaking(amount);
        uint256 harvested = _stakedToken().balanceOf(address(this)).sub(amount).sub(before);
        return harvested;
    }

    //modifier
}



// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.6.0 <0.7.0;

import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/math/MathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/SafeCastUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";

import "../libraries/OwnerPausableUpgradeable.sol";
import "../libraries/FixedPoint.sol";
import "../pool/PoolInterface.sol";
import "../token/HIFarmToken.sol";
import "../price/PriceInterface.sol";
import "./ComptrollerInterface.sol";

contract Comptroller is ComptrollerInterface, OwnerPausableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeMathUpgradeable for uint256;
    using SafeCastUpgradeable for uint256;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    //events
    event Claim(address indexed user, address indexed pool, uint256 amount);
    event MintNewReward(address indexed pool, uint256 amount);

    //structs
    struct ExtendRewardInfo {
        uint256 accPerSecond;
        uint256 lastTime;
        uint256 lastPeriodEndTime;
        uint256 duration;
    }
    struct Market {
        uint256 accPerSecond;
        uint256 accPerShareMantissa;
        uint256 lastTime;
        bool isListed;
        bool isPaused;
    }
    struct UserState {
        uint256 lastAccPerShareMantissa;
        uint256 accrued;
    }

    //variables
    address[] public allMarkets;
    mapping(address => Market) public markets;
    mapping(address => ExtendRewardInfo) public marketExtendRewardInfos;
    mapping(address => mapping(address => UserState)) public userStates;

    address public devaddr;
    address public treasurer;
    HIFarmToken public override hifToken;
    PriceInterface public override priceProvider;
    address public hifPool;
    uint256 public exchangeRateMantissa;
    mapping(address => bool) public isWhiteList;

    address public override preSaleLauncher;
    uint256 public override preSaleReleaseAt;
    mapping(address => bool) public minterList;

    //initializer
    function initialize(address _hifToken, address _priceProvider, address _devaddr, address _treasurer) public initializer {
        __OwnerPausable_init();
        __ReentrancyGuard_init();

        exchangeRateMantissa = 10e18;

        devaddr = _devaddr;
        treasurer = _treasurer;
        hifToken = HIFarmToken(_hifToken);
        priceProvider = PriceInterface(_priceProvider);
    }

    //view functions
    function getAllMarkets() public view override returns (address[] memory) {
        return allMarkets;
    }

    function isInMarket(address _pool) public view override returns (bool) {
        return markets[_pool].isListed;
    }

    function isInWhiteList(address _addr) public view override returns (bool) {
        if (_addr == address(this) || isInMarket(_addr) || isWhiteList[_addr]) {
            return true;
        }
        return false;
    }

    function isMinter(address _addr) public view override returns (bool) {
        if (isInMarket(_addr) || minterList[_addr]) {
            return true;
        }
        return false;
    }

    function amountHifOfUSD(uint256 _usdAmount) public view override returns (uint256){
        return FixedPoint.multiplyUintByMantissa(_usdAmount, exchangeRateMantissa);
    }

    function amountHifOfToken(address _token, uint256 _amount) public view override returns (uint256) {
        (, uint256 valueInUSD) = priceProvider.valueOfToken(_token, _amount);
        uint256 hifAmount = amountHifOfUSD(valueInUSD);
        return hifAmount;
    }

    function earned(address _pool, address _user) public override view returns (uint256) {
        UserState storage userState = userStates[_pool][_user];
        uint256 userAccrued = userState.accrued;

        uint256 accPerShareMantissa = rewardPerShare(_pool);
        uint256 deltaAccPerShareMantissa = accPerShareMantissa.sub(userState.lastAccPerShareMantissa);
        uint256 userMeasureBalance = PoolInterface(_pool).shareOf(_user);
        uint256 newAccrued = FixedPoint.multiplyUintByMantissa(userMeasureBalance, deltaAccPerShareMantissa);
        userAccrued = userAccrued.add(newAccrued);
        return userAccrued;
    }

    function apr(address _pool) public view returns (uint256) {
        Market storage market = markets[_pool];
        uint256 accHIFPerSecond = rewardPerSecond(_pool);

        uint256 measureTotalSupply = PoolInterface(_pool).totalShare();
        uint256 accHIFPerSecondPerShareMantissa = FixedPoint.calculateMantissa(accHIFPerSecond, measureTotalSupply > 0 ? measureTotalSupply : FixedPoint.SCALE);

        uint256 bnbPerShare = priceProvider.getBNBPerToken(PoolInterface(_pool).stakedToken()); //scale e18
        uint256 bnbPerHIF = priceProvider.getBNBPerToken(address(hifToken)); //scale e18

        //accBNBPerSecondPerShare = FixedPoint.multiplyUintByMantissa(accPerSecondPerShareMantissa, bnbPerRewardToken)
        uint256 rewardAPR = FixedPoint.multiplyUintByMantissa(bnbPerHIF, accHIFPerSecondPerShareMantissa).mul(1e18).mul(365 days).div(bnbPerShare);
        return rewardAPR;
    }

    function rewardPerSecond(address _pool) public view returns (uint256) {
        Market storage market = markets[_pool];
        uint256 accPerSecond = market.accPerSecond;
        ExtendRewardInfo storage extendRewardInfo = marketExtendRewardInfos[_pool];
        uint256 extendDeltaTimes = lastTimeExtendRewardApplicable(_pool).sub(extendRewardInfo.lastTime);
        if (extendDeltaTimes > 0) {
            accPerSecond = accPerSecond.add(extendRewardInfo.accPerSecond);
        }
        return accPerSecond;
    }

    function lastTimeExtendRewardApplicable(address _pool) public view returns (uint256) {
        return MathUpgradeable.min(block.timestamp, marketExtendRewardInfos[_pool].lastPeriodEndTime);
    }

    function rewardPerShare(address _pool) public view returns (uint256) {
        Market storage market = markets[_pool];

        uint256 blockTime = block.timestamp;
        uint256 deltaTimes = blockTime.sub(market.lastTime);
        uint256 accPerShareMantissa = market.accPerShareMantissa;

        uint256 accrued = 0;
        if (deltaTimes > 0 && market.accPerSecond > 0) {
            accrued = deltaTimes.mul(market.accPerSecond);
        }
        ExtendRewardInfo storage extendRewardInfo = marketExtendRewardInfos[_pool];
        uint256 extendDeltaTimes = lastTimeExtendRewardApplicable(_pool).sub(extendRewardInfo.lastTime);
        if (extendDeltaTimes > 0) {
            accrued = accrued.add(extendDeltaTimes.mul(extendRewardInfo.accPerSecond));
        }
        if (accrued > 0) {
            uint256 measureTotalSupply = PoolInterface(_pool).totalShare();
            if (measureTotalSupply > 0) {
                uint256 newAccPerShareMantissa = FixedPoint.calculateMantissa(accrued, measureTotalSupply);
                accPerShareMantissa = accPerShareMantissa.add(newAccPerShareMantissa);
            }
        }

        return accPerShareMantissa;
    }

    //restricted functions
    function setDev(address _devaddr) external onlyOwner {
        devaddr = _devaddr;
    }

    function setTreasurer(address _treasurer) external onlyOwner {
        treasurer = _treasurer;
    }

    function setHIFToken(address _hifToken) external onlyOwner {
        hifToken = HIFarmToken(_hifToken);
    }

    function setHIFPool(address _hifPool) external onlyOwner {
        hifPool = _hifPool;
    }

    function setPriceProvider(address _priceProvider) external onlyOwner {
        priceProvider = PriceInterface(_priceProvider);
    }

    function setWhiteList(address _addr, bool _enable) public onlyOwner {
        isWhiteList[_addr] = _enable;
    }

    function setMinter(address _addr, bool _enable) public onlyOwner {
        minterList[_addr] = _enable;
    }

    function addMarket(address _pool, uint256 _accPerSecond) public onlyOwner {
        PoolInterface(_pool).isHIFPool();

        Market storage market = markets[_pool];
        require(!market.isListed, 'Comptroller: market is listed');
        markets[_pool] = Market({
            accPerSecond: _accPerSecond,
            accPerShareMantissa: 0,
            lastTime: block.timestamp,
            isListed: true,
            isPaused: false
        });
        ExtendRewardInfo storage extendRewardInfo = marketExtendRewardInfos[_pool];
        extendRewardInfo.duration = 24 hours;

        for (uint i = 0; i < allMarkets.length; i ++) {
            require(allMarkets[i] != _pool, "Comptroller: market already added");
        }
        allMarkets.push(_pool);
    }

    function setMarketAccPerBlock(address _pool, uint256 _accPerSecond) public onlyOwner {
        // ensure we're all caught up
        _updateReward(_pool);

        markets[_pool].accPerSecond = _accPerSecond;
    }

    function setMarketPaused(address _pool, bool _paused) public onlyOwner {
        markets[_pool].isPaused = _paused;
    }

    function setExtendRewardsDuration(address _pool, uint256 _duration) external onlyOwner {
        ExtendRewardInfo storage extendRewardInfo = marketExtendRewardInfos[_pool];
        require(extendRewardInfo.lastPeriodEndTime == 0 || block.timestamp > extendRewardInfo.lastPeriodEndTime, "Comptroller: period");
        extendRewardInfo.duration = _duration;
    }

    function setExchangeRateMantissa(uint256 _exchangeRateMantissa) public onlyOwner {
        exchangeRateMantissa = _exchangeRateMantissa;
    }

    function setPreSaleLauncher(address _launcher) external onlyOwner {
        preSaleLauncher = _launcher;
        isWhiteList[_launcher] = true;
    }

    function setPreSaleReleaseAt(uint256 _releaseAt) external onlyOwner {
        preSaleReleaseAt = _releaseAt;
    }

    function mintNewFarmReward(address _pool, uint256 _amount) external override onlyOwner {
        _mintNewFarmReward(_pool, _amount);
    }

    function mintNewRewardForLauncher(address _to, uint256 _amount) external override onlyPreSaleLauncher whenNotPaused {
        _mintReward(_to, _amount, true);
    }

    function mintNewRewardForUserInToken(address _user, address _token, uint256 _amount) external override onlyMinters whenNotPaused {
        (, uint256 valueInUSD) = priceProvider.valueOfToken(_token, _amount);
        uint256 hifAmount = amountHifOfUSD(valueInUSD);
        _mintReward(_user, hifAmount, true);
    }

    function beforeSupply(address _user, uint256 _amount) external override onlyPools whenNotPaused {
        _amount;
        _beforeUpdate(msg.sender, _user);
    }

    function beforeRedeem(address _user, uint256 _amount) external override onlyPools whenNotPaused {
        _amount;
        _beforeUpdate(msg.sender, _user);
    }

    function claim(address _user) external override onlyPools whenNotPaused {
        _beforeUpdate(msg.sender, _user);

        UserState storage userState = userStates[msg.sender][_user];

        uint256 amount = userState.accrued;
        userState.accrued = 0;

        if (msg.sender == hifPool) {
            _mintReward(_user, amount, false);
        } else {
            _mintReward(_user, amount, true);
        }

        emit Claim(_user, msg.sender, amount);
    }

    //public functions

    //private functions
    function _approveTokenIfNeeded(IERC20Upgradeable _token, address _spender, uint256 _amount) internal {
        if (_token.allowance(address(this), _spender) < _amount) {
            _token.safeIncreaseAllowance(_spender, _amount);
        }
    }

    function _beforeUpdate(address _pool, address _user) internal {
        Market storage market = markets[_pool];
        require(!market.isPaused, 'Comptroller: market is paused');
        require(market.isListed, 'Comptroller: market is not listed');

        _updateReward(_pool);
        _distributeNewForUser(_pool, _user);
    }

    function _updateReward(address _pool) internal {
        Market storage market = markets[_pool];

        market.accPerShareMantissa = rewardPerShare(_pool);
        market.lastTime = block.timestamp;

        marketExtendRewardInfos[_pool].lastTime = lastTimeExtendRewardApplicable(_pool);
    }

    function _distributeNewForUser(address _pool, address _user) internal {
        Market storage market = markets[_pool];
        UserState storage userState = userStates[_pool][_user];
        if (market.accPerShareMantissa == userState.lastAccPerShareMantissa) {
            return;
        }

        uint256 deltaAccPerShareMantissa = market.accPerShareMantissa.sub(userState.lastAccPerShareMantissa);
        uint256 userMeasureBalance = PoolInterface(_pool).shareOf(_user);
        uint256 newAccrued = FixedPoint.multiplyUintByMantissa(userMeasureBalance, deltaAccPerShareMantissa);
        userState.accrued = userState.accrued.add(newAccrued);
        userState.lastAccPerShareMantissa = market.accPerShareMantissa;
    }

    function _mintNewFarmReward(address _pool, uint256 _amount) internal {
        if (_amount == 0) {
            return;
        }

        _updateReward(_pool);

        ExtendRewardInfo storage extendRewardInfo = marketExtendRewardInfos[_pool];
        if (block.timestamp >= extendRewardInfo.lastPeriodEndTime) {
            extendRewardInfo.accPerSecond = _amount.div(extendRewardInfo.duration);
        } else {
            uint256 remaining = extendRewardInfo.lastPeriodEndTime.sub(block.timestamp);
            uint256 leftover = remaining.mul(extendRewardInfo.accPerSecond);
            extendRewardInfo.accPerSecond = _amount.add(leftover).div(extendRewardInfo.duration);
        }

        extendRewardInfo.lastTime = block.timestamp;
        extendRewardInfo.lastPeriodEndTime = block.timestamp.add(extendRewardInfo.duration);

        emit MintNewReward(_pool, _amount);
    }

    function _mintReward(address _to, uint256 _amount, bool _compound) internal {
        if (_amount == 0) {
            return;
        }
        uint256 devAmount = _amount.mul(15).div(100);
        uint256 treasureAmount = _amount.mul(5).div(100);

        hifToken.mint(_to, _amount);

        if (_compound && hifPool != address(0)) {
            uint256 mintAmount = devAmount.add(treasureAmount);
            hifToken.mint(address(this), devAmount.add(treasureAmount));
            _approveTokenIfNeeded(hifToken, hifPool, mintAmount);
            PoolInterface(hifPool).depositTokenTo(devaddr, devAmount);
            PoolInterface(hifPool).depositTokenTo(treasurer, treasureAmount);
        } else {
            hifToken.mint(devaddr, devAmount);
            hifToken.mint(treasurer, treasureAmount);
        }
    }

    //modifier
    modifier onlyPools() {
        require(markets[msg.sender].isListed, "Comptroller: only pool is allowed");
        _;
    }

    modifier onlyPoolsOrOwner() {
        require(markets[msg.sender].isListed || msg.sender == owner(), "Comptroller: only pool/owner is allowed");
        _;
    }

    modifier onlyPreSaleLauncher() {
        require(msg.sender == preSaleLauncher, "Comptroller: only preSaleLauncher is allowed");
        _;
    }

    modifier onlyMinters() {
        require(isMinter(msg.sender), "Comptroller: only minter is allowed");
        _;
    }

}

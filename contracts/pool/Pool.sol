// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.6.12;

import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/SafeCastUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/introspection/ERC165CheckerUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";

import "../libraries/OwnerPausableUpgradeable.sol";
import "../comptroller/ComptrollerInterface.sol";
import "./PoolInterface.sol";

abstract contract Pool is PoolInterface, OwnerPausableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeMathUpgradeable for uint256;
    using SafeCastUpgradeable for uint256;
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using ERC165CheckerUpgradeable for address;

    //events
    event Deposit(address indexed from, address indexed to, uint256 amount);
    event Withdraw(address indexed to, uint256 amount);
    event ClaimReward(address indexed to, uint256 amount);
    event ReceiveReward(uint256 amount);

    //structs

    //variables
    bool public constant override isHIFPool = true;
    ComptrollerInterface public comptroller;
    uint256 public withdrawalFeeFactorMantissa;
    uint256 public withdrawalFeeFreePeriod;
    uint256 public performanceFeeFactorMantissa;

    //initializer
    function __Pool_init(address _comptroller) internal initializer {
        __OwnerPausable_init();
        __ReentrancyGuard_init();

        comptroller = ComptrollerInterface(_comptroller);
        withdrawalFeeFreePeriod = 3 days;
        withdrawalFeeFactorMantissa = 5e15; //0.005
        //performanceFeeFactorMantissa = 3e17; //0.3
    }

    //view functions
    function stakedToken() public view override returns (address) {
        return address(_stakedToken());
    }

    function rewardToken() public view override returns (address) {
        return address(_rewardToken());
    }

    function balance() public view override returns (uint256) {
        return _balance();
    }

    function principalOf(address user) public view virtual returns (uint256);

    function availableOf(address user) public view virtual returns (uint256);

    function tvl() public view virtual returns (uint256);
    function apRY() public view virtual returns (uint256, uint256);

    //restricted functions
    function setComptroller(address _comptroller) external onlyOwner {
        comptroller = ComptrollerInterface(_comptroller);
    }
    function setWithdrawalFeeFactorMantissa(uint256 _withdrawalFeeFactorMantissa) external onlyOwner {
        withdrawalFeeFactorMantissa = _withdrawalFeeFactorMantissa;
    }

    function setWithdrawalFeeFreePeriod(uint256 _withdrawalFeeFreePeriod) external onlyOwner {
        withdrawalFeeFreePeriod = _withdrawalFeeFreePeriod;
    }

    function setPerformanceFeeFactorMantissa(uint256 _performanceFeeFactorMantissa) external onlyOwner {
        performanceFeeFactorMantissa = _performanceFeeFactorMantissa;
    }

    //public functions
    function depositTo(address user) external payable override notContract whenNotPaused nonReentrant {
        require(address(_stakedToken()) == address(0), 'Pool: invalid asset');
        _supplyInternal(msg.sender, user, msg.value);
    }

    function depositTokenTo(address user, uint256 amount) external override notContract whenNotPaused nonReentrant {
        require(address(_stakedToken()) != address(0), 'Pool: invalid asset');
        _supplyInternal(msg.sender, user, amount);
    }
    function withdraw(uint256 amount) external override notContract whenNotPaused nonReentrant {
        _redeemInternal(msg.sender, amount);
    }

    function withdrawShare(uint256 share) external override notContract whenNotPaused nonReentrant {
        _redeemShareInternal(msg.sender, share);
    }

    function receiveReward() external payable virtual override whenNotPaused nonReentrant {
        revert('not support');
    }

    function receiveRewardToken(uint256 amount) external virtual override whenNotPaused nonReentrant {
        revert('not support');
    }

    //private functions
    function _stakedToken() internal virtual view returns (IERC20Upgradeable);

    function _rewardToken() internal virtual view returns (IERC20Upgradeable);

    function _balance() internal virtual view returns (uint256);

    function _supply(address from, address minter, uint256 amount) internal virtual returns (uint256);
    function _redeem(address user, uint256 amount) internal virtual returns (uint256);
    function _redeemShare(address user, uint256 share) internal virtual returns (uint256) {
        revert('_redeemShare not support');
    }

    function _doTransferIn(IERC20Upgradeable token, address from, uint256 amount) internal virtual returns (uint256);
    function _doTransferOut(IERC20Upgradeable token, address to, uint amount) internal virtual;

    function _supplyInternal(address from, address user, uint256 amount) internal virtual returns (uint256) {
        _doTransferIn(_stakedToken(), from, amount);

        uint256 stakeAmount = _supply(from, user, amount);

        emit Deposit(from, user, stakeAmount);
    }

    function _redeemInternal(address user, uint256 amount) internal virtual returns (uint256) {
        uint256 redeemed = _redeem(user, amount);

        _doTransferOut(_stakedToken(), user, redeemed);

        emit Withdraw(user, redeemed);
    }

    function _redeemShareInternal(address user, uint256 share) internal virtual returns (uint256) {
        uint256 redeemed = _redeemShare(user, share);

        _doTransferOut(_stakedToken(), user, redeemed);

        emit Withdraw(user, redeemed);
    }

    function _approveTokenIfNeeded(IERC20Upgradeable _ERC20Token, address _spender, uint256 _amount) internal virtual {
        if (_ERC20Token.allowance(address(this), _spender) < _amount) {
            _ERC20Token.safeApprove(_spender, 0);
            _ERC20Token.safeApprove(_spender, uint(~0));
        }
    }

    function _currentTime() internal virtual view returns (uint256) {
        return block.timestamp;
    }
    //modifier
    modifier notContract() {
        if (!comptroller.isInWhiteList(msg.sender)) {
            require(!AddressUpgradeable.isContract(msg.sender), "contract is not allowed");
            require(msg.sender == tx.origin, "no proxy contract is allowed");
        }
        _;
    }

    uint256[50] private __gap;
}

// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.6.0 <0.7.0;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";

import "../external/pancake/IPancakeFactory.sol";
import "../external/pancake/IPancakePair.sol";
import "../external/pancake/IPancakeRouter02.sol";
import "../libraries/OwnerPausableUpgradeable.sol";
import "../libraries/TransferHelper.sol";
import "./ZapInterface.sol";

contract Zap is ZapInterface, OwnerPausableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeMathUpgradeable for uint256;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    //events

    //structs

    //variables
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
    //IPancakeFactory private constant FACTORYV1 = IPancakeFactory(0xBCfCcbde45cE874adCB698cC183deBcF17952812);
    //IPancakeRouter02 private constant ROUTERV1 = IPancakeRouter02(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F);
    IPancakeFactory private constant FACTORYV2 = IPancakeFactory(0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73);
    IPancakeRouter02 private constant ROUTERV2 = IPancakeRouter02(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    mapping(address => address) public routePairAddresses;

    address public hifToken;

    //initializer
    function initialize(address _hifToken) public initializer {
        __OwnerPausable_init();
        __ReentrancyGuard_init();
        hifToken = _hifToken;
        routePairAddresses[hifToken] = BUSD;
    }

    receive() external payable {}

    //view functions

    //restricted functions
    function setRoutePairAddress(address _token, address _route) external onlyOwner {
        routePairAddresses[_token] = _route;
    }

    function sweep(address[] calldata _tokens) external onlyOwner {
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            uint amount = IERC20Upgradeable(token).balanceOf(address(this));
            if (amount > 0) {
                _swapTokenForBNB(token, amount, owner());
            }
        }
    }

    function withdraw(address _token) external onlyOwner {
        if (_token == address(0)) {
            TransferHelper.safeTransferETH(owner(), address(this).balance);
        } else {
            IERC20Upgradeable(_token).safeTransfer(owner(), IERC20Upgradeable(_token).balanceOf(address(this)));
        }
    }

    //public functions
    function zapIn(address _fromToken, uint256 _amount, address _pairAddress) external payable override nonReentrant whenNotPaused {
        if (_fromToken == address(0)) {
            _zapIn(msg.value, _pairAddress, msg.sender);
        } else if (_compareStrings(ERC20Upgradeable(_fromToken).symbol(), "Cake-LP")) {
            IERC20Upgradeable(_fromToken).safeTransferFrom(msg.sender, address(this), _amount);
            _zapInLP(_fromToken, _amount, _pairAddress, msg.sender);
        } else {
            IERC20Upgradeable(_fromToken).safeTransferFrom(msg.sender, address(this), _amount);
            _zapInToken(_fromToken, _amount, _pairAddress, msg.sender);
        }
    }

    function swapTokenForToken(address _fromToken, uint256 _amount, address _toToken) external override nonReentrant whenNotPaused returns (uint256) {
        IERC20Upgradeable(_fromToken).safeTransferFrom(msg.sender, address(this), _amount);
        return _swapTokenForToken(_fromToken, _amount, _toToken, msg.sender);
    }

    function swapForToken(address _token) external payable override nonReentrant whenNotPaused returns (uint256) {
        return _swapBNBForToken(_token, msg.value, msg.sender);
    }

    function zapOut(address _pairAddress, uint256 _amount, address _to) external override nonReentrant whenNotPaused returns (uint256) {
        IERC20Upgradeable(_pairAddress).safeTransferFrom(msg.sender, address(this), _amount);
        return _zapOut(_pairAddress, _amount, _to);
    }

    function zapOutUSD(address _pairAddress, uint256 _amount, address _to) external override nonReentrant whenNotPaused returns (uint256) {
        IERC20Upgradeable(_pairAddress).safeTransferFrom(msg.sender, address(this), _amount);
        return _zapOutUSD(_pairAddress, _amount, _to);
    }

    function zapOutForToken(address _pairAddress, uint256 _amount, address _to) external override nonReentrant whenNotPaused returns (uint256, uint256) {
        IERC20Upgradeable(_pairAddress).safeTransferFrom(msg.sender, address(this), _amount);
        return _removeLiquidity(_pairAddress, _amount, _to);
    }

    //private functions
    function _approveTokenIfNeeded(address _token, uint256 _amount) internal {
        if (IERC20Upgradeable(_token).allowance(address(this), address(ROUTERV2)) < _amount) {
            IERC20Upgradeable(_token).safeIncreaseAllowance(address(ROUTERV2), _amount);
        }
    }

    function _compareStrings(string memory a, string memory b) internal pure returns (bool) {
        return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b))));
    }

    function _transferIn(IERC20Upgradeable _token, address _from, uint256 _amount) internal {
        if (address(_token) == address(0)) {
            require(msg.sender == _from, "sender mismatch");
            require(msg.value == _amount, "invalid amount");
        } else {
            _token.safeTransferFrom(_from, address(this), _amount);
        }
    }

    function _getPairTokens(address _pairAddress) internal view returns (address token0, address token1) {
        IPancakePair pair = IPancakePair(_pairAddress);
        token0 = pair.token0();
        token1 = pair.token1();
    }

    function _zapInLP(address _fromPairAddress, uint256 _amount, address _toPairAddress, address _to) internal {
        if (_fromPairAddress == _toPairAddress) {
            IERC20Upgradeable(_fromPairAddress).safeTransferFrom(address(this), _to, _amount);
            return;
        }
        (uint256 amount0, uint256 amount1) = _removeLiquidity(_fromPairAddress, _amount, address(this));
        (address fromToken0, address fromToken1) = _getPairTokens(_fromPairAddress);
        if (fromToken0 == WBNB) {
            _zapIn(amount0, _toPairAddress, _to);
        } else {
            _zapInToken(fromToken0, amount0, _toPairAddress, _to);
        }

        if (fromToken1 == WBNB) {
            _zapIn(amount1, _toPairAddress, _to);
        } else {
            _zapInToken(fromToken1, amount1, _toPairAddress, _to);
        }
    }

    function _zapInToken(address _fromToken, uint256 _amount, address _pairAddress, address _to) internal {
        (address token0, address token1) = _getPairTokens(_pairAddress);
        if (_fromToken == token0 || _fromToken == token1) {
            address otherToken = _fromToken == token0 ? token1 : token0;
            uint256 amountToSwap = _amount.div(2);
            uint256 otherAmount = _swapTokenForToken(_fromToken, amountToSwap, otherToken, address(this));
            _addLiquidity(_fromToken, otherToken, _amount.sub(amountToSwap), otherAmount, _to);
        } else {
            uint256 bnbAmount = _swapTokenForBNB(_fromToken, _amount, address(this));
            _swapBNBToLP(bnbAmount, _pairAddress, _to);
        }
    }

    function _zapIn(uint256 _value, address _pairAddress, address _to) internal {
        _swapBNBToLP(_value, _pairAddress, _to);
    }

    function _zapOut(address _pairAddress, uint256 _amount, address _to) internal returns (uint256) {
        (address token0, address token1) = _getPairTokens(_pairAddress);
        (uint256 amount0, uint256 amount1) = _removeLiquidity(_pairAddress, _amount, address(this));

        uint256 bnbAmount0 = token0 == WBNB ? amount0 : _swapTokenForBNB(token0, amount0, address(this));
        uint256 bnbAmount1 = token1 == WBNB ? amount1 : _swapTokenForBNB(token1, amount1, address(this));

        uint256 outAmount = bnbAmount0.add(bnbAmount1);
        TransferHelper.safeTransferETH(_to, outAmount);
        return outAmount;
    }

    function _zapOutUSD(address _pairAddress, uint256 _amount, address _to) internal returns (uint256) {
        (address token0, address token1) = _getPairTokens(_pairAddress);
        (uint256 amount0, uint256 amount1) = _removeLiquidity(_pairAddress, _amount, address(this));

        uint256 usdAmount0 = token0 == BUSD ? amount0 : _swapTokenForToken(token0, amount0, BUSD, address(this));
        uint256 usdAmount1 = token1 == BUSD ? amount1 : _swapTokenForToken(token1, amount1, BUSD, address(this));

        uint256 outAmount = usdAmount0.add(usdAmount1);
        IERC20Upgradeable(BUSD).safeTransfer(_to, outAmount);
        return outAmount;
    }

    function _swapBNBToLP(uint256 _value, address _pairAddress, address _to) internal {
        (address token0, address token1) = _getPairTokens(_pairAddress);
        address _fromToken = WBNB;
        uint256 amountToSwap = _value.div(2);
        if (_fromToken == token0 || _fromToken == token1) {
            address otherToken = _fromToken == token0 ? token1 : token0;
            uint256 otherAmount = _swapBNBForToken(otherToken, amountToSwap, address(this));
            _addLiquidityBNB(_value.sub(amountToSwap), otherToken, otherAmount, msg.sender);
        } else {
            uint256 token0Amount = _swapBNBForToken(token0, amountToSwap, address(this));
            uint256 token1Amount = _swapBNBForToken(token1, _value.sub(amountToSwap), address(this));
            _addLiquidity(token0, token1, token0Amount, token1Amount, _to);
        }
    }

    function _addLiquidity(address _token0, address _token1, uint256 _amount0Desired, uint256 _amount1Desired, address _to) internal returns (uint256, uint256, uint256) {
        _approveTokenIfNeeded(_token0, _amount0Desired);
        _approveTokenIfNeeded(_token1, _amount1Desired);
        return ROUTERV2.addLiquidity(_token0, _token1, _amount0Desired, _amount1Desired, 0, 0, _to, block.timestamp);
    }

    function _addLiquidityBNB(uint256 _value, address _token1, uint256 _amount1Desired, address _to) internal returns (uint256, uint256, uint256) {
        _approveTokenIfNeeded(_token1, _amount1Desired);
        return ROUTERV2.addLiquidityETH{value: _value}(_token1, _amount1Desired, 0, 0, _to, block.timestamp);
    }

    function _removeLiquidity(address _pairAddress, uint256 _liquidity, address _to) internal returns (uint256 amount0, uint256 amount1) {
        //uint256 pairLPBalance = IERC20Upgradeable(_pairAddress).balanceOf(_pairAddress);
        //require(pairLPBalance == 0, "invalid lp balance");

        _approveTokenIfNeeded(_pairAddress, _liquidity);
        (address token0, address token1) = _getPairTokens(_pairAddress);
        if (WBNB == token0 || WBNB == token1) {
            address token = WBNB == token0 ? token1 : token0;
            (uint256 amountToken, uint256 amountETH) =  ROUTERV2.removeLiquidityETH(token, _liquidity, 0, 0, _to, block.timestamp);
            (amount0, amount1) = WBNB == token0 ? (amountETH, amountToken) : (amountToken, amountETH);
        } else {
            (amount0, amount1) = ROUTERV2.removeLiquidity(token0, token1, _liquidity, 0, 0, _to, block.timestamp);
        }
    }

    function _swapBNBForToken(address _token, uint256 _value, address _to) internal returns (uint256) {
        address[] memory path;

        if (routePairAddresses[_token] != address(0)) {
            path = new address[](3);
            path[0] = WBNB;
            path[1] = routePairAddresses[_token];
            path[2] = _token;
        } else {
            path = new address[](2);
            path[0] = WBNB;
            path[1] = _token;
        }

        uint256[] memory amounts = ROUTERV2.swapExactETHForTokens{value : _value}(0, path, _to, block.timestamp);
        return amounts[amounts.length - 1];
    }

    function _swapTokenForBNB(address _token, uint256 _amount, address _to) private returns (uint256) {
        _approveTokenIfNeeded(_token, _amount);

        address[] memory path;
        if (routePairAddresses[_token] != address(0)) {
            path = new address[](3);
            path[0] = _token;
            path[1] = routePairAddresses[_token];
            path[2] = WBNB;
        } else {
            path = new address[](2);
            path[0] = _token;
            path[1] = WBNB;
        }

        uint256[] memory amounts = ROUTERV2.swapExactTokensForETH(_amount, 0, path, _to, block.timestamp);
        return amounts[amounts.length - 1];
    }

    function _swapTokenForToken(address _fromToken, uint256 _amount, address _toToken, address _to) internal returns (uint256) {
        _approveTokenIfNeeded(_fromToken, _amount);

        address intermediate = routePairAddresses[_fromToken];
        if (intermediate == address(0)) {
            intermediate = routePairAddresses[_toToken];
        }

        address[] memory path;
        if (intermediate != address(0) && (_fromToken == WBNB || _toToken == WBNB)) {
            // [WBNB, BUSD, VAI] or [VAI, BUSD, WBNB]
            path = new address[](3);
            path[0] = _fromToken;
            path[1] = intermediate;
            path[2] = _toToken;
        } else if (intermediate != address(0) && (_fromToken == intermediate || _toToken == intermediate)) {
            // [VAI, BUSD] or [BUSD, VAI]
            // [HIF, BUSD] or [BUSD, HIF]
            path = new address[](2);
            path[0] = _fromToken;
            path[1] = _toToken;
        } else if (intermediate != address(0) && routePairAddresses[_fromToken] == routePairAddresses[_toToken]) {
            // [VAI, DAI] or [VAI, USDC]
            path = new address[](3);
            path[0] = _fromToken;
            path[1] = intermediate;
            path[2] = _toToken;
        } else if (routePairAddresses[_fromToken] != address(0) && routePairAddresses[_toToken] != address(0) && routePairAddresses[_fromToken] != routePairAddresses[_toToken]) {
            // routePairAddresses[xToken] = xRoute
            // [VAI, BUSD, WBNB, xRoute, xToken]
            path = new address[](5);
            path[0] = _fromToken;
            path[1] = routePairAddresses[_fromToken];
            path[2] = WBNB;
            path[3] = routePairAddresses[_toToken];
            path[4] = _toToken;
        } else if (intermediate != address(0) && routePairAddresses[_fromToken] != address(0)) {
            // [VAI, BUSD, WBNB, HIF]
            path = new address[](4);
            path[0] = _fromToken;
            path[1] = intermediate;
            path[2] = WBNB;
            path[3] = _toToken;
        } else if (intermediate != address(0) && routePairAddresses[_toToken] != address(0)) {
            // [HIF, WBNB, BUSD, VAI]
            path = new address[](4);
            path[0] = _fromToken;
            path[1] = WBNB;
            path[2] = intermediate;
            path[3] = _toToken;
        } else if (_fromToken == WBNB || _toToken == WBNB) {
            // [WBNB, HIF] or [HIF, WBNB]
            path = new address[](2);
            path[0] = _fromToken;
            path[1] = _toToken;
        } else {
            // [USDT, HIF] or [HIF, USDT]
            path = new address[](3);
            path[0] = _fromToken;
            path[1] = WBNB;
            path[2] = _toToken;
        }

        uint256[] memory amounts = ROUTERV2.swapExactTokensForTokens(_amount, 0, path, _to, block.timestamp);
        return amounts[amounts.length - 1];
    }

    //modifier

}

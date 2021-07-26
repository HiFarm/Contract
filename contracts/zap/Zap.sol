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
    event SetRefRouters(address factory, address router);
    event SetRefFactory(address token, address ref);

    //structs

    //variables
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
    IPancakeFactory private constant FACTORYV2 = IPancakeFactory(0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73);
    IPancakeRouter02 private constant ROUTERV2 = IPancakeRouter02(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    mapping(address => address) public routePairAddresses;

    address public hifToken;

    //factory => router
    mapping(address => address) public refsRouter;
    //token => factory
    mapping(address => address) public refsFactory;

    //initializer
    function initialize(address _hifToken) public initializer {
        __OwnerPausable_init();
        __ReentrancyGuard_init();
        hifToken = _hifToken;
        routePairAddresses[hifToken] = BUSD;

        refsRouter[address(FACTORYV2)] = address(ROUTERV2);
    }

    receive() external payable {}

    //view functions

    //restricted functions
    function setRoutePairAddress(address _token, address _route) external onlyOwner {
        routePairAddresses[_token] = _route;
    }

    function setRouter(address[] calldata factories, address[] calldata routers) external onlyOwner {
        require(factories.length == routers.length, 'factories & routers length mismatched');
        for (uint256 idx = 0; idx < factories.length; idx++) {
            refsRouter[factories[idx]] = routers[idx];
            emit SetRefRouters(factories[idx], routers[idx]);
        }
    }

    function setRefsFactory(address[] calldata tokens, address[] calldata refs) external onlyOwner {
        require(tokens.length == refs.length, 'tokens & refs length mismatched');
        for (uint256 idx = 0; idx < tokens.length; idx++) {
            refsFactory[tokens[idx]] = refs[idx];
            emit SetRefFactory(tokens[idx], refs[idx]);
        }
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
        } else if (_isPair(_fromToken)) {
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
        address router = address(_getRouterByToken(_token));
        if (IERC20Upgradeable(_token).allowance(address(this), address(router)) < _amount) {
            IERC20Upgradeable(_token).safeIncreaseAllowance(address(router), _amount);
        }
    }

    function _compareStrings(string memory a, string memory b) internal pure returns (bool) {
        return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b))));
    }

    function _isPair(address _token) internal view returns (bool) {
        string memory symbol = ERC20Upgradeable(_token).symbol();
        if (_compareStrings(symbol, "Cake-LP")) {
            return true;
        } else if (_compareStrings(symbol, "APE-LP")) {
            return true;
        }
        return false;
    }

    function _getRouterByToken(address _token) internal view returns (IPancakeRouter02) {
        IPancakeFactory factory = _getFactoryByToken(_token);
        //pancake factory or no route
        require(factory == FACTORYV2 || routePairAddresses[_token] == address(0), 'not support router');
        return _getRouter(address(factory));
    }

    function _getFactoryByToken(address _token) internal view returns (IPancakeFactory) {
        if (_isPair(_token)) {
            return IPancakeFactory(IPancakePair(_token).factory());
        }
        address factory = refsFactory[_token];
        return factory == address(0) ? FACTORYV2 : IPancakeFactory(factory);
    }

    function _getRouter(address _factory) internal view returns (IPancakeRouter02) {
        if (_factory == address(0)) {
            return ROUTERV2;
        }
        require(refsRouter[_factory] != address(0), 'invalid factory or router');
        return IPancakeRouter02(refsRouter[_factory]);
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
        _swapTokenToLP(_fromToken, _amount, _pairAddress, _to);
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
        address factory = IPancakePair(_pairAddress).factory();
        (address token0, address token1) = _getPairTokens(_pairAddress);
        address _fromToken = WBNB;
        uint256 amountToSwap = _value.div(2);
        if (_fromToken == token0 || _fromToken == token1) {
            address otherToken = _fromToken == token0 ? token1 : token0;
            uint256 otherAmount = _swapBNBForToken(otherToken, amountToSwap, address(this));
            _addLiquidityBNB(factory, _value.sub(amountToSwap), otherToken, otherAmount, _to);
        } else {
            uint256 token0Amount = _swapBNBForToken(token0, amountToSwap, address(this));
            uint256 token1Amount = _swapBNBForToken(token1, _value.sub(amountToSwap), address(this));
            _addLiquidity(factory, token0, token1, token0Amount, token1Amount, _to);
        }
    }

    function _swapTokenToLP(address _fromToken, uint256 _value, address _pairAddress, address _to) internal {
        address factory = IPancakePair(_pairAddress).factory();
        (address token0, address token1) = _getPairTokens(_pairAddress);
        uint256 amountToSwap = _value.div(2);
        if (_fromToken == token0 || _fromToken == token1) {
            address otherToken = _fromToken == token0 ? token1 : token0;
            uint256 otherAmount = _swapTokenForToken(_fromToken, amountToSwap, otherToken, address(this));
            uint256 token0Amount = _fromToken == token0 ? _value.sub(amountToSwap) : otherAmount; 
            uint256 token1Amount = _fromToken == token1 ? _value.sub(amountToSwap) : otherAmount;
            _addLiquidity(factory, token0, token1, token0Amount, token1Amount, _to);
        } else {
            uint256 token0Amount = _swapTokenForToken(_fromToken, amountToSwap, token0, address(this));
            uint256 token1Amount = _swapTokenForToken(_fromToken, _value.sub(amountToSwap), token1, address(this));
            _addLiquidity(factory, token0, token1, token0Amount, token1Amount, _to);
        }
    }

    function _addLiquidity(address _factory, address _token0, address _token1, uint256 _amount0Desired, uint256 _amount1Desired, address _to) internal returns (uint256, uint256, uint256) {
        _approveTokenIfNeeded(_token0, _amount0Desired);
        _approveTokenIfNeeded(_token1, _amount1Desired);
        return _getRouter(_factory).addLiquidity(_token0, _token1, _amount0Desired, _amount1Desired, 0, 0, _to, block.timestamp);
    }

    function _addLiquidityBNB(address _factory, uint256 _value, address _token1, uint256 _amount1Desired, address _to) internal returns (uint256, uint256, uint256) {
        _approveTokenIfNeeded(_token1, _amount1Desired);
        return _getRouter(_factory).addLiquidityETH{value: _value}(_token1, _amount1Desired, 0, 0, _to, block.timestamp);
    }

    function _removeLiquidity(address _pairAddress, uint256 _liquidity, address _to) internal returns (uint256 amount0, uint256 amount1) {
        address factory = IPancakePair(_pairAddress).factory();
        IPancakeRouter02 router = _getRouter(factory);
        _approveTokenIfNeeded(_pairAddress, _liquidity);
        (address token0, address token1) = _getPairTokens(_pairAddress);
        if (WBNB == token0 || WBNB == token1) {
            address token = WBNB == token0 ? token1 : token0;
            (uint256 amountToken, uint256 amountETH) =  router.removeLiquidityETH(token, _liquidity, 0, 0, _to, block.timestamp);
            (amount0, amount1) = WBNB == token0 ? (amountETH, amountToken) : (amountToken, amountETH);
        } else {
            (amount0, amount1) = router.removeLiquidity(token0, token1, _liquidity, 0, 0, _to, block.timestamp);
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

        uint256[] memory amounts = _getRouterByToken(_token).swapExactETHForTokens{value : _value}(0, path, _to, block.timestamp);
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

        uint256[] memory amounts = _getRouterByToken(_token).swapExactTokensForETH(_amount, 0, path, _to, block.timestamp);
        return amounts[amounts.length - 1];
    }

    function _swapTokenForToken(address _fromToken, uint256 _amount, address _toToken, address _to) internal returns (uint256) {
        IPancakeRouter02 fromRouter = _getRouterByToken(_fromToken);
        IPancakeRouter02 toRouter = _getRouterByToken(_toToken);
        if (fromRouter != toRouter) {
            uint256 bnbAmount = _swapTokenForBNB(_fromToken, _amount, address(this));
            return _swapBNBForToken(_toToken, bnbAmount, _to);
        }

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
            // [VAI, BUSD, HIF]
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
            // [VAI, BUSD, WBNB, ETH]
            path = new address[](4);
            path[0] = _fromToken;
            path[1] = intermediate;
            path[2] = WBNB;
            path[3] = _toToken;
        } else if (intermediate != address(0) && routePairAddresses[_toToken] != address(0)) {
            // [ETH, WBNB, BUSD, VAI]
            path = new address[](4);
            path[0] = _fromToken;
            path[1] = WBNB;
            path[2] = intermediate;
            path[3] = _toToken;
        } else if (_fromToken == WBNB || _toToken == WBNB) {
            // [WBNB, ETH] or [ETH, WBNB]
            path = new address[](2);
            path[0] = _fromToken;
            path[1] = _toToken;
        } else {
            path = new address[](3);
            path[0] = _fromToken;
            path[1] = WBNB;
            path[2] = _toToken;
        }

        uint256[] memory amounts = fromRouter.swapExactTokensForTokens(_amount, 0, path, _to, block.timestamp);
        return amounts[amounts.length - 1];
    }

    //modifier

}

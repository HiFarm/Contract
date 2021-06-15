// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.6.0 <0.7.0;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";

import "../external/chainlink/AggregatorV3Interface.sol";
import "../external/pancake/IPancakeFactory.sol";
import "../external/pancake/IPancakePair.sol";
import "../libraries/OwnerPausableUpgradeable.sol";
import "../libraries/HomoraMath.sol";
import "./PriceInterface.sol";

contract PriceProvider is PriceInterface, OwnerPausableUpgradeable {
    using SafeMathUpgradeable for uint256;
    using HomoraMath for uint256;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    //events
    event SetRefBNB(address token, address ref);
    event SetRefUSD(address token, address ref);
    event SetRefBNBUSD(address ref);

    //structs

    //variables
    IPancakeFactory private constant FACTORYV2 = IPancakeFactory(0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73);

    uint256 private constant SCALE = 1e18;
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
    address public refBNBUSD; // BNB-USD price reference
    mapping(address => address) public refsBNB; // Mapping from token address to BNB price reference
    mapping(address => address) public refsUSD; // Mapping from token address to USD price reference
    mapping(address => address) public routePairAddresses;
    address public hifToken;

    //initializer
    function initialize(address _hifToken) public initializer {
        __OwnerPausable_init();
        refBNBUSD = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;
        hifToken = _hifToken;
        routePairAddresses[hifToken] = BUSD;
    }

    //view functions
    function getBNBPrice() public view override returns (uint256) {
        (, int256 answer, , , ) = AggregatorV3Interface(refBNBUSD).latestRoundData();
        return uint256(answer).mul(1e10);
    }

    function getTokenPrice(address token) public view override returns (uint256) {
        if (token == WBNB || token == address(0)) return getBNBPrice();

        address refUSD = refsUSD[token];
        require(refUSD != address(0), 'no valid price reference for token');
        (, int256 answer, , , ) = AggregatorV3Interface(refUSD).latestRoundData();
        return uint256(answer).mul(1e10);
    }

    function getBNBPerToken(address token) public view override returns (uint256) {
        if (token == WBNB || token == address(0)) return uint256(SCALE);

        if (_compareStrings(ERC20Upgradeable(token).symbol(), "Cake-LP")) {
            return _getBNBPerLP(token);
        }

        uint256 decimals = uint256(ERC20Upgradeable(token).decimals());
        // 1. Check token-BNB price ref
        address refBNB = refsBNB[token];
        if (refBNB != address(0)) {
            (, int256 answer, , , ) = AggregatorV3Interface(refBNB).latestRoundData();
            return uint256(answer).mul(SCALE).div(10**decimals);
        }

        // 2. Check token-USD price ref
        address refUSD = refsUSD[token];
        if (refUSD != address(0)) {
            (, int256 answer, , , ) = AggregatorV3Interface(refUSD).latestRoundData();
            (, int256 bnbAnswer, , , ) = AggregatorV3Interface(refBNBUSD).latestRoundData();
            return uint256(answer).mul(1e36).div(uint256(bnbAnswer)).div(10**decimals);
        }

        if (token == hifToken) {
            return _getBNBPerTokenInDefi(token);
        }

        revert('no valid price reference for token');
    }

    function valueOfToken(address token, uint256 amount) public view override returns (uint256 valueInBNB, uint256 valueInUSD) {
        uint256 px = getBNBPerToken(token); // in bnb:e18
        valueInBNB = amount.mul(px).div(SCALE);
        uint256 bnbPrice = getBNBPrice(); // in usd:e18
        valueInUSD = valueInBNB.mul(bnbPrice).div(SCALE);
    }

    //restricted functions
    function setHIFToken(address _hifToken) external onlyOwner {
        hifToken = _hifToken;
    }

    function setRefsBNB(address[] calldata tokens, address[] calldata refs) external onlyOwner {
        require(tokens.length == refs.length, 'tokens & refs length mismatched');
        for (uint256 idx = 0; idx < tokens.length; idx++) {
            refsBNB[tokens[idx]] = refs[idx];
            emit SetRefBNB(tokens[idx], refs[idx]);
        }
    }

    function setRefsUSD(address[] calldata tokens, address[] calldata refs) external onlyOwner {
        require(tokens.length == refs.length, 'tokens & refs length mismatched');
        for (uint256 idx = 0; idx < tokens.length; idx++) {
            refsUSD[tokens[idx]] = refs[idx];
            emit SetRefUSD(tokens[idx], refs[idx]);
        }
    }

    function setRefBNBUSD(address _refBNBUSD) external onlyOwner {
        refBNBUSD = _refBNBUSD;
        emit SetRefBNBUSD(_refBNBUSD);
    }

    function setRoutePairAddress(address _token, address _route) external onlyOwner {
        routePairAddresses[_token] = _route;
    }

    //public functions

    //private functions
    function _compareStrings(string memory a, string memory b) internal pure returns (bool) {
        return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b))));
    }

    function _getBNBPerLP(address pair) internal view returns (uint256) {
        address token0 = IPancakePair(pair).token0();
        address token1 = IPancakePair(pair).token1();
        uint256 totalSupply = IPancakePair(pair).totalSupply();
        (uint256 reserve0, uint256 reserve1, ) = IPancakePair(pair).getReserves();
        uint256 sqrtK = HomoraMath.sqrt(reserve0.mul(reserve1)).fdiv(totalSupply); // in 2**112
        uint256 px0 = getBNBPerToken(token0); // in e18
        uint256 px1 = getBNBPerToken(token1); // in e18
        // fair token0 amt: sqrtK * sqrt(px1/px0)
        // fair token1 amt: sqrtK * sqrt(px0/px1)
        // fair lp price = 2 * sqrt(px0 * px1)
        // split into 2 sqrts multiplication to prevent uint256 overflow (note the 2**112)
        return sqrtK.mul(2).mul(HomoraMath.sqrt(px0)).div(2**56).mul(HomoraMath.sqrt(px1)).div(2**56);
    }

    function _getBNBPerTokenInDefi(address token) internal view returns (uint256) {
        if (token == WBNB || token == address(0)) return uint256(SCALE);

        address routeToken = routePairAddresses[token] == address(0) ? WBNB : routePairAddresses[token];
        address pair = FACTORYV2.getPair(token, routeToken);
        require(pair != address(0), "pair not found");

        address token0 = IPancakePair(pair).token0();
        (uint256 reserve0, uint256 reserve1, ) = IPancakePair(pair).getReserves();
        //in e18
        uint256 valueInRoute;
        if (token0 == routeToken) {
            valueInRoute = reserve0.mul(SCALE).div(reserve1);
        } else {
            valueInRoute = reserve1.mul(SCALE).div(reserve0);
        }

        uint256 valueInBNB;
        if (routeToken == WBNB) {
            valueInBNB = valueInRoute;
        } else {
            uint256 routeValueInBNB = getBNBPerToken(routeToken);
            valueInBNB = valueInRoute.mul(routeValueInBNB).div(SCALE);
        }
        return valueInBNB;
    }

    /*
    function _getBNBPerLPInDefi(address pair) internal view returns (uint256) {
        address token0 = IPancakePair(pair).token0();
        address token1 = IPancakePair(pair).token1();
        uint256 totalSupply = IPancakePair(pair).totalSupply();
        (uint256 reserve0, uint256 reserve1, ) = IPancakePair(pair).getReserves();
        uint256 valueInBNB;
        if (token0 == WBNB) {
            valueInBNB = reserve0.mul(SCALE).mul(2).div(totalSupply);
        } else if (token1 == WBNB) {
            valueInBNB = reserve1.mul(SCALE).mul(2).div(totalSupply);
        } else {
            uint256 token0PriceInBNB = getBNBPerToken(token0); //in e18
            valueInBNB = reserve0.mul(token0PriceInBNB).mul(2).div(totalSupply);
        }
        return valueInBNB;
    }
    */

    //modifier

}



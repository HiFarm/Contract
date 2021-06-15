// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.6.0 <0.8.0;

import "@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";

library Helper {
    using SafeMathUpgradeable for uint256;

    function compoundingAPY(uint256 apr, uint256 compoundUnit) internal pure returns(uint256) {
        uint256 compoundTimes = 365 days / compoundUnit;
        uint256 unitAPY = apr.div(compoundTimes).add(1e18);
        uint256 result = 1e18;

        for(uint256 i=0; i<compoundTimes; i++) {
            result = result.mul(unitAPY).div(1e18);
        }

        return result.sub(1e18);
    }
}

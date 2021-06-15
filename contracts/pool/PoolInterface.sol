// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.6.0 <0.7.0;

interface PoolInterface {
    function isHIFPool() external view returns (bool);

    /// @dev Returns the address of the underlying ERC20 asset
    /// @return The address of the asset
    function stakedToken() external view returns (address);

    function rewardToken() external view returns (address);

    /// @dev Returns the total underlying balance of all assets. This includes both principal and interest.
    /// @return The underlying balance of assets
    function balance() external view returns (uint256);

    function balanceOf(address user) external view returns (uint256);

    function totalShare() external view returns (uint256);

    function shareOf(address user) external view returns (uint256);

    function earned(address user) external view returns (uint256);

    function depositTo(address user) external payable;

    function depositTokenTo(address user, uint256 amount) external;

    function withdraw(uint256 amount) external;

    function withdrawShare(uint256 share) external;

    function withdrawAll() external;

    function claimReward() external;

    function receiveReward() external payable;

    function receiveRewardToken(uint256 amount) external;

}


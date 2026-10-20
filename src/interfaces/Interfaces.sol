// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IToken {
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice The existing HamsterHour v2 ABI. Successors must preserve these semantics:
/// fixed hourly windows; immutable, sequentially finalized loss history; sum(lossOf) <= total.
interface IHamsterGame {
    function IMD() external view returns (address);
    function windowStart(uint256 k) external view returns (uint64);
    function windowEnd(uint256 k) external view returns (uint64);
    function nextFinalizeWindow() external view returns (uint256);
    function lossOf(uint256 k, address account) external view returns (uint256);
    function totalEligibleLoss(uint256 k) external view returns (uint256);
    function cumulativeLossBefore(uint256 k) external view returns (uint256);
    function cumulativeLossAfter(uint256 k) external view returns (uint256);
    function balances(address account) external view returns (uint256);
    function withdraw() external;
    function finalize(uint256 maxWindows) external;
    function depositJackpot(uint256 amount) external;
    function fundOracleReserve(uint256 amount) external;
}

interface INFT {
    function ownerOf(uint256 tokenId) external view returns (address);
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

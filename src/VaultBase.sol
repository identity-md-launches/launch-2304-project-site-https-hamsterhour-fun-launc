// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IToken} from "./interfaces/Interfaces.sol";
import {HamsterBoost} from "./HamsterBoost.sol";

abstract contract VaultBase {
    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address public constant GAME_V2 = 0xe33AB493249a2Df0D8c4a71aC54F46d1F7778367;
    uint256 public constant MINING_ALLOCATION = 750_000_000 ether;
    uint256 public constant BOOST_ALLOCATION = 50_000_000 ether;
    uint256 public constant MAX_BATCH = 32;
    address public immutable TEAM;
    HamsterBoost public immutable boostEngine;
    uint256 public immutable deployedAt;
    address public token;
    uint256 private _entered;

    error NotTeam();
    error InvalidAddress();
    error InvalidAmount();
    error AlreadyDone();
    error NotReady();
    error InvalidInterface();
    error TransferFailed();
    error Reentrancy();
    error TooMany();
    error NotBound();

    event TokenBound(address indexed token);

    constructor(address team_, address boostEngine_) {
        if (team_ == address(0) || boostEngine_ == address(0)) revert InvalidAddress();
        TEAM = team_;
        boostEngine = HamsterBoost(boostEngine_);
        deployedAt = block.timestamp;
    }

    modifier onlyTeam() {
        if (msg.sender != TEAM) revert NotTeam();
        _;
    }

    modifier guarded() {
        if (_entered != 0) revert Reentrancy();
        _entered = 1;
        _;
        _entered = 0;
    }

    function bindToken(address token_) external onlyTeam guarded {
        if (token != address(0)) revert AlreadyDone();
        if (token_ == IMD || token_.code.length == 0) revert InvalidAddress();
        if (
            IToken(token_).totalSupply() != 1_000_000_000 ether
                || IToken(token_).balanceOf(address(this)) < 800_000_000 ether || IToken(token_).decimals() != 18
        ) revert InvalidAmount();
        token = token_;
        emit TokenBound(token_);
    }

    function _bound() internal view {
        if (token == address(0)) revert NotBound();
    }

    function _callToken(address asset, bytes memory data) internal {
        (bool ok, bytes memory result) = asset.call(data);
        if (!ok || asset.code.length == 0 || (result.length != 0 && !abi.decode(result, (bool)))) {
            revert TransferFailed();
        }
    }

    function _pull(address asset, address from, uint256 amount) internal {
        if (amount == 0 || amount > type(uint128).max) revert InvalidAmount();
        uint256 before_ = IToken(asset).balanceOf(address(this));
        _callToken(asset, abi.encodeCall(IToken.transferFrom, (from, address(this), amount)));
        if (IToken(asset).balanceOf(address(this)) != before_ + amount) revert TransferFailed();
    }

    function _push(address asset, address to, uint256 amount) internal {
        if (amount == 0) return;
        uint256 before_ = IToken(asset).balanceOf(address(this));
        uint256 recipientBefore = IToken(asset).balanceOf(to);
        _callToken(asset, abi.encodeCall(IToken.transfer, (to, amount)));
        if (
            IToken(asset).balanceOf(address(this)) + amount != before_
                || IToken(asset).balanceOf(to) != recipientBefore + amount
        ) revert TransferFailed();
    }

    function _approve(address spender, uint256 amount) internal {
        _callToken(IMD, abi.encodeCall(IToken.approve, (spender, 0)));
        if (amount != 0) _callToken(IMD, abi.encodeCall(IToken.approve, (spender, amount)));
    }

    function _grant(address account, uint256 amount) internal virtual;
}

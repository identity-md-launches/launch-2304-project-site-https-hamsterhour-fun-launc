// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultBase} from "./VaultBase.sol";
import {HamsterMining} from "./HamsterMining.sol";
import {HamsterStaking} from "./HamsterStaking.sol";
import {HamsterBoost} from "./HamsterBoost.sol";
import {IToken, IHamsterGame} from "./interfaces/Interfaces.sol";

/// @title HamsterVault
/// @notice Immutable mainnet HAMSTER mining, vesting, staking and IMD forwarding. No owner,
/// upgrade, pause, rescue, arbitrary-call or administrative withdrawal mechanism.
contract HamsterVault is HamsterMining, HamsterStaking {
    uint256 public jackpotPending;
    uint256 public oraclePending;

    event GameRewardsPulled(address indexed game, uint256 amount);
    event Forwarded(address indexed from, bool indexed oracle, uint256 amount);
    event Flushed(address indexed game, bool indexed oracle, uint256 amount);

    constructor(address team_, address boostEngine_) VaultBase(team_, boostEngine_) {}

    function _grant(address account, uint256 amount) internal override(VaultBase, HamsterStaking) {
        HamsterStaking._grant(account, amount);
    }

    /// @notice TEAM attests that the supplied ERC-721 is the canonical Squeek on mainnet.
    function activateBoost(address collection_) external onlyTeam guarded {
        boostEngine.schedule(collection_);
    }

    function executeBoost() external guarded {
        boostEngine.execute();
    }

    function registerNFT(uint256 tokenId) external guarded returns (uint256) {
        return boostEngine.register(msg.sender, tokenId);
    }

    function invalidateRegistration(uint256 registration) external guarded {
        boostEngine.invalidate(registration);
    }

    function prepareBoostDay(uint256 maxRegistrations) external guarded {
        boostEngine.prepare(maxRegistrations);
    }

    function claimBoost(uint256 day, uint256 registration) external guarded returns (uint256 amount) {
        _bound();
        address beneficiary;
        (beneficiary, amount) = boostEngine.claim(day, registration);
        _grant(beneficiary, amount);
    }

    function sweepDormantBoost() external guarded {
        boostEngine.sweep();
        miningAllocation += BOOST_ALLOCATION;
    }

    function bucketsLeft()
        external
        view
        returns (uint256 miningUncommitted, uint256 miningReserved, uint256 boostUncommitted, uint256 boostReserved)
    {
        HamsterBoost.State memory s = boostEngine.status(address(this));
        miningUncommitted = miningAllocation - miningCommitted;
        miningReserved = miningCommitted - miningGranted;
        boostUncommitted = s.swept ? 0 : BOOST_ALLOCATION - s.committed;
        boostReserved = s.committed - s.granted;
    }

    /// @notice Pull any registered game's credited 5% staker balance. Old games remain available.
    /// Every pull streams over 30 active days, including all pre-recipient backlog.
    function pullGameRewards(address game) external guarded returns (uint256 amount) {
        if (!games[game].registered) revert UnknownGame();
        _readyGlobal();
        amount = IHamsterGame(game).balances(address(this));
        if (amount == 0 || amount > type(uint128).max) revert InvalidAmount();
        uint256 before_ = IToken(IMD).balanceOf(address(this));
        IHamsterGame(game).withdraw();
        if (IToken(IMD).balanceOf(address(this)) != before_ + amount) revert TransferFailed();
        _stream(amount, true);
        emit GameRewardsPulled(game, amount);
    }

    function forwardJackpot(uint256 amount) external guarded {
        _pull(IMD, msg.sender, amount);
        jackpotPending += amount;
        emit Forwarded(msg.sender, false, amount);
    }

    function forwardOracle(uint256 amount) external guarded {
        _pull(IMD, msg.sender, amount);
        oraclePending += amount;
        emit Forwarded(msg.sender, true, amount);
    }

    function flushJackpot(uint256 amount) external guarded {
        if (amount == 0 || amount > jackpotPending) revert InvalidAmount();
        jackpotPending -= amount;
        _flush(amount, false);
    }

    function flushOracle(uint256 amount) external guarded {
        if (amount == 0 || amount > oraclePending) revert InvalidAmount();
        oraclePending -= amount;
        _flush(amount, true);
    }

    function _flush(uint256 amount, bool oracle) private {
        address game = currentGame;
        uint256 before_ = IToken(IMD).balanceOf(address(this));
        _approve(game, amount);
        if (oracle) IHamsterGame(game).fundOracleReserve(amount);
        else IHamsterGame(game).depositJackpot(amount);
        _approve(game, 0);
        if (IToken(IMD).balanceOf(address(this)) + amount != before_) revert TransferFailed();
        emit Flushed(game, oracle, amount);
    }

    /// @notice Custody accounting. Unsolicited token donations are excess and have no rescue path.
    function hamsterLiability() external view returns (uint256) {
        return 800_000_000 ether - miningGranted - boostEngine.status(address(this)).granted + totalGrantBalance
            + totalStaked + totalUnstakeQueued;
    }

    function imdLiability() external view returns (uint256) {
        return rewardLiability() + jackpotPending + oraclePending;
    }
}

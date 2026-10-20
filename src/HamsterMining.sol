// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultBase} from "./VaultBase.sol";
import {IHamsterGame} from "./interfaces/Interfaces.sol";
import {VaultMath as M} from "./libraries/VaultMath.sol";

abstract contract HamsterMining is VaultBase {
    uint256 public constant HALF_LOSS = 18_750 ether;
    uint256 public constant SWITCH_DELAY = 48 hours;
    uint256 public constant NEW_GAME_PERIOD = 14 days;
    uint256 public constant NEW_GAME_DAILY_CAP = 2_000_000 ether;
    uint256 public constant BOOST_DAILY_CAP = 100_000 ether;
    uint256 public constant NFT_DAILY_CAP = 10_000 ether;
    uint256 public constant BOOST_DELAY = 12 hours;
    uint256 public constant BOOST_DEADLINE = 365 days;
    uint256 public constant V2_GENESIS = 1791847200;

    struct Game {
        bool registered;
        bool rangeReady;
        uint64 genesis;
        uint64 switchedAt;
        uint256 first;
        uint256 end; // Exclusive; type(uint256).max while current.
        uint256 localOrigin;
        uint256 globalOrigin;
        address previous;
    }

    struct WindowAccounting {
        bool prepared;
        uint256 budget;
        uint256 paid;
        uint256 claimedLoss;
        uint256 dust; // Whole token wei provably lost to individual share rounding.
        uint256 fractionalDust; // Numerator, denominator = totalEligibleLoss.
    }

    mapping(address => Game) public games;
    address[] public gameList;
    address public currentGame;
    address public pendingGame;
    uint256 public pendingGameReadyAt;
    mapping(address => mapping(uint256 => WindowAccounting)) public windowAccounting;
    mapping(address => mapping(uint256 => mapping(address => bool))) public mined;
    uint256 public miningCommitted;
    uint256 public miningGranted;
    uint256 public knownMiningDust;
    uint256 public miningAllocation = MINING_ALLOCATION;
    error UnknownGame();
    error ExcludedWindow();
    error BadLossHistory();
    error NotFinalized();

    event GameScheduled(address indexed game, uint256 readyAt);
    event GameSwitched(address indexed previous, address indexed current, uint256 switchedAt, uint256 oldEnd);
    event RangeResolved(address indexed game, uint256 localOrigin, uint256 globalOrigin);
    event WindowPrepared(address indexed game, uint256 indexed k, uint256 budget);
    event Mined(address indexed game, uint256 indexed k, address indexed beneficiary, uint256 amount);

    constructor() {
        currentGame = GAME_V2;
        games[GAME_V2] = Game(true, true, uint64(V2_GENESIS), 0, 0, type(uint256).max, 0, 0, address(0));
        gameList.push(GAME_V2);
    }

    function emissionCurve(uint256 loss) public view returns (uint256) {
        return boostEngine.emissionCurve(loss);
    }

    function currentMiningState() external view returns (uint256 globalLoss, uint256 rate, uint256 halving) {
        return boostEngine.currentMiningState(address(this));
    }

    function rateAndHalving(uint256 globalLoss) external pure returns (uint256 rate, uint256 halving) {
        halving = globalLoss / HALF_LOSS;
        rate = halving >= 256 ? 0 : (20_000 ether >> halving);
    }

    function gameCount() external view returns (uint256) {
        return gameList.length;
    }

    function _firstAt(Game memory g, uint256 timestamp) internal pure returns (uint256) {
        return timestamp <= g.genesis ? 0 : (timestamp - g.genesis + 1 hours - 1) / 1 hours;
    }

    function scheduleGame(address candidate) external onlyTeam guarded {
        if (games[candidate].registered) revert AlreadyDone();
        boostEngine.checkGame(candidate);
        pendingGame = candidate;
        pendingGameReadyAt = block.timestamp + SWITCH_DELAY;
        emit GameScheduled(candidate, pendingGameReadyAt);
    }

    /// @notice Permissionless execution of TEAM's public, matured commitment.
    function executeGame() external guarded {
        address candidate = pendingGame;
        if (candidate == address(0) || block.timestamp < pendingGameReadyAt) revert NotReady();
        uint64 genesis = boostEngine.checkGame(candidate);
        address old = currentGame;
        if (!games[old].rangeReady) _resolveGame(old);
        Game storage previous = games[old];
        previous.end = M.min(previous.end, _firstAt(previous, block.timestamp));
        Game memory fresh = Game(true, false, genesis, uint64(block.timestamp), 0, type(uint256).max, 0, 0, old);
        fresh.first = _firstAt(fresh, block.timestamp);
        games[candidate] = fresh;
        gameList.push(candidate);
        currentGame = candidate;
        delete pendingGame;
        delete pendingGameReadyAt;
        emit GameSwitched(old, candidate, block.timestamp, previous.end);
    }

    function resolveGame(address game) external guarded {
        _resolveGame(game);
    }

    function _resolveGame(address game) internal {
        Game storage g = games[game];
        if (!g.registered) revert UnknownGame();
        if (g.rangeReady) return;
        Game memory prev = games[g.previous];
        if (!prev.rangeReady || IHamsterGame(g.previous).nextFinalizeWindow() < prev.end) revert NotFinalized();
        uint256 oldEnd =
            prev.end == prev.first ? prev.localOrigin : IHamsterGame(g.previous).cumulativeLossAfter(prev.end - 1);
        if (oldEnd < prev.localOrigin) revert BadLossHistory();
        // Exclude ALL of the successor's pre-switch backlog, even if it was not finalized at switch.
        if (IHamsterGame(game).nextFinalizeWindow() < g.first) revert NotFinalized();
        g.localOrigin = g.first == 0 ? 0 : IHamsterGame(game).cumulativeLossAfter(g.first - 1);
        g.globalOrigin = prev.globalOrigin + (oldEnd - prev.localOrigin);
        g.rangeReady = true;
        emit RangeResolved(game, g.localOrigin, g.globalOrigin);
    }

    function windowBudget(address game, uint256 k) public view returns (uint256 budget, uint256 total) {
        return boostEngine.windowBudget(address(this), game, k);
    }

    function claimable(address game, uint256 k, address account) public view returns (uint256) {
        if (mined[game][k][account]) return 0;
        (uint256 budget, uint256 total) = windowBudget(game, k);
        uint256 loss = IHamsterGame(game).lossOf(k, account);
        if (loss > total) revert BadLossHistory();
        return total == 0 ? 0 : M.mulDiv(budget, loss, total);
    }

    function _prepareWindow(address game, uint256 k) internal returns (uint256 budget, uint256 total) {
        (budget, total) = windowBudget(game, k);
        WindowAccounting storage w = windowAccounting[game][k];
        if (!w.prepared) {
            w.prepared = true;
            w.budget = budget;
            miningCommitted += budget;
            // The original curve remains unchanged after the reserve reclassification.
            if (miningCommitted > MINING_ALLOCATION) revert BadLossHistory();
            emit WindowPrepared(game, k, budget);
        }
    }

    function claimMined(address game, uint256[] calldata windows, address beneficiary)
        external
        guarded
        returns (uint256 amount)
    {
        _bound();
        if (beneficiary == address(0) || beneficiary == address(this)) revert InvalidAddress();
        if (windows.length == 0 || windows.length > MAX_BATCH) revert TooMany();
        for (uint256 i; i < windows.length; ++i) {
            uint256 k = windows[i];
            if (mined[game][k][beneficiary]) revert AlreadyDone();
            (uint256 budget, uint256 total) = _prepareWindow(game, k);
            uint256 loss = IHamsterGame(game).lossOf(k, beneficiary);
            WindowAccounting storage w = windowAccounting[game][k];
            if (loss > total || w.claimedLoss + loss > total) revert BadLossHistory();
            uint256 share = total == 0 ? 0 : M.mulDiv(budget, loss, total);
            mined[game][k][beneficiary] = true;
            w.claimedLoss += loss;
            w.paid += share;
            if (total != 0) {
                uint256 remainder = mulmod(budget, loss, total);
                // Addition without overflow, including for an unusually large game loss denominator.
                if (remainder >= total - w.fractionalDust) {
                    w.fractionalDust = remainder - (total - w.fractionalDust);
                    ++w.dust;
                    ++knownMiningDust;
                } else {
                    w.fractionalDust += remainder;
                }
            }
            amount += share;
            emit Mined(game, k, beneficiary, share);
        }
        miningGranted += amount;
        if (amount != 0) _grant(beneficiary, amount);
    }

    function gameAtTime(uint256 timestamp) public view returns (uint256 index) {
        uint256 end = gameList.length;
        while (index + 1 < end) {
            uint256 mid = (index + end) / 2;
            if (games[gameList[mid]].switchedAt <= timestamp) index = mid;
            else end = mid;
        }
    }
}

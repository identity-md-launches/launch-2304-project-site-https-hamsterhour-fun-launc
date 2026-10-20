// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VaultTestBase, HamsterVault, MockGame} from "./helpers/VaultTestBase.sol";

/// @notice Random sequences of losses, time, game switches, range resolution and claims on any
/// registered game. Checks the new-game daily cap, the bucket and claim/claimable agreement.
contract SwitchHandler is Test {
    address internal constant TEAM = address(bytes20(hex"6cba4751742f6989fa224b2dc5d5d52fcef98a34"));
    uint64 internal constant GENESIS = 1791847200;

    HamsterVault public vault;
    MockGame[] public games;
    address[3] public actors;
    uint256 public ghostMined;
    bool public claimMismatch;
    bool public capExceeded;
    uint256 public successfulClaims;

    constructor(HamsterVault vault_, MockGame v2, address[3] memory actors_) {
        vault = vault_;
        games.push(v2);
        actors = actors_;
    }

    function gameCount() external view returns (uint256) {
        return games.length;
    }

    function _finalizeAll() internal {
        for (uint256 i; i < games.length; ++i) {
            games[i].finalize(2_000);
        }
    }

    function addLoss(uint256 actorSeed, uint256 amount, uint256 offset) external {
        MockGame g = games[games.length - 1];
        uint256 k = (block.timestamp - GENESIS) / 1 hours + bound(offset, 0, 30);
        if (k < g.nextFinalizeWindow()) return;
        g.setLoss(k, actors[actorSeed % 3], bound(amount, 0, 400 ether));
    }

    function advance(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1 hours, 2 days));
        _finalizeAll();
    }

    function switchGame() external {
        if (games.length >= 3 || vault.pendingGame() != address(0)) return;
        MockGame next = new MockGame(GENESIS);
        vm.prank(TEAM);
        vault.scheduleGame(address(next));
        vm.warp(block.timestamp + 48 hours);
        _finalizeAll();
        vault.executeGame();
        games.push(next);
    }

    function resolve(uint256 seed) external {
        _finalizeAll();
        vault.resolveGame(address(games[seed % games.length]));
    }

    function claim(uint256 gameSeed, uint256 kSeed, uint256 actorSeed) external {
        MockGame g = games[gameSeed % games.length];
        (, bool rangeReady,, uint64 switchedAt, uint256 first, uint256 end,,,) = vault.games(address(g));
        if (!rangeReady) return;
        uint256 n = g.nextFinalizeWindow();
        if (end < n) n = end;
        if (n <= first) return;
        uint256 k = bound(kSeed, first, n - 1);
        address who = actors[actorSeed % 3];
        if (vault.mined(address(g), k, who)) return;
        uint256 expected = vault.claimable(address(g), k, who);
        uint256[] memory ws = new uint256[](1);
        ws[0] = k;
        uint256 amount = vault.claimMined(address(g), ws, who);
        if (amount != expected) claimMismatch = true;
        ghostMined += amount;
        successfulClaims++;
        if (switchedAt != 0) _checkDay(g, switchedAt, k);
    }

    /// Sum every prepared window budget of k's UTC day inside the 14-day period.
    function _checkDay(MockGame g, uint64 switchedAt, uint256 k) internal {
        uint256 startsAt = GENESIS + k * 1 hours;
        if (startsAt >= uint256(switchedAt) + 14 days) return;
        uint256 day = startsAt / 1 days;
        uint256 lo = day * 1 days <= GENESIS ? 0 : (day * 1 days - GENESIS + 1 hours - 1) / 1 hours;
        uint256 hi = ((day + 1) * 1 days - GENESIS + 1 hours - 1) / 1 hours;
        uint256 sum;
        for (uint256 i = lo; i < hi; ++i) {
            (bool prepared, uint256 budget,,,,) = vault.windowAccounting(address(g), i);
            if (prepared) sum += budget;
        }
        if (sum > 2_000_000 ether) capExceeded = true;
    }
}

contract SwitchInvariantTest is VaultTestBase {
    SwitchHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new SwitchHandler(vault, game, [alice, bob, carol]);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 30
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_switchesKeepCapBucketAndCustody() public view {
        assertFalse(handler.claimMismatch(), "claim != claimable");
        assertFalse(handler.capExceeded(), "new-game day above 2M");
        assertEq(vault.miningGranted(), handler.ghostMined());
        assertLe(vault.miningGranted() + vault.knownMiningDust(), vault.miningCommitted());
        assertLe(vault.miningCommitted(), vault.miningAllocation());
        assertEq(hamster.balanceOf(address(vault)), vault.hamsterLiability(), "HAMSTER custody");
        // The registry only grows and the newest game is current.
        assertEq(vault.gameCount(), handler.gameCount());
        assertEq(vault.currentGame(), address(handler.games(handler.gameCount() - 1)));
        // Every claim stays within the curve over all ranges: nothing beyond F(effective loss).
        if (handler.successfulClaims() != 0) {
            (bool ok, bytes memory data) =
                address(vault).staticcall(abi.encodeWithSelector(vault.currentMiningState.selector));
            if (ok) {
                (uint256 globalLoss,,) = abi.decode(data, (uint256, uint256, uint256));
                assertLe(vault.miningCommitted(), vault.emissionCurve(globalLoss), "committed beyond curve");
            }
        }
    }
}

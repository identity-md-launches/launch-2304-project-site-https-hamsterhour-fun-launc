// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HamsterVault} from "../src/HamsterVault.sol";
import {HamsterBoost} from "../src/HamsterBoost.sol";
import {MockToken, MockGame} from "./helpers/Mocks.sol";

/// @notice Random sequences in which the 365-day dormant-boost sweep lands inside a successor's
/// 14-day cap period: losses, time, cap preparation in random batch sizes, range resolution,
/// claims in random order, the sweep, and a possible second switch. The vault is deployed 360 days
/// before v2 genesis so the sweep opens 5 days and 1 hour after genesis, while the first
/// successor (switched in at genesis + 50h) is still capped.
contract SweepCapHandler is Test {
    address internal constant TEAM = address(bytes20(hex"6cba4751742f6989fa224b2dc5d5d52fcef98a34"));
    uint64 internal constant GENESIS = 1791847200;

    HamsterVault public vault;
    HamsterBoost public engine;
    MockGame[] public games;
    address[3] public actors;

    uint256 public ghostMined;
    uint256 public successfulClaims;
    uint256 public cappedClaims;
    uint256 public cappedClaimsAfterSweep;
    bool public swept;
    bool public sweptInsideCap;
    bool public claimMismatch;
    bool public capExceeded;
    bool public cachedAllowanceExceeded;
    bool public budgetChanged;

    // Budget each window showed the first time anyone looked at it after it became claimable.
    mapping(address => mapping(uint256 => uint256)) public seenBudget;
    mapping(address => mapping(uint256 => bool)) public seen;
    // Windows that received loss, per game: most claims target these.
    mapping(address => uint256[]) internal lossWindows;

    constructor(HamsterVault vault_, HamsterBoost engine_, MockGame v2, MockGame successor, address[3] memory a) {
        vault = vault_;
        engine = engine_;
        games.push(v2);
        games.push(successor);
        actors = a;
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
        // 100 IMD of loss is worth 2M at the base rate, so a few entries saturate a capped day.
        g.setLoss(k, actors[actorSeed % 3], bound(amount, 0, 300 ether));
        lossWindows[address(g)].push(k);
    }

    function advance(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1 hours, 36 hours));
        _finalizeAll();
    }

    function resolve(uint256 seed) external {
        _finalizeAll();
        vault.resolveGame(address(games[seed % games.length]));
    }

    function prepare(uint256 gameSeed, uint256 maxDays) external {
        _finalizeAll();
        engine.prepareCap(address(vault), address(games[1 + gameSeed % (games.length - 1)]), bound(maxDays, 1, 16));
    }

    /// Sweeps once it opens. It does not jump the clock, so capped days are usually finalized,
    /// cached and partly claimed first.
    function sweep() external {
        if (swept || block.timestamp < vault.deployedAt() + 365 days) return;
        _finalizeAll();
        vault.sweepDormantBoost();
        swept = true;
        (,,, uint64 switchedAt,,,,,) = vault.games(address(games[games.length - 1]));
        if (block.timestamp < uint256(switchedAt) + 14 days) sweptInsideCap = true;
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

    /// Reads, without claiming, the budget of a lossy window whose capped UTC day is already cached.
    /// A cached day is committed: its windows must price the same before and after a later sweep.
    function look(uint256 gameSeed, uint256 kSeed) external {
        MockGame g = games[1 + gameSeed % (games.length - 1)];
        uint256[] storage lossy = lossWindows[address(g)];
        if (lossy.length == 0) return;
        uint256 k = lossy[kSeed % lossy.length];
        (, bool rangeReady,, uint64 switchedAt,, uint256 end,,,) = vault.games(address(g));
        if (!rangeReady || k >= end || k >= g.nextFinalizeWindow()) return;
        if (GENESIS + k * 1 hours >= uint256(switchedAt) + 14 days) return;
        (bool ready,,,,) = engine.capDays(address(vault), address(g), (GENESIS + k * 1 hours) / 1 days);
        if (!ready) return;
        (uint256 budget,) = vault.windowBudget(address(g), k);
        if (seen[address(g)][k] && seenBudget[address(g)][k] != budget) budgetChanged = true;
        seen[address(g)][k] = true;
        seenBudget[address(g)][k] = budget;
    }

    function claim(uint256 gameSeed, uint256 kSeed, uint256 actorSeed) external {
        // Mostly the newest game, whose windows are the capped ones.
        MockGame g = games[gameSeed % 4 == 0 ? gameSeed / 4 % games.length : games.length - 1];
        _finalizeAll();
        try vault.resolveGame(address(g)) {} catch {}
        (, bool rangeReady,, uint64 switchedAt, uint256 first, uint256 end,,,) = vault.games(address(g));
        if (!rangeReady) return;
        uint256 n = g.nextFinalizeWindow();
        if (end < n) n = end;
        if (n <= first) return;
        uint256[] storage lossy = lossWindows[address(g)];
        uint256 k = bound(kSeed, first, n - 1);
        if (kSeed % 4 != 0 && lossy.length != 0) {
            k = lossy[kSeed / 4 % lossy.length];
            if (k < first || k >= n) return;
        }
        address who = actors[actorSeed % 3];
        if (vault.mined(address(g), k, who)) return;

        (uint256 budget,) = vault.windowBudget(address(g), k);
        if (seen[address(g)][k] && seenBudget[address(g)][k] != budget) budgetChanged = true;

        uint256 expected = vault.claimable(address(g), k, who);
        uint256[] memory ws = new uint256[](1);
        ws[0] = k;
        uint256 amount = vault.claimMined(address(g), ws, who);
        if (amount != expected) claimMismatch = true;
        ghostMined += amount;
        successfulClaims++;

        (bool prepared, uint256 cached,,,,) = vault.windowAccounting(address(g), k);
        if (!prepared || cached != budget) budgetChanged = true;
        seen[address(g)][k] = true;
        seenBudget[address(g)][k] = budget;
        if (switchedAt != 0 && GENESIS + k * 1 hours < uint256(switchedAt) + 14 days) {
            cappedClaims++;
            if (swept) cappedClaimsAfterSweep++;
            _checkDay(g, k);
        }
    }

    /// Every prepared window budget of k's UTC day sums to at most both 2M and that day's cached
    /// allowance, whichever curve the day was cached on.
    function _checkDay(MockGame g, uint256 k) internal {
        uint256 day = (GENESIS + k * 1 hours) / 1 days;
        uint256 lo = day * 1 days <= GENESIS ? 0 : (day * 1 days - GENESIS + 1 hours - 1) / 1 hours;
        uint256 hi = ((day + 1) * 1 days - GENESIS + 1 hours - 1) / 1 hours;
        uint256 sum;
        for (uint256 i = lo; i < hi; ++i) {
            (bool prepared, uint256 budget,,,,) = vault.windowAccounting(address(g), i);
            if (prepared) sum += budget;
        }
        if (sum > 2_000_000 ether) capExceeded = true;
        (bool ready,,,, uint256 allowance) = engine.capDays(address(vault), address(g), day);
        if (ready && sum > allowance) cachedAllowanceExceeded = true;
    }
}

contract SweepCapInvariantTest is Test {
    address internal constant TEAM = address(bytes20(hex"6cba4751742f6989fa224b2dc5d5d52fcef98a34"));
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant V2 = 0xe33AB493249a2Df0D8c4a71aC54F46d1F7778367;
    uint64 internal constant GENESIS = 1791847200;

    HamsterVault internal vault;
    HamsterBoost internal engine;
    MockToken internal hamster;
    MockGame internal successor;
    SweepCapHandler internal handler;

    function setUp() public {
        vm.chainId(1);
        vm.etch(IMD, address(new MockToken()).code);
        vm.etch(V2, address(new MockGame(GENESIS)).code);
        vm.warp(uint256(GENESIS) - 360 days + 1 hours);
        engine = new HamsterBoost();
        vault = new HamsterVault(TEAM, address(engine));
        vm.warp(uint256(GENESIS) + 2 hours);
        hamster = new MockToken();
        hamster.mint(address(vault), 800_000_000 ether);
        hamster.mint(address(this), 200_000_000 ether);
        vm.prank(TEAM);
        vault.bindToken(address(hamster));
        successor = new MockGame(GENESIS);
        vm.prank(TEAM);
        vault.scheduleGame(address(successor));
        vm.warp(uint256(GENESIS) + 50 hours);
        vault.executeGame();
        handler = new SweepCapHandler(
            vault, engine, MockGame(V2), successor, [makeAddr("alice"), makeAddr("bob"), makeAddr("carol")]
        );
        targetContract(address(handler));
    }

    /// The sweep opens inside the first successor's cap period, so the property is not vacuous.
    function test_sweepOpensInsideFirstCapPeriod() public view {
        (,,, uint64 switchedAt,,,,,) = vault.games(address(successor));
        assertLt(vault.deployedAt() + 365 days, uint256(switchedAt) + 14 days);
        assertGt(vault.deployedAt() + 365 days, uint256(switchedAt));
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 60
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_sweepInsideCapKeepsDaysAndBuckets() public view {
        assertFalse(handler.claimMismatch(), "claim != claimable");
        assertFalse(handler.capExceeded(), "capped day above 2M");
        assertFalse(handler.cachedAllowanceExceeded(), "capped day above its cached allowance");
        assertFalse(handler.budgetChanged(), "window budget depends on when it is claimed");
        assertEq(vault.miningGranted(), handler.ghostMined());
        assertLe(vault.miningGranted() + vault.knownMiningDust(), vault.miningCommitted());
        assertLe(vault.miningCommitted(), vault.miningAllocation());
        assertEq(vault.miningAllocation(), handler.swept() ? 800_000_000 ether : 750_000_000 ether);
        assertEq(hamster.balanceOf(address(vault)), vault.hamsterLiability(), "HAMSTER custody");
        HamsterBoost.State memory s = engine.status(address(vault));
        assertEq(s.swept, handler.swept());
        assertEq(s.committed, 0, "dormant boost never commits");
        assertEq(s.granted, 0, "dormant boost never grants");
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

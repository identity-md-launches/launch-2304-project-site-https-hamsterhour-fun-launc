// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VaultTestBase, HamsterVault, HamsterStaking, MockToken, MockGame} from "./helpers/VaultTestBase.sol";

/// @notice Drives the vault with random sequences of game losses, mining claims, staking,
/// unstaking, vesting withdrawals, reward deposits/claims and IMD forwarding.
/// Handler-side checks are recorded in ghost flags because reverts inside handler calls are discarded.
contract VaultHandler is Test {
    address internal constant V2 = 0xe33AB493249a2Df0D8c4a71aC54F46d1F7778367;
    uint64 internal constant GENESIS = 1791847200;

    HamsterVault public vault;
    MockGame public game;
    MockToken public hamster;
    MockToken public imd;
    address[3] public actors;

    uint256 public ghostMined;
    uint256 public ghostImdDeposited;
    uint256 public ghostImdPaid;
    uint256 public ghostForwarded;
    uint256 public ghostFlushed;
    mapping(address => uint256) public stakedIn;
    mapping(address => uint256) public grantedIn;
    mapping(address => uint256) public hamsterOut;

    bool public claimMismatch;
    bool public payoutMismatch;
    bool public unexpectedWeight;
    uint256 public calls;

    constructor(HamsterVault vault_, MockGame game_, MockToken hamster_, MockToken imd_, address[3] memory actors_) {
        vault = vault_;
        game = game_;
        hamster = hamster_;
        imd = imd_;
        actors = actors_;
        imd.approve(address(vault), type(uint256).max);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 3];
    }

    function addLoss(uint256 actorSeed, uint256 amount) external {
        calls++;
        address who = _actor(actorSeed);
        uint256 current = (block.timestamp - GENESIS) / 1 hours;
        uint256 k = game.nextFinalizeWindow();
        if (current > k) k = current;
        game.setLoss(k, who, bound(amount, 0, 6_000 ether));
    }

    function advance(uint256 dt) external {
        calls++;
        vm.warp(block.timestamp + bound(dt, 1, 3 days));
        game.finalize(500);
    }

    function claim(uint256 actorSeed, uint256 kSeed, uint256 callerSeed) external {
        calls++;
        uint256 n = game.nextFinalizeWindow();
        if (n == 0) return;
        uint256 k = bound(kSeed, 0, n - 1);
        address who = _actor(actorSeed);
        if (vault.mined(V2, k, who)) return;
        uint256 expected = vault.claimable(V2, k, who);
        uint256[] memory ws = new uint256[](1);
        ws[0] = k;
        uint256 grantBefore = vault.grantBalance(who);
        vm.prank(_actor(callerSeed));
        uint256 amount = vault.claimMined(V2, ws, who);
        if (amount != expected || vault.grantBalance(who) != grantBefore + amount) claimMismatch = true;
        ghostMined += amount;
        grantedIn[who] += amount;
    }

    function stake(uint256 actorSeed, uint256 amount) external {
        calls++;
        address who = _actor(actorSeed);
        amount = bound(amount, 1, 1_000_000 ether);
        vm.prank(who);
        vault.stake(amount);
        stakedIn[who] += amount;
    }

    function requestUnstake(uint256 actorSeed, uint256 lotSeed, uint256 amount) external {
        calls++;
        address who = _actor(actorSeed);
        (uint256 lotCount,,) = vault.positionCounts(who);
        if (lotCount == 0) return;
        uint256 id = lotSeed % lotCount;
        (uint256 lotAmount,, bool isGrant) = vault.lots(who, id);
        if (isGrant || lotAmount == 0) return;
        amount = bound(amount, 1, lotAmount);
        uint256 weightBefore = vault.rewardState().weight;
        vm.prank(who);
        vault.requestUnstake(id, amount);
        // Weight stops now: it can only drop (by `amount` if active, by zero if warming up).
        uint256 weightAfter = vault.rewardState().weight;
        if (weightAfter > weightBefore || (weightBefore - weightAfter != 0 && weightBefore - weightAfter != amount)) {
            unexpectedWeight = true;
        }
    }

    function withdrawUnstaked(uint256 actorSeed, uint256 reqSeed, uint256 callerSeed) external {
        calls++;
        address who = _actor(actorSeed);
        (,, uint256 count) = vault.positionCounts(who);
        if (count == 0) return;
        uint256 id = reqSeed % count;
        (uint256 amount, uint256 readyAt, bool withdrawn) = vault.unstakeQueue(who, id);
        if (withdrawn || block.timestamp < readyAt) return;
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        uint256 before_ = hamster.balanceOf(who);
        vm.prank(_actor(callerSeed));
        uint256 out = vault.withdrawUnstaked(who, ids);
        if (out != amount || hamster.balanceOf(who) != before_ + amount) payoutMismatch = true;
        hamsterOut[who] += out;
    }

    function withdrawVested(uint256 actorSeed, uint256 idSeed) external {
        calls++;
        address who = _actor(actorSeed);
        (, uint256 count,) = vault.positionCounts(who);
        if (count == 0) return;
        uint256 id = idSeed % count;
        (uint256 amount, uint256 withdrawn,,) = vault.grants(who, id);
        uint256 due = vault.vested(who, id) - withdrawn;
        if (due == 0) return;
        if (due > amount - withdrawn) payoutMismatch = true;
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        uint256 before_ = hamster.balanceOf(who);
        uint256 out = vault.withdrawVested(who, ids);
        if (out != due || hamster.balanceOf(who) != before_ + due) payoutMismatch = true;
        hamsterOut[who] += out;
    }

    function depositRewards(uint256 amount) external {
        calls++;
        amount = bound(amount, 1, 10_000 ether);
        imd.mint(address(this), amount);
        vault.depositRewards(amount);
        ghostImdDeposited += amount;
    }

    function depositDrip(uint256 amount) external {
        calls++;
        amount = bound(amount, 1, 10_000 ether);
        imd.mint(address(this), amount);
        vault.depositDrip(amount);
        ghostImdDeposited += amount;
    }

    function pullGame(uint256 amount) external {
        calls++;
        amount = bound(amount, 1, 10_000 ether);
        game.credit(address(vault), amount);
        vault.pullGameRewards(V2);
        ghostImdDeposited += amount;
    }

    function claimRewards(uint256 actorSeed) external {
        calls++;
        address who = _actor(actorSeed);
        uint256 pending = vault.pendingIMD(who);
        if (pending == 0) return;
        uint256 before_ = imd.balanceOf(who);
        uint256 paid = vault.claimRewards(who);
        if (paid != pending || imd.balanceOf(who) != before_ + paid) payoutMismatch = true;
        ghostImdPaid += paid;
    }

    function forward(uint256 amount, bool oracle) external {
        calls++;
        amount = bound(amount, 1, 10_000 ether);
        imd.mint(address(this), amount);
        if (oracle) vault.forwardOracle(amount);
        else vault.forwardJackpot(amount);
        ghostForwarded += amount;
    }

    function flush(uint256 amount, bool oracle) external {
        calls++;
        uint256 pending = oracle ? vault.oraclePending() : vault.jackpotPending();
        if (pending == 0) return;
        amount = bound(amount, 1, pending);
        if (oracle) vault.flushOracle(amount);
        else vault.flushJackpot(amount);
        ghostFlushed += amount;
    }

    function checkpoint(uint256 maxEvents) external {
        calls++;
        vault.checkpoint(bound(maxEvents, 1, 128));
    }
}

contract VaultInvariantTest is VaultTestBase {
    VaultHandler internal handler;
    address[3] internal actors;

    function setUp() public override {
        super.setUp();
        actors = [alice, bob, carol];
        hamster.mint(carol, 100_000_000 ether);
        vm.prank(carol);
        hamster.approve(address(vault), type(uint256).max);
        handler = new VaultHandler(vault, game, hamster, imd, actors);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_custodyEqualsLiabilities() public view {
        assertEq(hamster.balanceOf(address(vault)), vault.hamsterLiability(), "HAMSTER custody");
        assertEq(imd.balanceOf(address(vault)), vault.imdLiability(), "IMD custody");
        // The vault's HAMSTER can never exceed the 800M remainder plus user principal in custody.
        assertEq(
            vault.hamsterLiability(),
            800_000_000 ether - vault.miningGranted() + vault.totalGrantBalance() + vault.totalStaked()
                + vault.totalUnstakeQueued()
        );
        assertEq(vault.jackpotPending() + vault.oraclePending(), handler.ghostForwarded() - handler.ghostFlushed());
        assertEq(game.jackpot() + game.oracle(), handler.ghostFlushed());
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_miningBucketAndWindowAccounting() public view {
        assertFalse(handler.claimMismatch(), "claim != claimable");
        assertEq(vault.miningGranted(), handler.ghostMined());
        assertLe(vault.miningGranted() + vault.knownMiningDust(), vault.miningCommitted());
        assertLe(vault.miningCommitted(), vault.MINING_ALLOCATION());
        uint256 n = game.nextFinalizeWindow();
        uint256 committed;
        uint256 curveSum;
        for (uint256 k; k < n; ++k) {
            (bool prepared, uint256 budget, uint256 paid, uint256 claimedLoss, uint256 dust,) =
                vault.windowAccounting(V2, k);
            (uint256 live, uint256 total) = vault.windowBudget(V2, k);
            curveSum += live;
            if (!prepared) continue;
            assertEq(budget, live, "cached budget drifted");
            assertLe(paid + dust, budget, "window overpaid");
            assertLe(claimedLoss, total, "window overclaimed loss");
            committed += budget;
        }
        assertEq(committed, vault.miningCommitted(), "committed != sum of prepared budgets");
        // Window budgets telescope exactly to the global curve: halving crossings lose nothing.
        if (n != 0) assertEq(curveSum, vault.emissionCurve(game.cumulativeLossAfter(n - 1)), "curve telescoping");
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_balancesWeightAndPrincipal() public view {
        assertFalse(handler.payoutMismatch(), "payout mismatch");
        assertFalse(handler.unexpectedWeight(), "unstake did not stop weight now");
        HamsterStaking.RewardState memory s = vault.rewardState();
        uint256 grantSum;
        uint256 stakedSum;
        uint256 activeLots;
        for (uint256 i; i < 3; ++i) {
            address a = actors[i];
            grantSum += vault.grantBalance(a);
            stakedSum += vault.stakedBalance(a);
            (uint256 lotCount,,) = vault.positionCounts(a);
            uint256 lotSum;
            for (uint256 j; j < lotCount; ++j) {
                (uint256 amount, uint256 activation,) = vault.lots(a, j);
                lotSum += amount;
                if (activation < s.activationCursor) activeLots += amount;
            }
            // Unvested plus vested-unwithdrawn grants and staked principal are exactly the lots.
            assertEq(lotSum, vault.grantBalance(a) + vault.stakedBalance(a), "lots != stake + grants");
            // Nobody takes out more HAMSTER than they staked or were granted.
            assertLe(handler.hamsterOut(a), handler.stakedIn(a) + handler.grantedIn(a), "withdrew more than in");
        }
        assertEq(grantSum, vault.totalGrantBalance());
        assertEq(stakedSum, vault.totalStaked());
        // Earning weight is exactly the matured lots; warming-up lots and buckets never count.
        assertEq(s.weight, activeLots, "weight != matured lots");
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_rewardsNeverExceedDeposits() public view {
        uint256 deposited = vault.hookDeposited() + vault.gameDeposited() + vault.dripDeposited();
        assertEq(deposited, handler.ghostImdDeposited());
        assertEq(vault.rewardsPaid(), handler.ghostImdPaid());
        uint256 pending;
        for (uint256 i; i < 3; ++i) {
            pending += vault.pendingIMD(actors[i]);
        }
        HamsterStaking.RewardState memory s = vault.rewardState();
        uint256 released = (s.hookReleased + s.gameReleased) / RAY_ + s.dripEmitted;
        assertLe(pending + vault.rewardsPaid(), released + 1, "accrued more than released");
        assertLe(released, deposited, "released more than deposited");
    }

    uint256 internal constant RAY_ = 1e27;
}

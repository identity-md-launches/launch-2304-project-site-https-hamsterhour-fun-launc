// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    VaultTestBase,
    HamsterVault,
    HamsterBoost,
    HamsterMining,
    HamsterStaking,
    VaultBase,
    MockToken,
    MockGame
} from "./helpers/VaultTestBase.sol";

/// @notice Failure paths and edge inputs not exercised elsewhere: wrong callers, zero and
/// maximum amounts, repeated calls, out-of-range ids and boundaries of every timelock.
contract EdgeCasesTest is VaultTestBase {
    function test_everyTeamPowerRejectsOtherCallers() public {
        MockGame successor = new MockGame(GENESIS);
        address[3] memory others = [alice, address(this), address(boost)];
        for (uint256 i; i < others.length; ++i) {
            vm.startPrank(others[i]);
            vm.expectRevert(VaultBase.NotTeam.selector);
            vault.scheduleGame(address(successor));
            vm.expectRevert(VaultBase.NotTeam.selector);
            vault.activateBoost(address(0x1234));
            vm.expectRevert(VaultBase.NotTeam.selector);
            vault.bindToken(address(hamster));
            vm.stopPrank();
        }
        // Even TEAM cannot bind twice.
        vm.prank(TEAM);
        vm.expectRevert(VaultBase.AlreadyDone.selector);
        vault.bindToken(address(hamster));
    }

    function test_bindRejectsWrongSupplyBalanceImdAndEoa() public {
        HamsterVault fresh = new HamsterVault(TEAM, address(new HamsterBoost()));
        MockToken t = new MockToken();
        t.mint(address(fresh), 800_000_000 ether);
        t.mint(alice, 200_000_000 ether - 1);
        vm.startPrank(TEAM);
        vm.expectRevert(VaultBase.InvalidAmount.selector); // supply 1e27 - 1
        fresh.bindToken(address(t));
        t.mint(alice, 2);
        vm.expectRevert(VaultBase.InvalidAmount.selector); // supply 1e27 + 1
        fresh.bindToken(address(t));
        t.burn(alice, 1);
        t.burn(address(fresh), 1);
        t.mint(alice, 1);
        vm.expectRevert(VaultBase.InvalidAmount.selector); // vault holds 8e26 - 1
        fresh.bindToken(address(t));
        vm.expectRevert(VaultBase.InvalidAddress.selector);
        fresh.bindToken(IMD);
        vm.expectRevert(VaultBase.InvalidAddress.selector);
        fresh.bindToken(carol);
        vm.expectRevert(VaultBase.InvalidAddress.selector);
        fresh.bindToken(address(0));
        t.burn(alice, 1);
        t.mint(address(fresh), 1);
        fresh.bindToken(address(t));
        vm.stopPrank();
        assertEq(fresh.token(), address(t));
    }

    function test_constructorRejectsZeroTeamOrBoost() public {
        vm.expectRevert(VaultBase.InvalidAddress.selector);
        new HamsterVault(address(0), address(boost));
        vm.expectRevert(VaultBase.InvalidAddress.selector);
        new HamsterVault(TEAM, address(0));
    }

    function test_gameScheduleBoundaries() public {
        vm.expectRevert(VaultBase.NotReady.selector);
        vault.executeGame();
        vm.startPrank(TEAM);
        vm.expectRevert(VaultBase.AlreadyDone.selector);
        vault.scheduleGame(V2);
        vm.expectRevert(); // EOA has no interface
        vault.scheduleGame(carol);
        vm.expectRevert(HamsterBoost.InvalidInterface.selector);
        vault.scheduleGame(address(boost));
        vm.expectRevert(); // a contract without the game ABI
        vault.scheduleGame(address(vault));
        MockGame successor = new MockGame(GENESIS);
        vault.scheduleGame(address(successor));
        vm.stopPrank();
        uint256 readyAt = vault.pendingGameReadyAt();
        assertEq(readyAt, vm.getBlockTimestamp() + 48 hours);
        vm.warp(readyAt - 1);
        vm.expectRevert(VaultBase.NotReady.selector);
        vault.executeGame();
        assertEq(vault.currentGame(), V2);
        // Rescheduling restarts the full delay.
        MockGame other = new MockGame(GENESIS);
        vm.prank(TEAM);
        vault.scheduleGame(address(other));
        vm.warp(readyAt);
        vm.expectRevert(VaultBase.NotReady.selector);
        vault.executeGame();
        vm.warp(vm.getBlockTimestamp() + 48 hours - 1);
        vm.prank(carol);
        vault.executeGame();
        assertEq(vault.currentGame(), address(other));
        assertEq(vault.pendingGame(), address(0));
        vm.expectRevert(VaultBase.NotReady.selector);
        vault.executeGame();
        // An old game can never be re-registered to reopen its excluded suffix.
        vm.prank(TEAM);
        vm.expectRevert(VaultBase.AlreadyDone.selector);
        vault.scheduleGame(V2);
        assertEq(vault.gameCount(), 2);
    }

    function test_unknownGameAndWindowBeyondFinalization() public {
        MockGame stranger = new MockGame(GENESIS);
        vm.expectRevert(HamsterMining.UnknownGame.selector);
        vault.claimMined(address(stranger), one(0), alice);
        vm.expectRevert(HamsterMining.UnknownGame.selector);
        vault.pullGameRewards(address(stranger));
        vm.expectRevert(HamsterMining.UnknownGame.selector);
        vault.resolveGame(address(stranger));
        game.finalize(10);
        uint256 n = game.nextFinalizeWindow();
        vm.expectRevert(HamsterBoost.NotFinalized.selector);
        vault.claimMined(V2, one(n), alice);
        vm.expectRevert(VaultBase.TooMany.selector);
        vault.claimMined(V2, new uint256[](0), alice);
        vm.expectRevert(VaultBase.InvalidAddress.selector);
        vault.claimMined(V2, one(0), address(vault));
    }

    function test_zeroLossClaimConsumesSlotWithoutGrant() public {
        game.setLoss(0, alice, 1 ether);
        game.finalize(2);
        assertEq(_claim(0, bob), 0);
        (uint256 lots, uint256 grantCount,) = vault.positionCounts(bob);
        assertEq(lots + grantCount, 0);
        assertTrue(vault.mined(V2, 0, bob));
        vm.expectRevert(VaultBase.AlreadyDone.selector);
        _claim(0, bob);
        assertEq(_claim(0, alice), 20_000 ether);
        _conservation();
    }

    function test_lossAboveTotalOrOverclaimedWindowReverts() public {
        game.setLoss(0, alice, 2 ether);
        game.setLoss(0, bob, 2 ether);
        game.finalize(2);
        // A dishonest game reporting more loss for one account than the window total.
        vm.store(
            V2, keccak256(abi.encode(bob, keccak256(abi.encode(uint256(0), uint256(2))))), bytes32(uint256(5 ether))
        );
        assertEq(game.lossOf(0, bob), 5 ether);
        vm.expectRevert(HamsterBoost.BadLossHistory.selector);
        vault.claimable(V2, 0, bob);
        vm.expectRevert(HamsterBoost.BadLossHistory.selector);
        _claim(0, bob);
        // sum(lossOf) > total: the later claimant cannot take more than the window's remainder.
        vm.store(
            V2, keccak256(abi.encode(bob, keccak256(abi.encode(uint256(0), uint256(2))))), bytes32(uint256(3 ether))
        );
        assertEq(_claim(0, alice), 40_000 ether);
        vm.expectRevert(HamsterBoost.BadLossHistory.selector);
        _claim(0, bob);
        _conservation();
    }

    function test_stakingFailurePaths() public {
        vm.expectRevert(VaultBase.InvalidAmount.selector);
        _stake(alice, 0);
        vm.expectRevert(VaultBase.InvalidAmount.selector);
        _stake(alice, uint256(type(uint128).max) + 1);
        uint256 lot = _stake(alice, 10 ether);
        // Bob cannot touch alice's lot: his lot index does not exist.
        vm.prank(bob);
        vm.expectRevert();
        vault.requestUnstake(lot, 1);
        vm.startPrank(alice);
        vm.expectRevert(VaultBase.InvalidAmount.selector);
        vault.requestUnstake(lot, 0);
        vm.expectRevert(VaultBase.InvalidAmount.selector);
        vault.requestUnstake(lot, 10 ether + 1);
        uint256 req = vault.requestUnstake(lot, 10 ether);
        vm.expectRevert(VaultBase.InvalidAmount.selector);
        vault.requestUnstake(lot, 1);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 24 hours - 1);
        vm.expectRevert(VaultBase.NotReady.selector);
        vault.withdrawUnstaked(alice, one(req));
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.expectRevert(VaultBase.AlreadyDone.selector);
        vault.withdrawUnstaked(alice, pair(req, req));
        vm.expectRevert(VaultBase.TooMany.selector);
        vault.withdrawUnstaked(alice, new uint256[](0));
        vm.expectRevert(VaultBase.TooMany.selector);
        vault.withdrawUnstaked(alice, new uint256[](33));
        uint256 before_ = hamster.balanceOf(alice);
        vm.prank(carol);
        assertEq(vault.withdrawUnstaked(alice, one(req)), 10 ether);
        assertEq(hamster.balanceOf(alice), before_ + 10 ether);
        assertEq(hamster.balanceOf(carol), 0);
        vm.expectRevert(VaultBase.AlreadyDone.selector);
        vault.withdrawUnstaked(alice, one(req));
        vm.expectRevert();
        vault.withdrawUnstaked(alice, one(req + 1));
        _conservation();
    }

    function test_grantLotCannotBeUnstakedOrWithdrawnEarly() public {
        game.setLoss(0, alice, 1 ether);
        game.finalize(2);
        _claim(0, alice);
        vm.startPrank(alice);
        vm.expectRevert(HamsterStaking.WrongLot.selector);
        vault.requestUnstake(0, 1);
        // Nothing is vested in the claim's own second.
        vm.expectRevert(VaultBase.InvalidAmount.selector);
        vault.withdrawVested(alice, one(0));
        vm.expectRevert(VaultBase.TooMany.selector);
        vault.withdrawVested(alice, new uint256[](0));
        vm.expectRevert();
        vault.withdrawVested(alice, one(1));
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 7 days / 2);
        assertEq(vault.vested(alice, 0), 10_000 ether);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        assertEq(vault.vested(alice, 0), 20_000 ether);
        // Only the grantee decides when vested principal leaves the weight pool.
        address[3] memory others = [bob, carol, address(this)];
        for (uint256 i; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(HamsterStaking.NotAccount.selector);
            vault.withdrawVested(alice, one(0));
        }
        // Same id twice in one batch pays only once.
        vm.prank(alice);
        assertEq(vault.withdrawVested(alice, pair(0, 0)), 20_000 ether);
        assertEq(vault.grantBalance(alice), 0);
        _conservation();
    }

    function test_rewardFailurePaths() public {
        vm.expectRevert(VaultBase.InvalidAmount.selector);
        vault.depositRewards(0);
        vm.expectRevert(VaultBase.InvalidAmount.selector);
        vault.depositDrip(0);
        vm.expectRevert(VaultBase.InvalidAmount.selector);
        vault.claimRewards(alice);
        vm.expectRevert(VaultBase.InvalidAmount.selector);
        vault.pullGameRewards(V2);
        vm.expectRevert(VaultBase.TooMany.selector);
        vault.checkpoint(0);
        vm.expectRevert(VaultBase.TooMany.selector);
        vault.checkpoint(129);
        vm.expectRevert(VaultBase.TooMany.selector);
        vault.checkpointAccount(alice, 0);
        vm.expectRevert(VaultBase.TooMany.selector);
        vault.checkpointAccount(alice, 129);
        // A depositor without allowance cannot fund anything.
        vm.prank(bob);
        vm.expectRevert();
        vault.depositRewards(1 ether);
        _conservation();
    }

    function test_forwardingFailurePaths() public {
        vm.expectRevert(VaultBase.InvalidAmount.selector);
        vault.forwardJackpot(0);
        vm.expectRevert(VaultBase.InvalidAmount.selector);
        vault.forwardOracle(uint256(type(uint128).max) + 1);
        vm.expectRevert(VaultBase.InvalidAmount.selector);
        vault.flushJackpot(1);
        vault.forwardJackpot(5 ether);
        vault.forwardOracle(3 ether);
        vm.expectRevert(VaultBase.InvalidAmount.selector);
        vault.flushJackpot(5 ether + 1);
        vm.expectRevert(VaultBase.InvalidAmount.selector);
        vault.flushOracle(3 ether + 1);
        vm.expectRevert(VaultBase.InvalidAmount.selector);
        vault.flushOracle(0);
        // Jackpot balance cannot be flushed as oracle funding or vice versa.
        vault.flushOracle(3 ether);
        vm.expectRevert(VaultBase.InvalidAmount.selector);
        vault.flushOracle(1);
        vm.prank(carol);
        vault.flushJackpot(5 ether);
        assertEq(game.jackpot(), 5 ether);
        assertEq(game.oracle(), 3 ether);
        assertEq(imd.allowance(address(vault), V2), 0);
        _conservation();
    }

    function test_boostEntryPointsInertBeforeActivation() public {
        vm.expectRevert(HamsterBoost.NotReady.selector);
        vault.executeBoost();
        vm.expectRevert(HamsterBoost.IneligibleNFT.selector);
        vault.registerNFT(1);
        vm.expectRevert(HamsterBoost.NotReady.selector);
        vault.prepareBoostDay(1);
        vm.expectRevert(HamsterBoost.NotReady.selector);
        vault.claimBoost(0, 0);
        vm.expectRevert(HamsterBoost.NotReady.selector);
        vault.sweepDormantBoost();
        (uint256 freeMining,, uint256 freeBoost,) = vault.bucketsLeft();
        assertEq(freeMining, 750_000_000 ether);
        assertEq(freeBoost, 50_000_000 ether);
    }

    function test_boostActivationDeadlineBoundary() public {
        address nft = address(new BoostNFT());
        // Scheduling must leave room to execute before day 365.
        vm.warp(vault.deployedAt() + 365 days - 12 hours);
        vm.prank(TEAM);
        vm.expectRevert(HamsterBoost.NotReady.selector);
        vault.activateBoost(nft);
        vm.warp(vault.deployedAt() + 365 days - 12 hours - 1);
        vm.prank(TEAM);
        vault.activateBoost(nft);
        // A pending commitment can be replaced only while its execution still fits the deadline.
        vm.prank(TEAM);
        vault.activateBoost(nft);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(TEAM);
        vm.expectRevert(HamsterBoost.NotReady.selector);
        vault.activateBoost(nft);
        vm.warp(vm.getBlockTimestamp() + 12 hours - 2);
        vm.expectRevert(HamsterBoost.NotReady.selector);
        vault.executeBoost();
        vm.warp(vm.getBlockTimestamp() + 1);
        vault.executeBoost();
        assertEq(boost.status(address(vault)).collection, nft);
        // Activation is once: neither a new schedule nor a second execution is possible.
        vm.prank(TEAM);
        vm.expectRevert(HamsterBoost.AlreadyDone.selector);
        vault.activateBoost(nft);
        vm.expectRevert(HamsterBoost.NotReady.selector);
        vault.executeBoost();
        vm.warp(vault.deployedAt() + 400 days);
        vm.expectRevert(HamsterBoost.AlreadyDone.selector);
        vault.sweepDormantBoost();
    }

    function test_boostRejectsNonMainnetAndNonErc721() public {
        address nft = address(new BoostNFT());
        vm.chainId(8453);
        vm.prank(TEAM);
        vm.expectRevert(HamsterBoost.InvalidCollection.selector);
        vault.activateBoost(nft);
        vm.chainId(1);
        vm.prank(TEAM);
        vm.expectRevert(HamsterBoost.InvalidCollection.selector);
        vault.activateBoost(carol);
        vm.prank(TEAM);
        vm.expectRevert(); // ERC-20 has no supportsInterface
        vault.activateBoost(address(hamster));
    }

    function test_directBoostCallsCannotTouchVaultNamespace() public {
        // An outside contract writing to the engine only writes to its own namespace.
        address nft = address(new BoostNFT());
        vm.expectRevert();
        boost.schedule(nft);
        vm.expectRevert();
        boost.sweep();
        vm.expectRevert(HamsterBoost.NotReady.selector);
        boost.prepare(1);
        assertEq(boost.status(address(vault)).pendingCollection, address(0));
    }

    function test_rateAndHalvingEdges() public view {
        (uint256 rate, uint256 halving) = boost.rateAndHalving(0);
        assertEq(rate, 20_000 ether);
        assertEq(halving, 0);
        (rate, halving) = boost.rateAndHalving(18_750 ether - 1);
        assertEq(rate, 20_000 ether);
        (rate, halving) = boost.rateAndHalving(18_750 ether);
        assertEq(rate, 10_000 ether);
        assertEq(halving, 1);
        (rate,) = boost.rateAndHalving(256 * 18_750 ether);
        assertEq(rate, 0);
        (rate,) = boost.rateAndHalving(type(uint256).max);
        assertEq(rate, 0);
        assertEq(vault.emissionCurve(0), 0);
        assertEq(vault.emissionCurve(1), 20_000);
        assertLe(vault.emissionCurve(90 * 18_750 ether - 1), 750_000_000 ether);
        assertEq(vault.emissionCurve(90 * 18_750 ether), 750_000_000 ether);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_windowBudgetsTelescopeAcrossHalvings(uint256 seed, uint8 count) public {
        uint256 n = bound(count, 1, 12);
        for (uint256 k; k < n; ++k) {
            game.setLoss(k, alice, bound(uint256(keccak256(abi.encode(seed, k))), 0, 30_000 ether));
            game.setLoss(k, bob, bound(uint256(keccak256(abi.encode(seed, k, 1))), 0, 30_000 ether));
        }
        vm.warp(uint256(GENESIS) + (n + 1) * 1 hours);
        game.finalize(n);
        uint256 sum;
        for (uint256 k; k < n; ++k) {
            (uint256 budget,) = vault.windowBudget(V2, k);
            sum += budget;
        }
        assertEq(sum, vault.emissionCurve(game.cumulativeLossAfter(n - 1)));
        // Claiming everything in reverse order commits exactly the curve and never more.
        uint256 paid;
        for (uint256 k = n; k > 0; --k) {
            paid += _claim(k - 1, bob);
            paid += _claim(k - 1, alice);
        }
        assertEq(vault.miningCommitted(), sum);
        assertLe(paid, sum);
        assertLe(sum - paid, 2 * n); // at most one wei of rounding per share
        _conservation();
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_newGameDailyCapNeverExceeded(uint256 seed) public {
        MockGame successor = new MockGame(GENESIS);
        uint256 switchedAt = _switch(successor);
        uint256 first = (switchedAt - GENESIS + 1 hours - 1) / 1 hours;
        // Fill the rest of the switch day and the next whole UTC day with random large losses.
        uint256 dayEnd = (switchedAt / 1 days + 2) * 1 days;
        uint256 last = (dayEnd - GENESIS) / 1 hours;
        for (uint256 k = first; k < last; ++k) {
            successor.setLoss(k, alice, bound(uint256(keccak256(abi.encode(seed, k))), 0, 2_000 ether));
        }
        vm.warp(dayEnd + 1 hours);
        _resolve(successor);
        uint256 dayOneSum;
        uint256 dayTwoSum;
        for (uint256 k = first; k < last; ++k) {
            (uint256 budget,) = vault.windowBudget(address(successor), k);
            if ((GENESIS + k * 1 hours) / 1 days == switchedAt / 1 days) dayOneSum += budget;
            else dayTwoSum += budget;
        }
        assertLe(dayOneSum, 2_000_000 ether);
        assertLe(dayTwoSum, 2_000_000 ether);
        // Claim every window and check what was committed respects the cap.
        uint256 committedBefore = vault.miningCommitted();
        for (uint256 k = first; k < last; ++k) {
            vault.claimMined(address(successor), one(k), alice);
        }
        assertLe(vault.miningCommitted() - committedBefore, 4_000_000 ether);
        _conservation();
    }

    function test_prepareCapBoundsAndUnknownOrUnresolvedGames() public {
        vm.expectRevert(HamsterBoost.TooMany.selector);
        boost.prepareCap(address(vault), V2, 0);
        vm.expectRevert(HamsterBoost.TooMany.selector);
        boost.prepareCap(address(vault), V2, 17);
        // The first game has no cap period.
        (bool complete, uint256 dropped) = boost.prepareCap(address(vault), V2, 1);
        assertTrue(complete);
        assertEq(dropped, 0);
        MockGame stranger = new MockGame(GENESIS);
        vm.expectRevert(HamsterBoost.UnknownGame.selector);
        boost.prepareCap(address(vault), address(stranger), 1);
        MockGame next = new MockGame(GENESIS);
        uint256 switchTime = _switch(next);
        vm.expectRevert(HamsterBoost.NotReady.selector);
        boost.prepareCap(address(vault), address(next), 1);
        _resolve(next);
        // Nothing of an unfinished UTC day is cached; preparation stops there.
        (complete,) = boost.prepareCap(address(vault), address(next), 16);
        assertFalse(complete);
        (bool ready,,,,) = boost.capDays(address(vault), address(next), switchTime / 1 days);
        assertFalse(ready);
        (, uint256 nextDay,,) = boost.capStates(address(vault), address(next));
        assertEq(nextDay, switchTime / 1 days);
        // After the full 14-day period every day is cached and the state is complete.
        vm.warp(switchTime + 15 days + 2 hours);
        next.finalize(20_000);
        (complete, dropped) = boost.prepareCap(address(vault), address(next), 16);
        assertTrue(complete);
        assertEq(dropped, 0);
        (complete,) = boost.prepareCap(address(vault), address(next), 1);
        assertTrue(complete);
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzz_cappedDayPaysAtMostTwoMillionAtAnyCurvePosition(uint256 priorSeed, uint256 lossSeed) public {
        uint256 prior = bound(priorSeed, 0, 60 * 18_750 ether);
        if (prior != 0) game.setLoss(0, carol, prior);
        MockGame next = new MockGame(GENESIS);
        uint256 switchTime = _switch(next);
        uint256 day = switchTime / 1 days + 1;
        uint256 first = (day * 1 days - GENESIS + 1 hours - 1) / 1 hours;
        uint256 lossA = bound(lossSeed, 1, 40_000 ether);
        uint256 lossB = bound(uint256(keccak256(abi.encode(lossSeed))), 0, 40_000 ether);
        next.setLoss(first, alice, lossA);
        next.setLoss(first + 5, bob, lossB);
        vm.warp((day + 1) * 1 days + 1 hours);
        _resolve(next);
        if (prior != 0) _claim(0, carol);
        uint256 committedBefore = vault.miningCommitted();
        uint256 paid = vault.claimMined(address(next), one(first + 5), bob);
        paid += vault.claimMined(address(next), one(first), alice);
        (bool ready, uint256 pos,, uint256 raw, uint256 allowance) = boost.capDays(address(vault), address(next), day);
        assertTrue(ready);
        assertEq(pos, prior);
        assertEq(raw, vault.emissionCurve(prior + lossA + lossB) - vault.emissionCurve(prior));
        assertLe(allowance, 2_000_000 ether, "capped day above 2M");
        if (raw <= 2_000_000 ether) assertEq(allowance, raw);
        else assertApproxEqAbs(allowance, 2_000_000 ether, 1e12, "cap forfeits emission");
        // Splitting the allowance pro rata across the day's windows rounds each one down.
        uint256 committedDelta = vault.miningCommitted() - committedBefore;
        assertLe(committedDelta, allowance);
        assertLe(allowance - committedDelta, 2);
        assertLe(paid, committedDelta);
        assertLe(committedDelta - paid, 2);
        // The curve advanced only by the loss actually paid for; the rest is deferred.
        (uint256 globalLoss,,) = vault.currentMiningState();
        assertApproxEqAbs(vault.emissionCurve(globalLoss), vault.miningCommitted(), 2);
        assertGe(vault.emissionCurve(globalLoss), vault.miningCommitted());
        (,,, uint256 dropped) = boost.capStates(address(vault), address(next));
        assertEq(globalLoss + dropped, prior + lossA + lossB);
        _conservation();
    }

    function test_forwardingFollowsSecondSwitchWithoutHookChange() public {
        vault.forwardJackpot(1 ether);
        MockGame g3 = new MockGame(GENESIS);
        _switch(g3);
        vault.forwardOracle(2 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _resolve(g3);
        MockGame g4 = new MockGame(GENESIS);
        _switch(g4);
        vault.flushJackpot(1 ether);
        vault.flushOracle(2 ether);
        assertEq(g4.jackpot(), 1 ether);
        assertEq(g4.oracle(), 2 ether);
        assertEq(g3.jackpot() + g3.oracle() + game.jackpot() + game.oracle(), 0);
        // Old games keep their staker share pullable.
        g3.credit(address(vault), 4 ether);
        vault.pullGameRewards(address(g3));
        assertEq(vault.gameDeposited(), 4 ether);
        _conservation();
    }
}

contract BoostNFT {
    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x80ac58cd;
    }

    function ownerOf(uint256) external pure returns (address) {
        return address(1);
    }
}

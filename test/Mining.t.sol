// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    VaultTestBase,
    HamsterVault,
    HamsterBoost,
    HamsterMining,
    VaultBase,
    MockToken,
    MockGame
} from "./helpers/VaultTestBase.sol";

contract MiningTest is VaultTestBase {
    function test_retroactivePermissionlessClaimCreatesOnlyBeneficiaryGrant() public {
        game.setLoss(0, alice, 3 ether);
        game.finalize(2);
        uint256 before_ = hamster.balanceOf(alice);
        vm.prank(carol);
        uint256 amount = _claim(0, alice);
        assertEq(amount, 60_000 ether);
        assertEq(hamster.balanceOf(alice), before_);
        assertEq(vault.grantBalance(alice), amount);
        assertEq(vault.grantBalance(carol), 0);
        assertEq(vault.claimable(V2, 0, alice), 0);
        vm.expectRevert(VaultBase.AlreadyDone.selector);
        _claim(0, alice);
        _conservation();
    }

    function test_halvingCrossingAndDust() public {
        game.setLoss(0, alice, 18_750 ether - 1);
        game.setLoss(1, alice, 1);
        game.setLoss(1, bob, 1);
        game.setLoss(1, carol, 1);
        game.finalize(2);
        (uint256 budget,) = vault.windowBudget(V2, 1);
        assertEq(budget, 40_000);
        assertEq(_claim(1, alice), 13_333);
        assertEq(_claim(1, bob), 13_333);
        assertEq(_claim(1, carol), 13_333);
        assertEq(vault.knownMiningDust(), 1);
        (,,, uint256 claimedLoss, uint256 dust, uint256 fractional) = vault.windowAccounting(V2, 1);
        assertEq(claimedLoss, 3);
        assertEq(dust, 1);
        assertEq(fractional, 0);
        _claim(0, alice);
        _conservation();
    }

    function test_poolNettingRemainderRemainsReservedForever() public {
        game.setLoss(0, alice, 1 ether);
        game.setTotal(0, 3 ether);
        game.finalize(2);
        assertEq(_claim(0, alice), 20_000 ether);
        (, uint256 reserve,,) = vault.bucketsLeft();
        assertEq(reserve, 40_000 ether);
        vm.warp(vm.getBlockTimestamp() + 5 * 365 days);
        assertEq(vault.claimable(V2, 0, bob), 0);
        _conservation();
    }

    function test_finalizationBoundsDuplicatesAndInvalidBeneficiary() public {
        game.setLoss(0, alice, 1 ether);
        vm.expectRevert(HamsterBoost.NotFinalized.selector);
        _claim(0, alice);
        game.finalize(2);
        vm.expectRevert(VaultBase.AlreadyDone.selector);
        vault.claimMined(V2, pair(0, 0), alice);
        assertFalse(vault.mined(V2, 0, alice));
        vm.expectRevert(VaultBase.InvalidAddress.selector);
        _claim(0, address(0));
        vm.expectRevert(VaultBase.TooMany.selector);
        vault.claimMined(V2, new uint256[](33), alice);
        game.corruptBefore(0, 1);
        vm.expectRevert(HamsterBoost.BadLossHistory.selector);
        _claim(0, alice);
    }

    function testFuzz_claimOrderIndependentAndConserved(uint96 lossA, uint96 lossB, uint96 prior) public {
        uint256 a = bound(uint256(lossA), 1, 1_000 ether);
        uint256 b = bound(uint256(lossB), 1, 1_000 ether);
        uint256 p = bound(uint256(prior), 0, 100_000 ether);
        game.setLoss(0, carol, p);
        game.setLoss(1, alice, a);
        game.setLoss(1, bob, b);
        game.finalize(2);
        uint256 expectedA = vault.claimable(V2, 1, alice);
        uint256 expectedB = vault.claimable(V2, 1, bob);
        uint256 snapshot = vm.snapshotState();
        assertEq(_claim(1, bob), expectedB);
        assertEq(_claim(1, alice), expectedA);
        _conservation();
        assertTrue(vm.revertToStateAndDelete(snapshot));
        assertEq(_claim(1, alice), expectedA);
        assertEq(_claim(1, bob), expectedB);
        _conservation();
    }

    function testFuzz_curveMonotoneAdditiveAndBounded(uint128 x, uint128 y) public view {
        uint256 a = uint256(x);
        uint256 b = a + y;
        uint256 fa = vault.emissionCurve(a);
        uint256 fb = vault.emissionCurve(b);
        assertLe(fa, fb);
        assertLe(fb, 750_000_000 ether);
        assertEq(fa + (fb - fa), fb);
    }

    function test_curveKnownBoundariesAndRate() public view {
        assertEq(vault.emissionCurve(1 ether), 20_000 ether);
        assertEq(vault.emissionCurve(18_750 ether), 375_000_000 ether);
        assertEq(vault.emissionCurve(37_500 ether), 562_500_000 ether);
        assertEq(vault.emissionCurve(type(uint256).max), 750_000_000 ether);
        (uint256 rate, uint256 halving) = boost.rateAndHalving(37_500 ether);
        assertEq(rate, 5_000 ether);
        assertEq(halving, 2);
    }

    function test_miningBucketExhaustsWithoutOvercommitment() public {
        game.setLoss(0, alice, 90 * 18_750 ether);
        game.setLoss(1, bob, 1 ether);
        game.finalize(2);
        assertEq(_claim(1, bob), 0);
        assertEq(_claim(0, alice), 750_000_000 ether);
        assertEq(vault.miningCommitted(), 750_000_000 ether);
        assertEq(vault.miningGranted(), 750_000_000 ether);
        (uint256 left, uint256 reserve,,) = vault.bucketsLeft();
        assertEq(left + reserve, 0);
        (uint256 globalLoss,, uint256 halving) = vault.currentMiningState();
        assertEq(globalLoss, 90 * 18_750 ether + 1 ether);
        assertEq(halving, 90);
        _conservation();
    }

    function test_switchTimelockHasNoEarlyEffectAndChecksInterface() public {
        MockGame next = new MockGame(GENESIS);
        vm.expectRevert(VaultBase.NotTeam.selector);
        vault.scheduleGame(address(next));
        vm.prank(TEAM);
        vault.scheduleGame(address(next));
        assertEq(vault.currentGame(), V2);
        vm.warp(vm.getBlockTimestamp() + 48 hours - 1);
        vm.expectRevert(VaultBase.NotReady.selector);
        vault.executeGame();
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(carol);
        vault.executeGame();
        assertEq(vault.currentGame(), address(next));
        vm.prank(TEAM);
        vm.expectRevert(VaultBase.AlreadyDone.selector);
        vault.scheduleGame(V2);
        vm.prank(TEAM);
        vm.expectRevert();
        vault.scheduleGame(address(hamster));
    }

    function test_switchOverlappingBacklogNeverResetsOrDoubleCountsLoss() public {
        game.setLoss(0, alice, 18_750 ether);
        MockGame next = new MockGame(GENESIS);
        next.setLoss(0, bob, 500_000 ether);
        uint256 switchTime = _switch(next);
        uint256 first = (switchTime - GENESIS + 1 hours - 1) / 1 hours;
        next.setLoss(first, bob, 10 ether);
        vm.expectRevert(HamsterMining.NotFinalized.selector);
        vault.resolveGame(address(next));
        vm.warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 1 hours);
        _resolve(next);
        (,,,,, uint256 localOrigin, uint256 globalOrigin,) = _gameRange(address(next));
        assertEq(localOrigin, 500_000 ether);
        assertEq(globalOrigin, 18_750 ether);
        assertEq(vault.claimMined(address(next), one(first), bob), 100_000 ether);
        assertEq(_claim(0, alice), 375_000_000 ether);
        vm.expectRevert(HamsterBoost.ExcludedWindow.selector);
        vault.claimMined(address(next), one(0), bob);
        vm.expectRevert(HamsterBoost.ExcludedWindow.selector);
        _claim(first, alice);
        vm.warp(vm.getBlockTimestamp() + 1_000 days);
        assertEq(vault.claimable(V2, 1, carol), 0);
        _conservation();
    }

    function _gameRange(address which)
        internal
        view
        returns (
            bool ready,
            uint64 genesis,
            uint64 at,
            uint256 first,
            uint256 end,
            uint256 local,
            uint256 global,
            address previous
        )
    {
        (, ready, genesis, at, first, end, local, global, previous) = vault.games(which);
    }

    function test_newGameDailyCapScalesEveryWindowAndDefersTheRest() public {
        MockGame next = new MockGame(GENESIS);
        uint256 switchTime = _switch(next);
        uint256 day = switchTime / 1 days + 1;
        uint256 first = (day * 1 days - GENESIS + 1 hours - 1) / 1 hours;
        next.setLoss(first, alice, 200 ether);
        next.setLoss(first + 1, bob, 200 ether);
        uint256 uncapped = (switchTime + 14 days - GENESIS + 1 hours - 1) / 1 hours;
        next.setLoss(uncapped, alice, 200 ether);
        vm.warp(day * 1 days + 3 hours);
        _resolve(next);
        vm.expectRevert(HamsterBoost.NotFinalized.selector);
        vault.claimMined(address(next), one(first), alice);
        // The last window starts at 23:20 and ends at 00:20 in the v2 timetable.
        vm.warp((day + 1) * 1 days + 1 hours);
        next.finalize(200);
        uint256 snapshot = vm.snapshotState();
        assertEq(vault.claimMined(address(next), one(first + 1), bob), 1_000_000 ether);
        assertEq(vault.claimMined(address(next), one(first), alice), 1_000_000 ether);
        assertTrue(vm.revertToStateAndDelete(snapshot));
        // Anyone may cache the capped days first; the result is identical.
        (bool complete,) = boost.prepareCap(address(vault), address(next), 2);
        assertFalse(complete);
        (bool ready,, uint256 lossStart, uint256 raw, uint256 allowance) =
            boost.capDays(address(vault), address(next), day);
        assertTrue(ready);
        assertEq(lossStart, 0);
        assertEq(raw, 8_000_000 ether);
        assertEq(allowance, 2_000_000 ether);
        assertEq(vault.claimMined(address(next), one(first), alice), 1_000_000 ether);
        assertEq(vault.claimMined(address(next), one(first + 1), bob), 1_000_000 ether);
        // The curve advanced only by the 100 IMD worth of loss that was actually paid.
        (uint256 globalLoss,,) = vault.currentMiningState();
        assertEq(globalLoss, 100 ether);
        assertEq(vault.emissionCurve(globalLoss), vault.miningCommitted());
        vm.warp(uint256(GENESIS) + (uncapped + 1) * 1 hours);
        next.finalize(1000);
        assertEq(vault.claimMined(address(next), one(uncapped), alice), 4_000_000 ether);
        (,,, uint256 dropped) = vault_capState(address(next));
        assertEq(dropped, 300 ether);
        (globalLoss,,) = vault.currentMiningState();
        assertEq(globalLoss, 300 ether);
        assertEq(vault.emissionCurve(globalLoss), vault.miningCommitted());
        _conservation();
    }

    function vault_capState(address which) internal view returns (bool, uint256, uint256, uint256) {
        return boost.capStates(address(vault), which);
    }

    function test_newGameCapCrossingHalvingKeepsCurveConsistentAndChainsToNextGame() public {
        MockGame next = new MockGame(GENESIS);
        uint256 switchTime = _switch(next);
        uint256 day = switchTime / 1 days + 1;
        uint256 first = (day * 1 days - GENESIS + 1 hours - 1) / 1 hours;
        // 20,000 IMD in one capped window crosses the first halving: raw 375M + 625M/18750*1250.
        next.setLoss(first, alice, 20_000 ether);
        next.setLoss(first + 30, bob, 100 ether);
        vm.warp((day + 2) * 1 days + 1 hours);
        _resolve(next);
        assertEq(vault.claimMined(address(next), one(first), alice), 2_000_000 ether);
        // Finalized history already includes bob's window: 100 IMD consumed on each day.
        (uint256 globalLoss, uint256 rate, uint256 halving) = vault.currentMiningState();
        assertEq(globalLoss, 200 ether);
        assertEq(halving, 0);
        assertEq(rate, 20_000 ether);
        // The following capped day resumed at full rate because only 100 IMD were consumed.
        assertEq(vault.claimMined(address(next), one(first + 30), bob), 2_000_000 ether);
        assertEq(vault.emissionCurve(200 ether), vault.miningCommitted());
        // A further switch chains the effective position, not the raw cumulative loss.
        MockGame third = new MockGame(GENESIS);
        uint256 thirdSwitch = _switch(third);
        uint256 k = (thirdSwitch - GENESIS + 1 hours - 1) / 1 hours;
        third.setLoss(k, carol, 1 ether);
        vm.warp(uint256(GENESIS) + (k + 1) * 1 hours);
        next.finalize(10_000);
        third.finalize(10_000);
        vault.resolveGame(address(third));
        (,,,,,, uint256 globalOrigin,) = _gameRange(address(third));
        assertEq(globalOrigin, 200 ether);
        (bool complete, uint256 dropped) = boost.prepareCap(address(vault), address(next), 16);
        assertTrue(complete);
        assertEq(dropped, 19_900 ether);
        _conservation();
    }

    function test_miningStateFallsBackToOutgoingGameWhileSuccessorUnresolved() public {
        game.setLoss(0, alice, 5 ether);
        game.finalize(1);
        MockGame next = new MockGame(GENESIS);
        _switch(next);
        (, bool ready,,,,,,,) = vault.games(address(next));
        assertFalse(ready);
        (uint256 globalLoss, uint256 rate, uint256 halving) = vault.currentMiningState();
        assertEq(globalLoss, 5 ether);
        assertEq(rate, 20_000 ether);
        assertEq(halving, 0);
    }

    function test_switchTwiceChainsFinalRanges() public {
        game.setLoss(0, alice, 1 ether);
        MockGame next = new MockGame(GENESIS);
        _switch(next);
        uint256 k = (vm.getBlockTimestamp() - GENESIS) / 1 hours;
        next.setLoss(k, alice, 2 ether);
        MockGame third = new MockGame(GENESIS);
        vm.prank(TEAM);
        vault.scheduleGame(address(third));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.expectRevert(HamsterMining.NotFinalized.selector);
        vault.executeGame();
        game.finalize(1000);
        next.finalize(1000);
        vault.executeGame();
        third.finalize(1000);
        vault.resolveGame(address(third));
        (,,,,,, uint256 global,) = _gameRange(address(third));
        assertEq(global, 3 ether);
        assertEq(_claim(0, alice), 20_000 ether);
        assertEq(vault.claimMined(address(next), one(k), alice), 40_000 ether);
        _conservation();
    }

    function test_bindChecksAndImmutableTeam() public {
        HamsterVault fresh = new HamsterVault(TEAM, address(boost));
        MockToken wrong = new MockToken();
        vm.prank(TEAM);
        vm.expectRevert(VaultBase.InvalidAddress.selector);
        fresh.bindToken(IMD);
        wrong.mint(address(fresh), 800_000_000 ether);
        vm.prank(TEAM);
        vm.expectRevert(VaultBase.InvalidAmount.selector);
        fresh.bindToken(address(wrong));
        wrong.mint(alice, 200_000_000 ether);
        vm.expectRevert(VaultBase.NotTeam.selector);
        fresh.bindToken(address(wrong));
        wrong.burn(address(fresh), 1);
        wrong.mint(alice, 1);
        vm.prank(TEAM);
        vm.expectRevert(VaultBase.InvalidAmount.selector);
        fresh.bindToken(address(wrong));
        vm.prank(alice);
        wrong.transfer(address(fresh), 1);
        vm.mockCall(address(wrong), abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        vm.prank(TEAM);
        vm.expectRevert(VaultBase.InvalidAmount.selector);
        fresh.bindToken(address(wrong));
        vm.clearMockedCalls();
        vm.prank(TEAM);
        fresh.bindToken(address(wrong));
        assertEq(fresh.TEAM(), TEAM);
        vm.prank(TEAM);
        vm.expectRevert(VaultBase.AlreadyDone.selector);
        fresh.bindToken(address(wrong));
    }

    function test_rewardsCanWaitBeforeBindingButHamsterActionsCannot() public {
        HamsterVault fresh = new HamsterVault(TEAM, address(boost));
        imd.approve(address(fresh), 700 ether);
        fresh.depositRewards(700 ether);
        vm.warp(vm.getBlockTimestamp() + 10 days);
        assertEq(fresh.rewardState().clock, 0);
        vm.expectRevert(VaultBase.NotBound.selector);
        fresh.stake(1 ether);
        vm.expectRevert(VaultBase.NotBound.selector);
        fresh.claimMined(V2, one(0), alice);
        assertEq(fresh.rewardLiability(), 700 ether);
        assertEq(imd.balanceOf(address(fresh)), 700 ether);
    }

    function test_emptyChainConstructorsAndRuntimePolicy() public {
        _runtimePolicy(address(boost).code);
        vm.etch(IMD, "");
        vm.etch(V2, "");
        vm.etch(address(boost), "");
        HamsterVault fresh = new HamsterVault(TEAM, address(boost));
        assertEq(fresh.TEAM(), TEAM);
        assertEq(fresh.currentGame(), V2);
        _runtimePolicy(address(fresh).code);
    }

    function _runtimePolicy(bytes memory code) internal pure {
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
        }
    }
}

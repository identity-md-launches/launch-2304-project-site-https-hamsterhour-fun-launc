// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase, HamsterVault, HamsterStaking, VaultBase, MockGame} from "./helpers/VaultTestBase.sol";
import {MockNoReturnToken} from "./helpers/Mocks.sol";
import {VaultMath} from "../src/libraries/VaultMath.sol";

contract StakingTest is VaultTestBase {
    function test_automaticWarmupAndTimeProRata() public {
        uint256 start = vm.getBlockTimestamp();
        _stake(alice, 100 ether);
        vault.depositRewards(700 ether);
        vm.warp(start + 1 days - 1);
        assertEq(vault.pendingIMD(alice), 0);
        vm.warp(start + 1 days);
        _stake(bob, 100 ether);
        assertEq(vault.pendingIMD(alice), 0);
        vm.warp(start + 2 days);
        assertApproxEqAbs(vault.pendingIMD(alice), 100 ether, 1);
        assertEq(vault.pendingIMD(bob), 0);
        vm.warp(start + 3 days);
        assertApproxEqAbs(vault.pendingIMD(alice), 150 ether, 1);
        assertApproxEqAbs(vault.pendingIMD(bob), 50 ether, 1);
        vm.prank(carol);
        vault.claimRewards(alice);
        assertApproxEqAbs(imd.balanceOf(alice), 150 ether, 1);
        assertEq(imd.balanceOf(carol), 0);
        vault.claimRewards(bob);
        _conservation();
    }

    function test_vestingUnvestedAndVestedUnwithdrawnAreWeight() public {
        game.setLoss(0, alice, 1 ether);
        game.finalize(2);
        _claim(0, alice);
        _stake(bob, 20_000 ether);
        uint256 start = vm.getBlockTimestamp();
        vault.depositRewards(700 ether);
        vm.warp(start + 1 days);
        assertEq(vault.rewardState().weight, 40_000 ether);
        vm.warp(start + 4 days);
        assertApproxEqAbs(vault.pendingIMD(alice), 150 ether, 1);
        assertEq(vault.grantBalance(alice), 20_000 ether);
        uint256 due = vault.vested(alice, 0);
        uint256 before_ = hamster.balanceOf(alice);
        vm.prank(carol);
        vm.expectRevert(HamsterStaking.NotAccount.selector);
        vault.withdrawVested(alice, one(0));
        assertEq(vault.rewardState().weight, 40_000 ether);
        vm.prank(alice);
        assertEq(vault.withdrawVested(alice, one(0)), due);
        assertEq(hamster.balanceOf(alice), before_ + due);
        assertEq(vault.rewardState().weight, 40_000 ether - due);
        assertEq(vault.grantBalance(alice), 20_000 ether - due);
        vm.warp(start + 10 days);
        assertEq(vault.vested(alice, 0), 20_000 ether);
        vm.prank(alice);
        vault.withdrawVested(alice, one(0));
        assertEq(vault.grantBalance(alice), 0);
        assertEq(vault.rewardState().weight, 20_000 ether);
        vm.prank(alice);
        vm.expectRevert(VaultBase.InvalidAmount.selector);
        vault.withdrawVested(alice, one(0));
        _conservation();
    }

    function test_earlyVestingWithdrawalReducesOnlyItsWarmup() public {
        game.setLoss(0, alice, 1 ether);
        game.finalize(2);
        _claim(0, alice);
        _stake(alice, 100 ether);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 12 hours);
        vm.prank(alice);
        uint256 withdrawn = vault.withdrawVested(alice, one(0));
        assertEq(vault.rewardState().weight, 0);
        vm.warp(start + 1 days);
        assertEq(vault.rewardState().weight, 20_100 ether - withdrawn);
        vm.prank(alice);
        vm.expectRevert(HamsterStaking.WrongLot.selector);
        vault.requestUnstake(0, 1);
        _conservation();
    }

    function test_unstakeStopsWeightNowAndReleasesAfter24Hours() public {
        uint256 start = vm.getBlockTimestamp();
        uint256 lot = _stake(alice, 100 ether);
        vault.depositRewards(700 ether);
        vm.warp(start + 2 days);
        uint256 balanceBefore = hamster.balanceOf(alice);
        vm.prank(alice);
        uint256 request = vault.requestUnstake(lot, 100 ether);
        assertEq(vault.rewardState().weight, 0);
        assertEq(hamster.balanceOf(alice), balanceBefore);
        vm.warp(start + 3 days - 1);
        vm.expectRevert(VaultBase.NotReady.selector);
        vault.withdrawUnstaked(alice, one(request));
        vm.warp(start + 3 days);
        vm.prank(carol);
        vault.withdrawUnstaked(alice, one(request));
        assertEq(hamster.balanceOf(alice), balanceBefore + 100 ether);
        assertApproxEqAbs(vault.pendingIMD(alice), 100 ether, 1);
        vm.expectRevert(VaultBase.AlreadyDone.selector);
        vault.withdrawUnstaked(alice, one(request));
        _conservation();
    }

    function test_cancelWarmupAndPartialUnstake() public {
        uint256 start = vm.getBlockTimestamp();
        uint256 lot = _stake(alice, 100 ether);
        vm.warp(start + 12 hours);
        vm.prank(alice);
        vault.requestUnstake(lot, 60 ether);
        vm.warp(start + 1 days);
        assertEq(vault.rewardState().weight, 40 ether);
        vm.prank(alice);
        vault.requestUnstake(lot, 40 ether);
        assertEq(vault.rewardState().weight, 0);
        vm.warp(start + 2 days);
        vault.withdrawUnstaked(alice, pair(0, 1));
        assertEq(vault.totalUnstakeQueued(), 0);
        _conservation();
    }

    function test_zeroWeightPausesClockAndNoBacklogWindfall() public {
        vault.depositRewards(700 ether);
        vault.depositDrip(10_000 ether);
        game.credit(address(vault), 300 ether);
        vault.pullGameRewards(V2);
        vm.warp(vm.getBlockTimestamp() + 100 days);
        assertEq(vault.rewardState().clock, 0);
        _stake(alice, 100 ether);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        assertEq(vault.pendingIMD(alice), 0);
        assertEq(vault.rewardState().clock, 0);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 earned = vault.pendingIMD(alice);
        // 100 hook + 10 game + ~99.5016625083 continuous drip.
        assertApproxEqAbs(earned, 209_501662508319464260, 1000);
        vault.claimRewards(alice);
        vm.prank(alice);
        vault.requestUnstake(0, 100 ether);
        uint256 clockBefore = vault.rewardState().clock;
        vm.warp(vm.getBlockTimestamp() + 100 days);
        _stake(bob, 100 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(vault.rewardState().clock, clockBefore);
        assertEq(vault.pendingIMD(bob), 0);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertGt(vault.pendingIMD(bob), 200 ether);
        assertLt(vault.pendingIMD(bob), 210 ether);
        _conservation();
    }

    function test_topupsDoNotRestartExistingSevenDayStream() public {
        _stake(alice, 1 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 start = vm.getBlockTimestamp();
        vault.depositRewards(700 ether);
        vm.warp(start + 3 days);
        vault.depositRewards(70 ether);
        vm.warp(start + 7 days);
        assertApproxEqAbs(vault.pendingIMD(alice), 740 ether, 1);
        vm.warp(start + 10 days);
        assertApproxEqAbs(vault.pendingIMD(alice), 770 ether, 1);
        vault.claimRewards(alice);
        assertLe(vault.rewardLiability(), 1);
        _conservation();
    }

    function test_gameBacklogIsThirtyDayStreamAndOldGameRemainsPullable() public {
        game.credit(address(vault), 300 ether);
        vault.pullGameRewards(V2);
        _stake(alice, 1 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 15 days);
        assertApproxEqAbs(vault.pendingIMD(alice), 150 ether, 1);
        vm.warp(start + 30 days);
        assertEq(vault.pendingIMD(alice), 300 ether);
        MockGame next = new MockGame(GENESIS);
        _switch(next);
        game.credit(address(vault), 30 ether);
        assertEq(vault.pullGameRewards(V2), 30 ether);
        next.credit(address(vault), 60 ether);
        vault.pullGameRewards(address(next));
        vm.warp(vm.getBlockTimestamp() + 30 days);
        assertEq(vault.pendingIMD(alice), 390 ether);
        _conservation();
    }

    function test_continuousDripAnchoredAndCheckpointFrequencyIndependent() public {
        _stake(alice, 1 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vault.depositDrip(10_000 ether);
        uint256 start = vm.getBlockTimestamp();
        uint256 snapshot = vm.snapshotState();
        vm.warp(start + 1 days);
        uint256 once = vault.pendingIMD(alice);
        assertApproxEqAbs(once, 99_501662508319464260, 1000);
        assertTrue(vm.revertToStateAndDelete(snapshot));
        for (uint256 i = 1; i <= 24; ++i) {
            vm.warp(start + i * 1 hours);
            vault.checkpoint(128);
        }
        assertEq(vault.pendingIMD(alice), once);
        vault.depositDrip(10_000 ether);
        vm.warp(start + 2 days);
        uint256 twice = vault.pendingIMD(alice);
        assertGt(twice - once, 198 ether);
        assertLt(twice - once, 199 ether);
        vault.claimRewards(alice);
        _conservation();
    }

    function testFuzz_dripDecayBoundedAndMonotone(uint32 elapsed) public pure {
        uint256 a = VaultMath.decay(elapsed);
        uint256 b = VaultMath.decay(uint256(elapsed) + 1 days);
        assertLe(a, 1e27);
        assertLe(b, a);
    }

    function test_claimFrequencyCannotFarmRounding() public {
        _stake(alice, 3 ether);
        _stake(bob, 7 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vault.depositRewards(7 ether);
        uint256 start = vm.getBlockTimestamp();
        uint256 snapshot = vm.snapshotState();
        vm.warp(start + 7 days);
        uint256 once = vault.pendingIMD(alice);
        assertTrue(vm.revertToStateAndDelete(snapshot));
        for (uint256 i = 1; i <= 7; ++i) {
            vm.warp(start + i * 1 days);
            vault.claimRewards(alice);
        }
        assertLe(imd.balanceOf(alice), once);
        assertApproxEqAbs(imd.balanceOf(alice), once, 1);
        _conservation();
    }

    function test_boundedCheckpointRecoversAfterManyActivations() public {
        for (uint256 i; i < 140; ++i) {
            _stake(alice, 1 ether);
            vm.warp(vm.getBlockTimestamp() + 1 seconds);
        }
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.expectRevert(HamsterStaking.CheckpointRequired.selector);
        vault.pendingIMD(alice);
        vm.prank(alice);
        vm.expectRevert(HamsterStaking.CheckpointRequired.selector);
        vault.requestUnstake(0, 1 ether);
        assertFalse(vault.checkpoint(64));
        assertFalse(vault.checkpoint(64));
        assertTrue(vault.checkpoint(64));
        assertFalse(vault.checkpointAccount(alice, 64));
        assertFalse(vault.checkpointAccount(alice, 64));
        assertTrue(vault.checkpointAccount(alice, 64));
        assertEq(vault.rewardState().weight, 140 ether);
        vm.prank(alice);
        vault.requestUnstake(0, 1 ether);
        assertEq(vault.rewardState().weight, 139 ether);
        _conservation();
    }

    function test_transferFailuresAndReentrancyRollBackAccounting() public {
        imd.setFalse(true);
        vm.expectRevert(VaultBase.TransferFailed.selector);
        vault.depositRewards(100 ether);
        assertEq(vault.hookDeposited(), 0);
        imd.setFalse(false);
        imd.setFee(100);
        vm.expectRevert(VaultBase.TransferFailed.selector);
        vault.depositDrip(100 ether);
        assertEq(vault.dripDeposited(), 0);
        imd.setFee(0);
        imd.setCallback(address(vault), abi.encodeCall(vault.depositRewards, (1)));
        vm.expectRevert(VaultBase.TransferFailed.selector);
        vault.depositRewards(100 ether);
        assertEq(vault.hookDeposited(), 0);
        imd.setCallback(address(0), "");
        _stake(alice, 100 ether);
        hamster.setFee(100);
        vm.prank(alice);
        vm.expectRevert(VaultBase.TransferFailed.selector);
        vault.stake(100 ether);
        assertEq(vault.stakedBalance(alice), 100 ether);
        _conservation();
    }

    function test_outgoingRewardReentrancyCannotConsumeCredit() public {
        _stake(alice, 100 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vault.depositRewards(700 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 due = vault.pendingIMD(alice);
        imd.setCallback(address(vault), abi.encodeCall(vault.claimRewards, (alice)));
        vm.expectRevert(VaultBase.TransferFailed.selector);
        vault.claimRewards(alice);
        assertEq(vault.pendingIMD(alice), due);
        assertEq(vault.rewardsPaid(), 0);
        imd.setCallback(address(0), "");
        assertEq(vault.claimRewards(alice), due);
        _conservation();
    }

    function test_optionalERC20ReturnValuesSupported() public {
        HamsterVault fresh = new HamsterVault(TEAM, address(boost));
        MockNoReturnToken optional = new MockNoReturnToken();
        optional.mint(address(fresh), 800_000_000 ether);
        optional.mint(alice, 200_000_000 ether);
        vm.prank(TEAM);
        fresh.bindToken(address(optional));
        vm.startPrank(alice);
        optional.approve(address(fresh), 100 ether);
        uint256 lot = fresh.stake(100 ether);
        fresh.requestUnstake(lot, 100 ether);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        fresh.withdrawUnstaked(alice, one(0));
        assertEq(optional.balanceOf(alice), 200_000_000 ether);
        assertEq(optional.balanceOf(address(fresh)), fresh.hamsterLiability());
    }

    function testFuzz_unattendedActivationsMatchFrequentCheckpoints(uint64 a, uint64 b, uint32 duration) public {
        uint256 amountA = bound(uint256(a), 1 ether, 10 ether);
        uint256 amountB = bound(uint256(b), 1 ether, 10 ether);
        uint256 elapsed = bound(uint256(duration), 3 days, 10 days);
        _stake(alice, amountA);
        vault.depositRewards(700 ether);
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        _stake(bob, amountB);
        uint256 start = vm.getBlockTimestamp();
        uint256 snapshot = vm.snapshotState();
        vm.warp(start + elapsed);
        uint256 expectedA = vault.pendingIMD(alice);
        uint256 expectedB = vault.pendingIMD(bob);
        assertTrue(vm.revertToStateAndDelete(snapshot));
        for (uint256 i = 1; i <= 20; ++i) {
            vm.warp(start + elapsed * i / 20);
            vault.checkpointAccount(alice, 128);
            vault.checkpointAccount(bob, 128);
        }
        assertApproxEqAbs(vault.pendingIMD(alice), expectedA, 2);
        assertApproxEqAbs(vault.pendingIMD(bob), expectedB, 2);
        vault.claimRewards(alice);
        vault.claimRewards(bob);
        _conservation();
    }

    function test_hookDepositsNeverRevertForMaintenanceAndConserveFunds() public {
        _stake(alice, 1 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        // A burst of hook deposits at distinct seconds creates more than 128 stream ends.
        for (uint256 i; i < 140; ++i) {
            vault.depositRewards(1 ether);
            vm.warp(vm.getBlockTimestamp() + 12 seconds);
        }
        // All of them mature during a quiet week; the next hook deposit must still succeed.
        vm.warp(vm.getBlockTimestamp() + 7 days + 1 hours);
        vm.expectRevert(HamsterStaking.CheckpointRequired.selector);
        vault.pendingIMD(alice);
        vault.depositRewards(1 ether);
        vault.depositDrip(2 ether);
        while (!vault.checkpoint(128)) {}
        vm.warp(vm.getBlockTimestamp() + 8 days);
        assertTrue(vault.checkpoint(128));
        // The burst and the late stream were fully distributed to the only staker.
        assertApproxEqAbs(vault.pendingIMD(alice), 141 ether + vault.rewardState().dripEmitted, 141);
        vault.claimRewards(alice);
        _conservation();
    }
}

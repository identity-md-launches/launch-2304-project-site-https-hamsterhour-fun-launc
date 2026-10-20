// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase, VaultBase, HamsterMining, MockGame} from "./helpers/VaultTestBase.sol";

contract ForwardingTest is VaultTestBase {
    function test_queuedFundsFollowCurrentGameAfterSwitch() public {
        vault.forwardJackpot(100 ether);
        vault.forwardOracle(200 ether);
        vault.depositRewards(70 ether);
        vault.depositDrip(80 ether);
        assertEq(vault.jackpotPending(), 100 ether);
        assertEq(vault.oraclePending(), 200 ether);
        MockGame next = new MockGame(GENESIS);
        _switch(next);
        vm.prank(carol);
        vault.flushJackpot(100 ether);
        vm.prank(alice);
        vault.flushOracle(200 ether);
        assertEq(game.jackpot(), 0);
        assertEq(game.oracle(), 0);
        assertEq(next.jackpot(), 100 ether);
        assertEq(next.oracle(), 200 ether);
        assertEq(imd.allowance(address(vault), address(next)), 0);
        assertEq(vault.rewardLiability(), 150 ether);
        _conservation();
    }

    function test_partialFlushKeepsBucketsSeparate() public {
        vault.forwardJackpot(100 ether);
        vault.forwardOracle(20 ether);
        vault.flushJackpot(40 ether);
        assertEq(vault.jackpotPending(), 60 ether);
        assertEq(vault.oraclePending(), 20 ether);
        vm.expectRevert(VaultBase.InvalidAmount.selector);
        vault.flushOracle(21 ether);
        vm.expectRevert(VaultBase.InvalidAmount.selector);
        vault.flushJackpot(61 ether);
        vm.expectRevert(VaultBase.InvalidAmount.selector);
        vault.forwardOracle(0);
        _conservation();
    }

    function test_failedGameFlushRollsBackAndCannotSpendRewards() public {
        vault.forwardJackpot(100 ether);
        vault.depositRewards(700 ether);
        game.setFail(true);
        vm.expectRevert(bytes("game failure"));
        vault.flushJackpot(100 ether);
        assertEq(vault.jackpotPending(), 100 ether);
        assertEq(imd.allowance(address(vault), V2), 0);
        game.setFail(false);
        vault.flushJackpot(100 ether);
        assertEq(vault.rewardLiability(), 700 ether);
        _conservation();
    }

    function test_gamePullChecksRegistrationAndReceivedAmount() public {
        MockGame unknown = new MockGame(GENESIS);
        vm.expectRevert(HamsterMining.UnknownGame.selector);
        vault.pullGameRewards(address(unknown));
        game.credit(address(vault), 100 ether);
        imd.setFee(100);
        vm.expectRevert(VaultBase.TransferFailed.selector);
        vault.pullGameRewards(V2);
        assertEq(game.balances(address(vault)), 100 ether);
        assertEq(vault.gameDeposited(), 0);
        imd.setFee(0);
        assertEq(vault.pullGameRewards(V2), 100 ether);
        vm.expectRevert(VaultBase.InvalidAmount.selector);
        vault.pullGameRewards(V2);
        _conservation();
    }

    function test_gameReturningSuccessWithoutPullingCannotClearForwardingBalance() public {
        vault.forwardJackpot(100 ether);
        vm.mockCall(V2, abi.encodeWithSignature("depositJackpot(uint256)", 100 ether), "");
        vm.expectRevert(VaultBase.TransferFailed.selector);
        vault.flushJackpot(100 ether);
        assertEq(vault.jackpotPending(), 100 ether);
        assertEq(imd.allowance(address(vault), V2), 0);
        vm.clearMockedCalls();
        vault.flushJackpot(100 ether);
        _conservation();
    }
}

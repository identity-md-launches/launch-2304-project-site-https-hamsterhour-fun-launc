// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase, MockGame} from "./helpers/VaultTestBase.sol";
import {HamsterHour} from "./reference/HamsterHour.sol";
import {OracleAttestation} from "./reference/OracleAttestation.sol";

/// @notice Offline integration against the actual, unmodified v2 source, including its real
/// settlement/signature, loss-history, staking-recipient and forwarding ABIs.
contract V2IntegrationTest is VaultTestBase {
    HamsterHour internal original;
    address internal testAttester;
    uint256 internal testAttesterKey;

    function setUp() public override {
        super.setUp();
        (testAttester, testAttesterKey) = makeAddrAndKey("offline oracle fixture");
        HamsterHour implementation = new HamsterHour(TEAM, testAttester, makeAddr("offline intake fixture"));
        vm.etch(V2, address(implementation).code);
        vm.copyStorage(address(implementation), V2);
        original = HamsterHour(V2);
        imd.mint(alice, 100 ether);
        imd.mint(bob, 100 ether);
        vm.prank(alice);
        imd.approve(V2, type(uint256).max);
        vm.prank(bob);
        imd.approve(V2, type(uint256).max);
    }

    function _settle(uint256 k, uint256 result) internal {
        OracleAttestation.Attestation memory a;
        a.requestId = keccak256(abi.encode("offline fixture", k));
        a.chainId = 1;
        a.fromBlock = 100;
        a.toBlock = 200;
        a.questionHash = original.questionHash(k, a.fromBlock, a.toBlock);
        a.answerType = 3;
        a.answer = abi.encode(result);
        a.figure = result;
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 5;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = uint64(vm.getBlockTimestamp() + 1 hours);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(testAttesterKey, original.attestationDigest(a));
        original.settle(k, a, abi.encodePacked(r, s, v));
    }

    function test_actualV2RetroactiveMiningRecipientBacklogAndForwarding() public {
        vm.warp(uint256(GENESIS) - 1 hours);
        vm.prank(alice);
        original.betOverUnder(0, true, 10 ether);
        vm.prank(bob);
        original.betOverUnder(0, false, 10 ether);
        vm.warp(uint256(GENESIS) + 2 hours);
        _settle(0, 3000);
        original.finalize(2);
        assertEq(original.lossOf(0, bob), 10 ether);
        assertEq(original.totalEligibleLoss(0), 10 ether);
        assertEq(_claim(0, bob), 200_000 ether);
        vm.prank(alice);
        original.claim(0);
        assertEq(original.lossOf(0, alice), 0);
        assertEq(original.pendingStakingFees(), 1 ether);
        vm.prank(TEAM);
        original.scheduleStakingRecipient(address(vault));
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        vm.prank(TEAM);
        original.executeStakingRecipient(address(vault));
        assertEq(original.balances(address(vault)), 1 ether);
        assertEq(vault.pullGameRewards(V2), 1 ether);
        assertEq(original.balances(address(vault)), 0);
        vault.forwardJackpot(10 ether);
        uint256 destination = original.earliestNotStartedWindow();
        vault.flushJackpot(10 ether);
        assertEq(original.pendingJackpotDeposits(destination), 10 ether);
        uint256 reserveBefore = original.oracleReserve();
        vault.forwardOracle(5 ether);
        vault.flushOracle(5 ether);
        assertEq(original.oracleReserve(), reserveBefore + 5 ether);
        _conservation();
    }

    function test_actualV2CrossMarketNettingRetainsUnclaimableRemainder() public {
        vm.warp(uint256(GENESIS) - 1 hours);
        vm.startPrank(alice);
        original.betOverUnder(0, false, 10 ether);
        original.betSnooze(0, false, 10 ether);
        vm.stopPrank();
        vm.startPrank(bob);
        original.betOverUnder(0, true, 10 ether);
        original.betSnooze(0, true, 10 ether);
        vm.stopPrank();
        vm.warp(uint256(GENESIS) + 2 hours);
        _settle(0, 3000);
        original.finalize(2);
        assertEq(original.totalEligibleLoss(0), 20 ether);
        assertEq(original.lossOf(0, alice), 1.8 ether);
        assertEq(original.lossOf(0, bob), 1.8 ether);
        assertEq(_claim(0, alice), 36_000 ether);
        assertEq(_claim(0, bob), 36_000 ether);
        (, uint256 reserved,,) = vault.bucketsLeft();
        assertEq(reserved, 328_000 ether);
        _conservation();
    }

    function test_actualV2InterfaceAcceptedWithoutMovingFundsOnSchedule() public {
        HamsterHour next = new HamsterHour(TEAM, testAttester, makeAddr("offline successor intake"));
        vm.prank(TEAM);
        vault.scheduleGame(address(next));
        assertEq(vault.currentGame(), V2);
        assertEq(next.nextFinalizeWindow(), 0);
        assertEq(next.oracleReserve(), 0);
        assertEq(next.totalPendingJackpotDeposits(), 0);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vault.executeGame();
        original.finalize(100);
        next.finalize(100);
        vault.resolveGame(address(next));
        vault.forwardOracle(1 ether);
        vault.flushOracle(1 ether);
        assertEq(next.oracleReserve(), 1 ether);
        _conservation();
    }
}

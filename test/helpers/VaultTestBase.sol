// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HamsterVault} from "../../src/HamsterVault.sol";
import {HamsterBoost} from "../../src/HamsterBoost.sol";
import {HamsterMining} from "../../src/HamsterMining.sol";
import {HamsterStaking} from "../../src/HamsterStaking.sol";
import {VaultBase} from "../../src/VaultBase.sol";
import {MockToken, MockGame, MockNFT} from "./Mocks.sol";

abstract contract VaultTestBase is Test {
    address internal constant TEAM = address(bytes20(hex"6cba4751742f6989fa224b2dc5d5d52fcef98a34"));
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant V2 = 0xe33AB493249a2Df0D8c4a71aC54F46d1F7778367;
    uint64 internal constant GENESIS = 1791847200;
    HamsterVault internal vault;
    HamsterBoost internal boost;
    MockToken internal hamster;
    MockToken internal imd;
    MockGame internal game;
    address internal alice;
    address internal bob;
    address internal carol;

    function setUp() public virtual {
        vm.chainId(1);
        vm.warp(uint256(GENESIS) + 2 hours);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        MockToken tokenTemplate = new MockToken();
        vm.etch(IMD, address(tokenTemplate).code);
        imd = MockToken(IMD);
        MockGame gameTemplate = new MockGame(GENESIS);
        vm.etch(V2, address(gameTemplate).code);
        game = MockGame(V2);
        boost = new HamsterBoost();
        vault = new HamsterVault(TEAM, address(boost));
        hamster = new MockToken();
        hamster.mint(address(vault), 800_000_000 ether);
        hamster.mint(alice, 100_000_000 ether);
        hamster.mint(bob, 100_000_000 ether);
        vm.prank(TEAM);
        vault.bindToken(address(hamster));
        imd.mint(address(this), 1_000_000 ether);
        imd.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        hamster.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        hamster.approve(address(vault), type(uint256).max);
    }

    function one(uint256 x) internal pure returns (uint256[] memory xs) {
        xs = new uint256[](1);
        xs[0] = x;
    }

    function pair(uint256 a, uint256 b) internal pure returns (uint256[] memory xs) {
        xs = new uint256[](2);
        xs[0] = a;
        xs[1] = b;
    }

    function _claim(uint256 k, address account) internal returns (uint256) {
        return vault.claimMined(V2, one(k), account);
    }

    function _stake(address who, uint256 amount) internal returns (uint256 lot) {
        vm.prank(who);
        lot = vault.stake(amount);
    }

    function _switch(MockGame successor) internal returns (uint256 switchedAt) {
        vm.prank(TEAM);
        vault.scheduleGame(address(successor));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vault.executeGame();
        return vm.getBlockTimestamp();
    }

    function _resolve(MockGame successor) internal {
        game.finalize(20_000);
        successor.finalize(20_000);
        vault.resolveGame(address(successor));
    }

    function _conservation() internal view {
        assertEq(hamster.balanceOf(address(vault)), vault.hamsterLiability(), "HAMSTER conservation");
        assertEq(imd.balanceOf(address(vault)), vault.imdLiability(), "IMD conservation");
        assertLe(vault.miningGranted(), vault.miningCommitted());
        assertLe(vault.miningCommitted(), vault.miningAllocation());
        HamsterBoost.State memory s = boost.status(address(vault));
        assertLe(s.granted, s.committed);
        assertLe(s.committed, vault.BOOST_ALLOCATION());
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase, HamsterBoost, VaultBase, MockNFT, MockGame} from "./helpers/VaultTestBase.sol";

contract BoostTest is VaultTestBase {
    MockNFT internal nft;

    function _activate() internal {
        nft = new MockNFT();
        vm.prank(TEAM);
        vault.activateBoost(address(nft));
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        vault.executeBoost();
    }

    function _register(address who, uint256 id) internal returns (uint256 registration) {
        nft.mint(who, id);
        vm.prank(who);
        registration = vault.registerNFT(id);
        assertEq(nft.ownerOf(id), who);
    }

    function _dayAndWindow() internal view returns (uint256 day, uint256 k) {
        day = (vm.getBlockTimestamp() + 24 hours) / 1 days + 1;
        k = (day * 1 days - GENESIS + 1 hours - 1) / 1 hours;
    }

    function _prepareThrough(uint256 day) internal {
        while (boost.status(address(vault)).nextDay <= day) vault.prepareBoostDay(8);
    }

    function test_activationTimelockAuthorizationMainnetAndOneShot() public {
        nft = new MockNFT();
        vm.expectRevert(VaultBase.NotTeam.selector);
        vault.activateBoost(address(nft));
        vm.chainId(11155111);
        vm.prank(TEAM);
        vm.expectRevert(HamsterBoost.InvalidCollection.selector);
        vault.activateBoost(address(nft));
        vm.chainId(1);
        vm.prank(TEAM);
        vault.activateBoost(address(nft));
        vm.warp(vm.getBlockTimestamp() + 12 hours - 1);
        vm.expectRevert(HamsterBoost.NotReady.selector);
        vault.executeBoost();
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(carol);
        vault.executeBoost();
        assertEq(boost.status(address(vault)).collection, address(nft));
        vm.prank(TEAM);
        vm.expectRevert(HamsterBoost.AlreadyDone.selector);
        vault.activateBoost(address(nft));
    }

    function test_registerRequiresOwnershipAnd24HourLead() public {
        _activate();
        uint256 id = _register(alice, 7);
        vm.prank(bob);
        vm.expectRevert(HamsterBoost.IneligibleNFT.selector);
        vault.registerNFT(7);
        vm.prank(alice);
        vm.expectRevert(HamsterBoost.AlreadyDone.selector);
        vault.registerNFT(7);
        uint256 eligible = vm.getBlockTimestamp() + 24 hours;
        uint256 firstEligible = (eligible - GENESIS + 1 hours - 1) / 1 hours;
        game.setLoss(firstEligible - 1, alice, 1 ether);
        game.setLoss(firstEligible, alice, 0.5 ether);
        uint256 day = (uint256(GENESIS) + firstEligible * 1 hours) / 1 days;
        vm.warp((day + 1) * 1 days + 1 hours);
        game.finalize(1000);
        _prepareThrough(day);
        assertEq(boost.claimable(address(vault), day, id), 5_000 ether);
        vm.prank(carol);
        assertEq(vault.claimBoost(day, id), 5_000 ether);
        assertEq(vault.grantBalance(alice), 5_000 ether);
        assertEq(vault.grantBalance(carol), 0);
        assertEq(nft.ownerOf(7), alice);
        vm.expectRevert(HamsterBoost.AlreadyDone.selector);
        vault.claimBoost(day, id);
        _conservation();
    }

    function test_nftCapAppliesAcrossAllWindowsAndResetsNextUtcDay() public {
        _activate();
        uint256 id = _register(alice, 7);
        (uint256 day, uint256 k) = _dayAndWindow();
        game.setLoss(k, alice, 10 ether);
        game.setLoss(k + 1, alice, 10 ether);
        game.setLoss(k + 24, alice, 10 ether);
        vm.warp((day + 2) * 1 days + 1 hours);
        game.finalize(1000);
        _prepareThrough(day + 1);
        assertEq(vault.claimBoost(day + 1, id), 10_000 ether);
        assertEq(vault.claimBoost(day, id), 10_000 ether);
        assertEq(boost.status(address(vault)).granted, 20_000 ether);
        _conservation();
    }

    function test_globalDailyCapOrderIndependenceAndBoundedPreparation() public {
        _activate();
        address[] memory holders = new address[](11);
        (uint256 day, uint256 k) = _dayAndWindow();
        for (uint256 i; i < 11; ++i) {
            holders[i] = makeAddr(string.concat("holder", vm.toString(i)));
            _register(holders[i], i + 100);
            game.setLoss(k, holders[i], 1 ether);
        }
        vm.warp((day + 1) * 1 days + 1 hours);
        game.finalize(1000);
        vm.expectRevert(HamsterBoost.TooMany.selector);
        vault.prepareBoostDay(9);
        _prepareThrough(day);
        uint256 expected = uint256(100_000 ether) / 11;
        uint256 snapshot = vm.snapshotState();
        for (uint256 i; i < 11; ++i) {
            assertEq(vault.claimBoost(day, i), expected);
            assertEq(vault.grantBalance(holders[i]), expected);
        }
        assertLe(boost.status(address(vault)).granted, 100_000 ether);
        _conservation();
        assertTrue(vm.revertToStateAndDelete(snapshot));
        for (uint256 i = 11; i != 0; --i) {
            assertEq(vault.claimBoost(day, i - 1), expected);
        }
        _conservation();
    }

    function test_ownerChangeVoidsBeforeAndAfterPreparation() public {
        _activate();
        uint256 a = _register(alice, 1);
        uint256 b = _register(bob, 2);
        (uint256 day, uint256 k) = _dayAndWindow();
        game.setLoss(k, alice, 1 ether);
        game.setLoss(k, bob, 1 ether);
        nft.move(1, carol);
        vm.warp((day + 1) * 1 days + 1 hours);
        game.finalize(1000);
        _prepareThrough(day);
        assertEq(boost.claimable(address(vault), day, a), 0);
        assertEq(boost.claimable(address(vault), day, b), 10_000 ether);
        nft.move(2, carol);
        assertEq(boost.claimable(address(vault), day, b), 0);
        vault.invalidateRegistration(b);
        nft.move(2, bob);
        assertFalse(boost.validRegistration(address(vault), b));
        vm.expectRevert(HamsterBoost.InvalidAmount.selector);
        vault.claimBoost(day, b);
        // Voided NFT entitlement never affects the underlying mining entitlement.
        assertEq(_claim(k, alice), 20_000 ether);
        assertEq(_claim(k, bob), 20_000 ether);
        _conservation();
    }

    function test_newOwnerRegistersAgainWithFreshWarmup() public {
        _activate();
        _register(alice, 1);
        nft.move(1, bob);
        vm.prank(bob);
        uint256 id = vault.registerNFT(1);
        assertEq(id, 1);
        assertFalse(boost.validRegistration(address(vault), 0));
        (, uint64 at,,) = boost.registrations(address(vault), id);
        assertEq(uint256(at), vm.getBlockTimestamp() + 24 hours);
        assertEq(boost.registrationCount(address(vault)), 2);
        assertEq(boost.registeredTokenCount(address(vault)), 1);
    }

    function test_multipleNFTsShareFiftyPercentAndNoCompanionNamespaceBypass() public {
        _activate();
        uint256 old = _register(alice, 1);
        uint256 current = _register(alice, 2);
        assertTrue(boost.validRegistration(address(vault), old));
        assertTrue(boost.validRegistration(address(vault), current));
        vm.expectRevert();
        boost.invalidate(current);
        assertTrue(boost.validRegistration(address(vault), current));
        vm.expectRevert();
        boost.register(alice, 2);
        (uint256 day, uint256 k) = _dayAndWindow();
        game.setLoss(k, alice, 1 ether);
        vm.warp((day + 1) * 1 days + 1 hours);
        game.finalize(1000);
        _prepareThrough(day);
        assertEq(boost.claimable(address(vault), day, old), 5_000 ether);
        assertEq(vault.claimBoost(day, current), 5_000 ether);
        assertEq(vault.claimBoost(day, old), 5_000 ether);
        assertEq(boost.status(address(vault)).granted, 10_000 ether);
        _conservation();
    }

    function test_multipleNFTsIncreaseDailyCapCapacity() public {
        _activate();
        uint256 a = _register(alice, 1);
        uint256 b = _register(alice, 2);
        (uint256 day, uint256 k) = _dayAndWindow();
        game.setLoss(k, alice, 10 ether);
        vm.warp((day + 1) * 1 days + 1 hours);
        game.finalize(1000);
        _prepareThrough(day);
        assertEq(vault.claimBoost(day, a), 10_000 ether);
        assertEq(vault.claimBoost(day, b), 10_000 ether);
        assertEq(vault.grantBalance(alice), 20_000 ether);
        _conservation();
    }

    function test_globalBoostCapSpansOldAndNewGameOnSwitchDay() public {
        _activate();
        address[] memory holders = new address[](11);
        for (uint256 i; i < 11; ++i) {
            holders[i] = makeAddr(string.concat("crossGame", vm.toString(i)));
            _register(holders[i], i + 100);
        }
        // Switch at noon, giving both games windows that start on the same UTC day.
        vm.warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 12 hours);
        MockGame next = new MockGame(GENESIS);
        uint256 switchedAt = _switch(next);
        uint256 first = (switchedAt - GENESIS + 1 hours - 1) / 1 hours;
        for (uint256 i; i < 11; ++i) {
            if (i < 6) game.setLoss(first - 1, holders[i], 1 ether);
            else next.setLoss(first, holders[i], 1 ether);
        }
        uint256 day = switchedAt / 1 days;
        vm.warp((day + 1) * 1 days + 1 hours);
        _resolve(next);
        _prepareThrough(day);
        for (uint256 i; i < 11; ++i) {
            assertEq(vault.claimBoost(day, i), uint256(100_000 ether) / 11);
        }
        assertLe(boost.status(address(vault)).granted, 100_000 ether);
        _conservation();
    }

    function test_365DaySweepOnceAndCannotActivateAfterwards() public {
        game.setLoss(0, alice, 1 ether);
        game.finalize(2);
        _claim(0, alice);
        vm.warp(vault.deployedAt() + 365 days - 1);
        vm.expectRevert(HamsterBoost.NotReady.selector);
        vault.sweepDormantBoost();
        vm.warp(vault.deployedAt() + 365 days);
        vm.prank(carol);
        vault.sweepDormantBoost();
        assertEq(vault.miningAllocation(), 800_000_000 ether);
        (uint256 freeMining, uint256 reserve, uint256 freeBoost, uint256 boostReserve) = vault.bucketsLeft();
        assertEq(freeMining + reserve + vault.miningGranted(), 800_000_000 ether);
        assertEq(freeBoost + boostReserve, 0);
        assertEq(vault.emissionCurve(18_750 ether), 375_000_000 ether);
        vm.expectRevert(HamsterBoost.AlreadyDone.selector);
        vault.sweepDormantBoost();
        nft = new MockNFT();
        vm.prank(TEAM);
        vm.expectRevert(HamsterBoost.AlreadyDone.selector);
        vault.activateBoost(address(nft));
        _conservation();
    }

    function test_pendingUnexecutedActivationCannotBlock365DaySweep() public {
        nft = new MockNFT();
        vm.prank(TEAM);
        vault.activateBoost(address(nft));
        vm.warp(vault.deployedAt() + 365 days);
        vm.expectRevert(HamsterBoost.NotReady.selector);
        vault.executeBoost();
        vault.sweepDormantBoost();
        assertTrue(boost.status(address(vault)).swept);
    }

    function test_activatedCollectionPreventsSweep() public {
        _activate();
        vm.warp(vault.deployedAt() + 365 days);
        vm.expectRevert(HamsterBoost.AlreadyDone.selector);
        vault.sweepDormantBoost();
    }
}

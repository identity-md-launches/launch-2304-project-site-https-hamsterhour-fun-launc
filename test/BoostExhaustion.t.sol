// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HamsterBoost, IMiningView} from "../src/HamsterBoost.sol";
import {MockNFT} from "./helpers/Mocks.sol";

/// @dev Narrow, noncustodial mining-view fixture. It presents one funded window per day so
/// the production boost engine's full 50M reservation history can be tested economically.
contract BoostLimitFixture {
    HamsterBoost public immutable engine;
    uint256 public immutable deployedAt;
    uint256 public day;
    uint256 public budget;

    constructor(HamsterBoost engine_) {
        engine = engine_;
        deployedAt = block.timestamp;
    }

    function setup(address nft) external {
        engine.schedule(nft);
    }

    function execute() external {
        engine.execute();
    }

    function register(address who, uint256 id) external {
        engine.register(who, id);
    }

    function setDay(uint256 day_, uint256 budget_) external {
        day = day_;
        budget = budget_;
    }

    function prepare() external {
        engine.prepare(8);
    }

    function claim(uint256 d, uint256 id) external returns (address, uint256) {
        return engine.claim(d, id);
    }

    function gameAtTime(uint256) external pure returns (uint256) {
        return 0;
    }

    function gameCount() external pure returns (uint256) {
        return 1;
    }

    function gameList(uint256) external view returns (address) {
        return address(this);
    }

    function games(address) external view returns (IMiningView.GameData memory) {
        return IMiningView.GameData(true, true, uint64(day * 1 days), 0, 0, 1, 0, 0, address(0));
    }

    function windowBudget(address, uint256) external view returns (uint256, uint256) {
        return (budget, 10 ether);
    }

    function lossOf(uint256, address) external pure returns (uint256) {
        return 1 ether;
    }
}

contract BoostExhaustionTest is Test {
    function test_full50MBucketFinalPartialDayAndNoClaimOrderRace() public {
        vm.chainId(1);
        vm.warp(1791847200);
        HamsterBoost engine = new HamsterBoost();
        BoostLimitFixture fixture = new BoostLimitFixture(engine);
        MockNFT nft = new MockNFT();
        fixture.setup(address(nft));
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        fixture.execute();
        for (uint256 i; i < 10; ++i) {
            address holder = makeAddr(string.concat("limit holder", vm.toString(i)));
            nft.mint(holder, i);
            fixture.register(holder, i);
        }
        // Finish the initial partial day without funded windows.
        uint256 initial = engine.status(address(fixture)).nextDay;
        fixture.setDay(initial, 0);
        vm.warp((initial + 1) * 1 days + 1 hours);
        while (engine.status(address(fixture)).nextDay == initial) fixture.prepare();
        uint256 first = initial + 1;
        for (uint256 i; i < 502; ++i) {
            uint256 day = first + i;
            // Day 0 reserves 50k. Days 1..499 reserve 49.9M. Day 500 has only 50k left.
            fixture.setDay(day, i == 0 ? 100_000 ether : 200_000 ether);
            vm.warp((day + 1) * 1 days + 1 hours);
            while (engine.status(address(fixture)).nextDay == day) fixture.prepare();
        }
        assertEq(engine.status(address(fixture)).committed, 50_000_000 ether);
        assertEq(engine.claimable(address(fixture), first + 500, 0), 5_000 ether);
        assertEq(engine.claimable(address(fixture), first + 501, 0), 0);
        (, uint256 last) = fixture.claim(first + 500, 0);
        (, uint256 early) = fixture.claim(first, 0);
        (, uint256 middle) = fixture.claim(first + 100, 0);
        assertEq(last, 5_000 ether);
        assertEq(early, 5_000 ether);
        assertEq(middle, 10_000 ether);
        assertEq(engine.status(address(fixture)).granted, 20_000 ether);
    }
}

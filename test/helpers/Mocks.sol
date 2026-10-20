// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IToken} from "../../src/interfaces/Interfaces.sol";

contract MockToken {
    uint256 public totalSupply;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public fee;
    bool public returnFalse;
    address public callback;
    bytes public callbackData;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function burn(address from, uint256 amount) external {
        totalSupply -= amount;
        balanceOf[from] -= amount;
    }

    function setFee(uint256 fee_) external {
        fee = fee_;
    }

    function setFalse(bool fail) external {
        returnFalse = fail;
    }

    function setCallback(address to, bytes calldata data) external {
        callback = to;
        callbackData = data;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return !returnFalse;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return !returnFalse;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amount;
        _transfer(from, to, amount);
        return !returnFalse;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        uint256 charged = amount * fee / 10_000;
        balanceOf[to] += amount - charged;
        totalSupply -= charged;
        if (callback != address(0)) {
            (bool ok,) = callback.call(callbackData);
            require(ok, "callback rejected");
        }
    }
}

contract MockGame {
    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    uint64 public immutable genesis;
    uint256 public nextFinalizeWindow;
    uint256 public cumulativeLoss;
    mapping(uint256 => mapping(address => uint256)) public lossOf;
    mapping(uint256 => uint256) public totalEligibleLoss;
    mapping(uint256 => uint256) public cumulativeLossBefore;
    mapping(uint256 => uint256) public cumulativeLossAfter;
    mapping(address => uint256) public balances;
    uint256 public jackpot;
    uint256 public oracle;
    bool public fail;

    constructor(uint64 genesis_) {
        genesis = genesis_;
    }

    function windowStart(uint256 k) external view returns (uint64) {
        return uint64(genesis + k * 1 hours);
    }

    function windowEnd(uint256 k) public view returns (uint64) {
        return uint64(genesis + (k + 1) * 1 hours);
    }

    function setFail(bool fail_) external {
        fail = fail_;
    }

    function setLoss(uint256 k, address who, uint256 amount) external {
        require(k >= nextFinalizeWindow, "already final");
        totalEligibleLoss[k] = totalEligibleLoss[k] - lossOf[k][who] + amount;
        lossOf[k][who] = amount;
    }

    function setTotal(uint256 k, uint256 amount) external {
        totalEligibleLoss[k] = amount;
    }

    function corruptBefore(uint256 k, uint256 amount) external {
        cumulativeLossBefore[k] = amount;
    }

    function finalize(uint256 maxWindows) external {
        for (uint256 i; i < maxWindows; ++i) {
            uint256 k = nextFinalizeWindow;
            if (windowEnd(k) > block.timestamp) break;
            cumulativeLossBefore[k] = cumulativeLoss;
            cumulativeLoss += totalEligibleLoss[k];
            cumulativeLossAfter[k] = cumulativeLoss;
            ++nextFinalizeWindow;
        }
    }

    function credit(address to, uint256 amount) external {
        MockToken(IMD).mint(address(this), amount);
        balances[to] += amount;
    }

    function withdraw() external {
        require(!fail, "game failure");
        uint256 amount = balances[msg.sender];
        require(amount != 0, "empty");
        balances[msg.sender] = 0;
        require(IToken(IMD).transfer(msg.sender, amount));
    }

    function depositJackpot(uint256 amount) external {
        require(!fail, "game failure");
        jackpot += amount;
        require(IToken(IMD).transferFrom(msg.sender, address(this), amount));
    }

    function fundOracleReserve(uint256 amount) external {
        require(!fail, "game failure");
        oracle += amount;
        require(IToken(IMD).transferFrom(msg.sender, address(this), amount));
    }
}

contract MockNFT {
    mapping(uint256 => address) private _owner;

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x80ac58cd;
    }

    function ownerOf(uint256 id) external view returns (address) {
        require(_owner[id] != address(0), "not minted");
        return _owner[id];
    }

    function mint(address to, uint256 id) external {
        _owner[id] = to;
    }

    function move(uint256 id, address to) external {
        _owner[id] = to;
    }
}

contract MockNoReturnToken {
    uint256 public totalSupply;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

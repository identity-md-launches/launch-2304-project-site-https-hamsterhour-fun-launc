// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultBase} from "./VaultBase.sol";
import {VaultMath as M} from "./libraries/VaultMath.sol";

abstract contract HamsterStaking is VaultBase {
    uint256 public constant WARMUP = 24 hours;
    uint256 public constant UNSTAKE_DELAY = 24 hours;
    uint256 public constant VESTING = 7 days;
    uint256 public constant HOOK_STREAM = 7 days;
    uint256 public constant GAME_STREAM = 30 days;
    uint256 public constant RAY = 1e27;
    uint256 public constant MAX_CHECKPOINT = 128;

    struct RewardState {
        uint256 wallTime;
        uint256 clock; // Seconds with nonzero eligible weight. All reward sources pause at zero.
        uint256 weight;
        uint256 index;
        uint256 hookRate; // IMD wei * RAY per active second.
        uint256 gameRate;
        uint256 hookCursor;
        uint256 gameCursor;
        uint256 activationCursor;
        uint256 hookReleased; // IMD wei * RAY.
        uint256 gameReleased;
        uint256 dripPrincipal;
        uint256 dripStart;
        uint256 dripReleased; // IMD wei since the latest drip deposit.
        uint256 dripEmitted; // IMD wei over all drip deposits.
        uint256 dustScaled; // IMD wei * RAY not credited by index division.
    }

    struct StreamEnd {
        uint256 finish; // Active reward clock.
        uint256 rate;
        uint256 dustScaled;
    }

    struct Activation {
        uint256 at;
        uint256 amount;
        uint256 index;
    }

    struct Account {
        uint256 weight;
        uint256 paidIndex;
        uint256 earned;
        uint256 remainder; // Fractional IMD wei, denominator RAY.
        uint256 cursor; // First lot not yet incorporated in account.weight.
    }

    struct Lot {
        uint256 amount;
        uint256 activation;
        bool isGrant;
    }

    struct Grant {
        uint256 amount;
        uint256 withdrawn;
        uint256 startsAt;
        uint256 lot;
    }

    struct Unstake {
        uint256 amount;
        uint256 readyAt;
        bool withdrawn;
    }

    RewardState internal _reward;
    StreamEnd[] public hookStreams;
    StreamEnd[] public gameStreams;
    Activation[] public activations;
    mapping(address => Account) public accounts;
    mapping(address => Lot[]) public lots;
    mapping(address => Grant[]) public grants;
    mapping(address => Unstake[]) public unstakeQueue;
    mapping(address => uint256) public stakedBalance;
    mapping(address => uint256) public grantBalance;
    uint256 public totalStaked;
    uint256 public totalGrantBalance;
    uint256 public totalUnstakeQueued;
    uint256 public hookDeposited;
    uint256 public gameDeposited;
    uint256 public dripDeposited;
    uint256 public rewardsPaid;

    error CheckpointRequired();
    error WrongLot();

    event Staked(address indexed account, uint256 indexed lot, uint256 amount, uint256 earnsAt);
    event GrantCreated(address indexed account, uint256 indexed grant, uint256 amount, uint256 startsAt);
    event VestedWithdrawn(address indexed account, uint256 amount);
    event UnstakeRequested(address indexed account, uint256 indexed request, uint256 amount, uint256 readyAt);
    event Unstaked(address indexed account, uint256 amount);
    event StreamFunded(address indexed from, uint256 amount, uint256 duration);
    event DripDeposited(address indexed from, uint256 amount);
    event RewardsPaid(address indexed account, uint256 amount);
    event Checkpoint(uint256 wallTime, uint256 rewardClock, uint256 weight, uint256 index);

    constructor() {
        _reward.wallTime = block.timestamp;
    }

    /// @dev One interval, ending at the next activation, stream end, or target. The exact same
    /// evaluator powers state checkpoints and pendingIMD, including unattended warm-up maturity.
    function _step(RewardState memory s, uint256 target) internal view returns (RewardState memory) {
        uint256 to = target;
        if (s.activationCursor < activations.length) to = M.min(to, activations[s.activationCursor].at);
        if (s.weight != 0) {
            if (s.hookCursor < hookStreams.length) {
                to = M.min(to, s.wallTime + hookStreams[s.hookCursor].finish - s.clock);
            }
            if (s.gameCursor < gameStreams.length) {
                to = M.min(to, s.wallTime + gameStreams[s.gameCursor].finish - s.clock);
            }
            uint256 dt = to - s.wallTime;
            s.clock += dt;
            uint256 hookEmission = s.hookRate * dt;
            uint256 gameEmission = s.gameRate * dt;
            if (s.hookCursor < hookStreams.length && hookStreams[s.hookCursor].finish == s.clock) {
                StreamEnd memory e = hookStreams[s.hookCursor++];
                s.hookRate -= e.rate;
                hookEmission += e.dustScaled;
            }
            if (s.gameCursor < gameStreams.length && gameStreams[s.gameCursor].finish == s.clock) {
                StreamEnd memory e = gameStreams[s.gameCursor++];
                s.gameRate -= e.rate;
                gameEmission += e.dustScaled;
            }
            s.hookReleased += hookEmission;
            s.gameReleased += gameEmission;
            uint256 released = M.mulDiv(s.dripPrincipal, RAY - M.decay(s.clock - s.dripStart), RAY);
            uint256 dripEmission = released - s.dripReleased;
            s.dripReleased = released;
            s.dripEmitted += dripEmission;
            uint256 emission = hookEmission + gameEmission + dripEmission * RAY;
            s.index += emission / s.weight;
            s.dustScaled += emission % s.weight;
        }
        s.wallTime = to;
        if (s.activationCursor < activations.length && activations[s.activationCursor].at == to) {
            s.weight += activations[s.activationCursor++].amount;
        }
        return s;
    }

    function _checkpoint(uint256 maxEvents) internal returns (bool current) {
        RewardState memory s = _reward;
        for (uint256 i; i < maxEvents && s.wallTime < block.timestamp; ++i) {
            uint256 oldCursor = s.activationCursor;
            s = _step(s, block.timestamp);
            if (s.activationCursor != oldCursor) activations[oldCursor].index = s.index;
        }
        _reward = s;
        return s.wallTime == block.timestamp;
    }

    /// @notice Bounded, permissionless maintenance. Repeat until true after a long idle period.
    function checkpoint(uint256 maxEvents) external guarded returns (bool current) {
        if (maxEvents == 0 || maxEvents > MAX_CHECKPOINT) revert TooMany();
        current = _checkpoint(maxEvents);
        emit Checkpoint(_reward.wallTime, _reward.clock, _reward.weight, _reward.index);
    }

    function _credit(Account memory a, uint256 weight, uint256 delta) private pure returns (Account memory) {
        a.earned += M.mulDiv(weight, delta, RAY);
        uint256 fractional = mulmod(weight, delta, RAY) + a.remainder;
        a.earned += fractional / RAY;
        a.remainder = fractional % RAY;
        return a;
    }

    function _syncAccount(address account, uint256 maxLots) internal returns (bool current) {
        Account memory a = accounts[account];
        a = _credit(a, a.weight, _reward.index - a.paidIndex);
        a.paidIndex = _reward.index;
        Lot[] storage positions = lots[account];
        uint256 end = M.min(a.cursor + maxLots, positions.length);
        for (; a.cursor < end; ++a.cursor) {
            Lot memory lot = positions[a.cursor];
            if (lot.activation >= _reward.activationCursor) break;
            a = _credit(a, lot.amount, _reward.index - activations[lot.activation].index);
            a.weight += lot.amount;
        }
        accounts[account] = a;
        return a.cursor == positions.length || positions[a.cursor].activation >= _reward.activationCursor;
    }

    function checkpointAccount(address account, uint256 maxLots) external guarded returns (bool current) {
        if (maxLots == 0 || maxLots > MAX_CHECKPOINT) revert TooMany();
        bool globalCurrent = _checkpoint(MAX_CHECKPOINT);
        current = _syncAccount(account, maxLots) && globalCurrent;
    }

    function _ready(address account) internal {
        if (!_checkpoint(MAX_CHECKPOINT)) revert CheckpointRequired();
        if (!_syncAccount(account, MAX_CHECKPOINT)) revert CheckpointRequired();
    }

    function _readyGlobal() internal {
        if (!_checkpoint(MAX_CHECKPOINT)) revert CheckpointRequired();
    }

    function _newLot(address account, uint256 amount, bool isGrant) internal returns (uint256 id) {
        uint256 at = block.timestamp + WARMUP;
        uint256 activation = activations.length;
        if (activation != 0 && activations[activation - 1].at == at) {
            --activation;
            activations[activation].amount += amount;
        } else {
            activations.push(Activation(at, amount, 0));
        }
        id = lots[account].length;
        lots[account].push(Lot(amount, activation, isGrant));
    }

    function stake(uint256 amount) external guarded returns (uint256 lot) {
        _bound();
        _ready(msg.sender);
        _pull(token, msg.sender, amount);
        lot = _newLot(msg.sender, amount, false);
        stakedBalance[msg.sender] += amount;
        totalStaked += amount;
        emit Staked(msg.sender, lot, amount, block.timestamp + WARMUP);
    }

    function _grant(address account, uint256 amount) internal virtual override {
        _ready(account);
        uint256 lot = _newLot(account, amount, true);
        uint256 id = grants[account].length;
        grants[account].push(Grant(amount, 0, block.timestamp, lot));
        grantBalance[account] += amount;
        totalGrantBalance += amount;
        emit GrantCreated(account, id, amount, block.timestamp);
    }

    function _removeLot(address account, uint256 lotId, uint256 amount) internal {
        Lot storage lot = lots[account][lotId];
        if (amount == 0 || amount > lot.amount) revert InvalidAmount();
        lot.amount -= amount;
        if (lot.activation < _reward.activationCursor) {
            _reward.weight -= amount;
            accounts[account].weight -= amount;
        } else {
            activations[lot.activation].amount -= amount;
        }
    }

    /// @notice Specify the deposit lot; this permits cancellation during warm-up without an
    /// unbounded search. The caller cannot unstake another wallet's funds or a vesting grant.
    function requestUnstake(uint256 lotId, uint256 amount) external guarded returns (uint256 request) {
        _ready(msg.sender);
        if (lots[msg.sender][lotId].isGrant) revert WrongLot();
        _removeLot(msg.sender, lotId, amount);
        stakedBalance[msg.sender] -= amount;
        totalStaked -= amount;
        totalUnstakeQueued += amount;
        request = unstakeQueue[msg.sender].length;
        unstakeQueue[msg.sender].push(Unstake(amount, block.timestamp + UNSTAKE_DELAY, false));
        emit UnstakeRequested(msg.sender, request, amount, block.timestamp + UNSTAKE_DELAY);
    }

    function withdrawUnstaked(address account, uint256[] calldata requests) external guarded returns (uint256 amount) {
        if (requests.length == 0 || requests.length > MAX_BATCH) revert TooMany();
        _ready(account);
        for (uint256 i; i < requests.length; ++i) {
            Unstake storage q = unstakeQueue[account][requests[i]];
            if (q.withdrawn) revert AlreadyDone();
            if (block.timestamp < q.readyAt) revert NotReady();
            q.withdrawn = true;
            amount += q.amount;
        }
        totalUnstakeQueued -= amount;
        _push(token, account, amount);
        emit Unstaked(account, amount);
    }

    function vested(address account, uint256 id) public view returns (uint256) {
        Grant memory g = grants[account][id];
        return M.mulDiv(g.amount, M.min(block.timestamp - g.startsAt, VESTING), VESTING);
    }

    function withdrawVested(address account, uint256[] calldata ids) external guarded returns (uint256 amount) {
        if (ids.length == 0 || ids.length > MAX_BATCH) revert TooMany();
        _ready(account);
        for (uint256 i; i < ids.length; ++i) {
            Grant storage g = grants[account][ids[i]];
            uint256 due = vested(account, ids[i]) - g.withdrawn;
            if (due == 0) continue;
            g.withdrawn += due;
            _removeLot(account, g.lot, due);
            amount += due;
        }
        if (amount == 0) revert InvalidAmount();
        grantBalance[account] -= amount;
        totalGrantBalance -= amount;
        _push(token, account, amount);
        emit VestedWithdrawn(account, amount);
    }

    function _stream(uint256 amount, bool game) internal {
        uint256 duration = game ? GAME_STREAM : HOOK_STREAM;
        uint256 finish = _reward.clock + duration;
        uint256 rate = amount * RAY / duration;
        uint256 dust = amount * RAY - rate * duration;
        StreamEnd[] storage queue = game ? gameStreams : hookStreams;
        uint256 n = queue.length;
        if (n != 0 && queue[n - 1].finish == finish) {
            queue[n - 1].rate += rate;
            queue[n - 1].dustScaled += dust;
        } else {
            queue.push(StreamEnd(finish, rate, dust));
        }
        if (game) {
            _reward.gameRate += rate;
            gameDeposited += amount;
        } else {
            _reward.hookRate += rate;
            hookDeposited += amount;
        }
        emit StreamFunded(msg.sender, amount, duration);
    }

    function depositRewards(uint256 amount) external guarded {
        _readyGlobal();
        _pull(IMD, msg.sender, amount);
        _stream(amount, false);
    }

    function depositDrip(uint256 amount) external guarded {
        _readyGlobal();
        _pull(IMD, msg.sender, amount);
        _reward.dripPrincipal = _reward.dripPrincipal - _reward.dripReleased + amount;
        _reward.dripReleased = 0;
        _reward.dripStart = _reward.clock;
        dripDeposited += amount;
        emit DripDeposited(msg.sender, amount);
    }

    function claimRewards(address account) external guarded returns (uint256 amount) {
        _ready(account);
        amount = accounts[account].earned;
        if (amount == 0) revert InvalidAmount();
        accounts[account].earned = 0;
        rewardsPaid += amount;
        _push(IMD, account, amount);
        emit RewardsPaid(account, amount);
    }

    function _preview() internal view returns (RewardState memory s, uint256[128] memory indices) {
        s = _reward;
        uint256 cursor = s.activationCursor;
        for (uint256 i; i < MAX_CHECKPOINT && s.wallTime < block.timestamp; ++i) {
            uint256 oldCursor = s.activationCursor;
            s = _step(s, block.timestamp);
            if (s.activationCursor != oldCursor) indices[oldCursor - cursor] = s.index;
        }
        if (s.wallTime != block.timestamp) revert CheckpointRequired();
    }

    function pendingIMD(address account) public view returns (uint256) {
        (RewardState memory s, uint256[128] memory indices) = _preview();
        Account memory a = accounts[account];
        a = _credit(a, a.weight, s.index - a.paidIndex);
        Lot[] storage positions = lots[account];
        uint256 end = M.min(a.cursor + MAX_CHECKPOINT, positions.length);
        for (; a.cursor < end; ++a.cursor) {
            Lot memory lot = positions[a.cursor];
            if (lot.activation >= s.activationCursor) break;
            uint256 index = lot.activation < _reward.activationCursor
                ? activations[lot.activation].index
                : indices[lot.activation - _reward.activationCursor];
            a = _credit(a, lot.amount, s.index - index);
        }
        if (a.cursor < positions.length && positions[a.cursor].activation < s.activationCursor) {
            revert CheckpointRequired();
        }
        return a.earned;
    }

    function rewardState() external view returns (RewardState memory s) {
        (s,) = _preview();
    }

    function storedRewardState() external view returns (RewardState memory) {
        return _reward;
    }

    function positionCounts(address account)
        external
        view
        returns (uint256 lotCount, uint256 grantCount, uint256 unstakeCount)
    {
        return (lots[account].length, grants[account].length, unstakeQueue[account].length);
    }

    function streamCounts() external view returns (uint256 hookCount, uint256 gameCount, uint256 activationCount) {
        return (hookStreams.length, gameStreams.length, activations.length);
    }

    function rewardLiability() public view returns (uint256) {
        return hookDeposited + gameDeposited + dripDeposited - rewardsPaid;
    }
}

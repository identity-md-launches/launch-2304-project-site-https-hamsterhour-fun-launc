// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {INFT, IHamsterGame} from "./interfaces/Interfaces.sol";
import {VaultMath as M} from "./libraries/VaultMath.sol";

interface IMiningView {
    struct GameData {
        bool registered;
        bool rangeReady;
        uint64 genesis;
        uint64 switchedAt;
        uint256 first;
        uint256 end;
        uint256 localOrigin;
        uint256 globalOrigin;
        address previous;
    }
    function windowAccounting(address game, uint256 k)
        external
        view
        returns (bool, uint256, uint256, uint256, uint256, uint256);
    function deployedAt() external view returns (uint256);
    function currentGame() external view returns (address);
    function gameAtTime(uint256 timestamp) external view returns (uint256);
    function gameList(uint256 index) external view returns (address);
    function gameCount() external view returns (uint256);
    function games(address game) external view returns (GameData memory);
    function windowBudget(address game, uint256 k) external view returns (uint256 budget, uint256 total);
}

interface ILoss {
    function lossOf(uint256 k, address account) external view returns (uint256);
}

/// @notice Immutable, noncustodial boost accounting. Every mutation uses msg.sender as its
/// namespace. A direct caller can modify only its own namespace, never a HamsterVault's.
/// Deploy this first, then pass its address to the vault's immutable constructor parameter.
contract HamsterBoost {
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    uint256 internal constant HALF_LOSS = 18_750 ether;
    uint256 internal constant MINING_ALLOCATION = 750_000_000 ether;
    uint256 internal constant NEW_GAME_PERIOD = 14 days;
    uint256 internal constant NEW_GAME_DAILY_CAP = 2_000_000 ether;
    error UnknownGame();
    error ExcludedWindow();
    error NotFinalized();
    error InvalidInterface();
    uint256 public constant ALLOCATION = 50_000_000 ether;
    uint256 public constant DAILY_CAP = 100_000 ether;
    uint256 public constant NFT_DAILY_CAP = 10_000 ether;

    struct State {
        address pendingCollection;
        uint256 readyAt;
        address collection;
        bool swept;
        uint256 sweptLoss; // Effective global loss when swept; the curve extends from here.
        uint256 nextDay;
        uint256 committed;
        uint256 granted;
    }

    struct Registration {
        address account;
        uint64 eligibleFrom;
        uint256 tokenId;
        bool invalid;
    }

    struct Window {
        address game;
        uint256 k;
        uint256 startsAt;
        uint256 budget;
        uint256 total;
    }

    struct Day {
        bool started;
        bool complete;
        bool counted;
        uint256 registrationCount;
        uint256 cursor;
        uint256 demand;
        uint256 budget;
        uint256 paid;
    }

    mapping(address => State) private _states;
    mapping(address => Registration[]) public registrations;
    mapping(address => uint256[]) public registeredTokens;
    mapping(address => mapping(address => uint256[])) public walletRegistrations;
    mapping(address => mapping(uint256 => uint256)) public nftRegistration;
    mapping(address => mapping(uint256 => Day)) public days_;
    mapping(address => mapping(uint256 => Window[])) private _windows;
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) public demand;
    mapping(address => mapping(uint256 => mapping(uint256 => bool))) public claimed;
    mapping(address => mapping(uint256 => mapping(uint256 => bool))) public eligibleSnapshot;
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) public dayRegistration;
    mapping(address => mapping(uint256 => mapping(address => mapping(uint256 => uint256)))) public eligibleCount;

    /// @dev Sequential new-game cap accounting per (vault, game). `pos` is the effective global
    /// curve position after every prepared day; `dropped` is loss the cap left unconsumed.
    struct CapState {
        bool complete;
        uint256 nextDay;
        uint256 pos;
        uint256 dropped;
    }

    struct CapDay {
        bool ready;
        uint256 pos; // Effective global position at the day's first capped window.
        uint256 lossStart; // Local cumulative loss before that window.
        uint256 raw; // Sum of uncapped window budgets.
        uint256 allowance; // Amount actually emitted: min(raw, 2M) on the curve.
    }

    /// @dev The curve in force when a capped day was cached. A day's `raw` and `allowance` were
    /// summed on this curve, so its windows are priced on the same curve forever, even if the
    /// dormant-boost sweep later extends the live curve past the day's raw positions.
    struct CapCurve {
        bool swept;
        uint256 sweptLoss;
    }

    mapping(address => mapping(address => CapState)) public capStates;
    mapping(address => mapping(address => mapping(uint256 => CapDay))) public capDays;
    mapping(address => mapping(address => mapping(uint256 => CapCurve))) public capDayCurves;

    error AlreadyDone();
    error NotReady();
    error InvalidCollection();
    error IneligibleNFT();
    error InvalidAmount();
    error TooMany();
    error BadLossHistory();

    event Scheduled(address indexed vault, address indexed collection, uint256 readyAt);
    event Activated(address indexed vault, address indexed collection);
    event Registered(
        address indexed vault,
        uint256 indexed registration,
        address indexed account,
        uint256 tokenId,
        uint256 eligibleFrom
    );
    event Voided(address indexed vault, uint256 indexed registration);
    event Prepared(address indexed vault, uint256 indexed day, uint256 demand, uint256 budget);
    event Claimed(
        address indexed vault, uint256 indexed day, uint256 indexed registration, address account, uint256 amount
    );
    event Swept(address indexed vault, uint256 sweptLoss);
    event CapDayPrepared(
        address indexed vault, address indexed game, uint256 indexed day, uint256 raw, uint256 allowance
    );

    function status(address vault) external view returns (State memory) {
        return _states[vault];
    }

    function _checkCollection(address collection_) private view {
        if (block.chainid != 1 || collection_.code.length == 0 || !INFT(collection_).supportsInterface(0x80ac58cd)) {
            revert InvalidCollection();
        }
    }

    /// @dev Only the vault can create a commitment in the vault's namespace. Its wrapper checks TEAM.
    function schedule(address collection_) external {
        State storage s = _states[msg.sender];
        if (s.collection != address(0) || s.swept) revert AlreadyDone();
        if (block.timestamp + 12 hours >= IMiningView(msg.sender).deployedAt() + 365 days) revert NotReady();
        _checkCollection(collection_);
        s.pendingCollection = collection_;
        s.readyAt = block.timestamp + 12 hours;
        emit Scheduled(msg.sender, collection_, s.readyAt);
    }

    function execute() external {
        State storage s = _states[msg.sender];
        if (
            s.pendingCollection == address(0) || block.timestamp < s.readyAt
                || block.timestamp >= IMiningView(msg.sender).deployedAt() + 365 days || s.swept
        ) revert NotReady();
        _checkCollection(s.pendingCollection);
        s.collection = s.pendingCollection;
        delete s.pendingCollection;
        s.nextDay = (block.timestamp + 24 hours) / 1 days;
        emit Activated(msg.sender, s.collection);
    }

    function sweep() external {
        State storage s = _states[msg.sender];
        if (block.timestamp < IMiningView(msg.sender).deployedAt() + 365 days) revert NotReady();
        if (s.collection != address(0) || s.swept) revert AlreadyDone();
        (uint256 globalLoss,,) = _miningState(msg.sender);
        s.swept = true;
        s.sweptLoss = globalLoss;
        delete s.pendingCollection;
        emit Swept(msg.sender, globalLoss);
    }

    function register(address account, uint256 tokenId) external returns (uint256 id) {
        State memory s = _states[msg.sender];
        if (s.collection == address(0) || INFT(s.collection).ownerOf(tokenId) != account) revert IneligibleNFT();
        uint256 previous = nftRegistration[msg.sender][tokenId];
        if (previous != 0) {
            Registration storage old = registrations[msg.sender][previous - 1];
            if (!old.invalid && old.account == account) revert AlreadyDone();
            old.invalid = true;
            emit Voided(msg.sender, previous - 1);
        } else {
            registeredTokens[msg.sender].push(tokenId);
        }
        id = registrations[msg.sender].length;
        registrations[msg.sender].push(Registration(account, uint64(block.timestamp + 24 hours), tokenId, false));
        nftRegistration[msg.sender][tokenId] = id + 1;
        walletRegistrations[msg.sender][account].push(id);
        emit Registered(msg.sender, id, account, tokenId, block.timestamp + 24 hours);
    }

    function validRegistration(address vault, uint256 id) public view returns (bool) {
        Registration memory r = registrations[vault][id];
        if (r.invalid || nftRegistration[vault][r.tokenId] != id + 1) {
            return false;
        }
        try INFT(_states[vault].collection).ownerOf(r.tokenId) returns (address owner) {
            return owner == r.account;
        } catch {
            return false;
        }
    }

    function invalidate(uint256 id) external {
        if (validRegistration(msg.sender, id)) revert IneligibleNFT();
        registrations[msg.sender][id].invalid = true;
        emit Voided(msg.sender, id);
    }

    function registrationCount(address vault) external view returns (uint256) {
        return registrations[vault].length;
    }

    function registeredTokenCount(address vault) external view returns (uint256) {
        return registeredTokens[vault].length;
    }

    function walletRegistrationCount(address vault, address account) external view returns (uint256) {
        return walletRegistrations[vault][account].length;
    }

    function _firstAt(uint256 genesis, uint256 timestamp) private pure returns (uint256) {
        return timestamp <= genesis ? 0 : (timestamp - genesis + 1 hours - 1) / 1 hours;
    }

    function _startDay(address vault, uint256 day) private {
        Day storage d = days_[vault][day];
        d.started = true;
        // Enumerate each NFT once, not its entire ownership history. Repeated transfers cannot
        // grow the amount of daily preparation work for that token.
        d.registrationCount = registeredTokens[vault].length;
        IMiningView v = IMiningView(vault);
        uint256 idx = v.gameAtTime(day * 1 days);
        uint256 count = v.gameCount();
        for (; idx < count; ++idx) {
            address game = v.gameList(idx);
            IMiningView.GameData memory g = v.games(game);
            uint256 genesis = g.genesis;
            uint256 switchedAt = g.switchedAt;
            uint256 first = g.first;
            uint256 end = g.end;
            if (switchedAt >= (day + 1) * 1 days) break;
            if (g.previous != address(0)) _advanceCap(vault, game, 16);
            uint256 dayFirst = _firstAt(genesis, day * 1 days);
            if (dayFirst > first) first = dayFirst;
            end = M.min(end, _firstAt(genesis, (day + 1) * 1 days));
            for (uint256 k = first; k < end; ++k) {
                (uint256 budget, uint256 total) = v.windowBudget(game, k);
                _windows[vault][day].push(Window(game, k, uint256(genesis) + k * 1 hours, budget, total));
            }
        }
    }

    /// @notice Reserve days chronologically; claims can then arrive in any order. Registration
    /// enumeration is bounded and resumable, with at most 25 hourly windows per UTC day.
    function prepare(uint256 maxRegistrations) external {
        State storage s = _states[msg.sender];
        if (s.collection == address(0)) revert NotReady();
        uint256 day = s.nextDay;
        if (block.timestamp < (day + 1) * 1 days) revert NotReady();
        if (maxRegistrations == 0 || maxRegistrations > 8) revert TooMany();
        Day storage d = days_[msg.sender][day];
        if (!d.started) _startDay(msg.sender, day);
        uint256 end = M.min(d.cursor + maxRegistrations, d.registrationCount);
        // First freeze eligible NFT counts for every wallet/window. Splitting its +50% bonus
        // equally across its eligible NFTs increases cap capacity without multiplying the bonus.
        if (!d.counted) {
            for (uint256 cursor = d.cursor; cursor < end; ++cursor) {
                uint256 id = nftRegistration[msg.sender][registeredTokens[msg.sender][cursor]] - 1;
                dayRegistration[msg.sender][day][cursor] = id + 1;
                if (!validRegistration(msg.sender, id)) continue;
                Registration memory r = registrations[msg.sender][id];
                eligibleSnapshot[msg.sender][day][id] = true;
                Window[] storage windows = _windows[msg.sender][day];
                for (uint256 j; j < windows.length; ++j) {
                    if (windows[j].startsAt >= r.eligibleFrom && windows[j].total != 0) {
                        ++eligibleCount[msg.sender][day][r.account][j];
                    }
                }
            }
            d.cursor = end;
            if (end == d.registrationCount) {
                d.counted = true;
                d.cursor = 0;
            }
            return;
        }
        for (uint256 cursor = d.cursor; cursor < end; ++cursor) {
            uint256 id = dayRegistration[msg.sender][day][cursor] - 1;
            Registration memory r = registrations[msg.sender][id];
            uint256 amount;
            if (eligibleSnapshot[msg.sender][day][id]) {
                Window[] storage windows = _windows[msg.sender][day];
                for (uint256 j; j < windows.length; ++j) {
                    Window memory w = windows[j];
                    if (w.startsAt < r.eligibleFrom || w.total == 0) continue;
                    uint256 loss = ILoss(w.game).lossOf(w.k, r.account);
                    if (loss > w.total) revert BadLossHistory();
                    amount += M.mulDiv(w.budget, loss, w.total) / 2 / eligibleCount[msg.sender][day][r.account][j];
                }
            }
            amount = M.min(amount, NFT_DAILY_CAP);
            demand[msg.sender][day][id] = amount;
            d.demand += amount;
        }
        d.cursor = end;
        if (end == d.registrationCount) {
            d.budget = M.min(M.min(d.demand, DAILY_CAP), ALLOCATION - s.committed);
            s.committed += d.budget;
            d.complete = true;
            ++s.nextDay;
            emit Prepared(msg.sender, day, d.demand, d.budget);
        }
    }

    function claimable(address vault, uint256 day, uint256 registration) public view returns (uint256) {
        Day memory d = days_[vault][day];
        if (!d.complete) revert NotReady();
        if (claimed[vault][day][registration] || !validRegistration(vault, registration) || d.demand == 0) return 0;
        return M.mulDiv(d.budget, demand[vault][day][registration], d.demand);
    }

    function claim(uint256 day, uint256 registration) external returns (address beneficiary, uint256 amount) {
        if (claimed[msg.sender][day][registration]) revert AlreadyDone();
        amount = claimable(msg.sender, day, registration);
        if (amount == 0) revert InvalidAmount();
        claimed[msg.sender][day][registration] = true;
        days_[msg.sender][day].paid += amount;
        _states[msg.sender].granted += amount;
        beneficiary = registrations[msg.sender][registration].account;
        emit Claimed(msg.sender, day, registration, beneficiary, amount);
    }

    function _hasSelector(bytes memory code, bytes4 selector) private pure returns (bool) {
        // ABI probing is compatibility checking, not a proof that a TEAM-selected game is honest.
        for (uint256 i; i + 4 < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0x63) {
                bytes4 found;
                assembly ("memory-safe") {
                    found := mload(add(add(code, 33), i))
                }
                if (found == selector) return true;
            }
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
        }
        return false;
    }

    function checkGame(address candidate) external view returns (uint64 genesis) {
        if (candidate == address(this) || candidate.code.length == 0) revert InvalidInterface();
        IHamsterGame g = IHamsterGame(candidate);
        genesis = g.windowStart(0);
        if (
            g.IMD() != IMD || g.windowEnd(0) != uint256(genesis) + 1 hours
                || g.windowStart(1) != uint256(genesis) + 1 hours
        ) revert InvalidInterface();
        // Check all required read selectors with their real ABI.
        g.nextFinalizeWindow();
        g.lossOf(0, address(this));
        g.totalEligibleLoss(0);
        g.cumulativeLossBefore(0);
        g.cumulativeLossAfter(0);
        g.balances(address(this));
        bytes memory code = candidate.code;
        if (
            !_hasSelector(code, IHamsterGame.withdraw.selector) || !_hasSelector(code, IHamsterGame.finalize.selector)
                || !_hasSelector(code, IHamsterGame.depositJackpot.selector)
                || !_hasSelector(code, IHamsterGame.fundOracleReserve.selector)
        ) revert InvalidInterface();
    }

    /// @notice Integral of the global, never-reset halving curve, in HAMSTER wei.
    /// Each complete band consumes half the remaining 750M curve. Saturation is below one wei.
    function emissionCurve(uint256 loss) public pure returns (uint256) {
        uint256 h = loss / HALF_LOSS;
        if (h >= 90) return MINING_ALLOCATION;
        uint256 remaining = MINING_ALLOCATION >> h;
        uint256 band = remaining - (MINING_ALLOCATION >> (h + 1));
        return MINING_ALLOCATION - remaining + M.mulDiv(band, loss % HALF_LOSS, HALF_LOSS);
    }

    /// @dev The curve that applies to a vault. After a dormant-boost sweep the part of the curve
    /// beyond the sweep point is scaled so that it converges to 800M instead of 750M. Halving
    /// points are unchanged and everything already emitted is unchanged.
    function _curve(State memory s, uint256 loss) internal pure returns (uint256) {
        uint256 f = emissionCurve(loss);
        if (!s.swept || loss <= s.sweptLoss) return f;
        uint256 f0 = emissionCurve(s.sweptLoss);
        uint256 room = MINING_ALLOCATION - f0;
        if (room == 0) return f;
        return f0 + M.mulDiv(f - f0, room + ALLOCATION, room);
    }

    function extendedCurve(address vault, uint256 loss) external view returns (uint256) {
        return _curve(_states[vault], loss);
    }

    /// @dev A loss whose extended emission does not exceed `emission` (the largest one up to the
    /// rounding of the curve itself). Saturated emission maps to the first saturated loss.
    function _inverse(State memory s, uint256 emission) internal pure returns (uint256) {
        if (s.swept && emission > emissionCurve(s.sweptLoss)) {
            uint256 f0 = emissionCurve(s.sweptLoss);
            uint256 room = MINING_ALLOCATION - f0;
            if (room != 0) emission = f0 + M.mulDiv(emission - f0, room, room + ALLOCATION);
        }
        if (emission >= MINING_ALLOCATION) return 90 * HALF_LOSS;
        uint256 h;
        while (MINING_ALLOCATION - (MINING_ALLOCATION >> (h + 1)) <= emission) ++h;
        uint256 band = (MINING_ALLOCATION >> h) - (MINING_ALLOCATION >> (h + 1));
        uint256 within = emission - (MINING_ALLOCATION - (MINING_ALLOCATION >> h));
        return h * HALF_LOSS + M.mulDiv(within, HALF_LOSS, band);
    }

    function _lossRange(address game, IMiningView.GameData memory g, uint256 k)
        internal
        view
        returns (uint256 before_, uint256 total)
    {
        if (!g.registered) revert UnknownGame();
        if (!g.rangeReady) revert NotReady();
        if (k < g.first || k >= g.end) revert ExcludedWindow();
        IHamsterGame source = IHamsterGame(game);
        if (source.nextFinalizeWindow() <= k) revert NotFinalized();
        if (
            source.windowStart(k) != uint256(g.genesis) + k * 1 hours
                || source.windowEnd(k) != uint256(g.genesis) + (k + 1) * 1 hours
        ) revert InvalidInterface();
        before_ = source.cumulativeLossBefore(k);
        uint256 after_ = source.cumulativeLossAfter(k);
        total = source.totalEligibleLoss(k);
        if (
            before_ < g.localOrigin || after_ < before_ || after_ - before_ != total
                || (k == g.first && before_ != g.localOrigin)
                || (k > g.first && before_ != source.cumulativeLossAfter(k - 1))
        ) revert BadLossHistory();
    }

    function _dayBounds(IMiningView.GameData memory g, uint256 day) internal pure returns (uint256 first, uint256 end) {
        first = _firstAt(g.genesis, day * 1 days);
        if (first < g.first) first = g.first;
        end = M.min(_firstAt(g.genesis, (day + 1) * 1 days), g.end);
        if (end < first) end = first;
    }

    /// @dev First window of a successor that is outside its 14-day cap period.
    function _capEnd(IMiningView.GameData memory g) internal pure returns (uint256) {
        return M.min(g.end, _firstAt(g.genesis, uint256(g.switchedAt) + NEW_GAME_PERIOD));
    }

    function _capDayBounds(IMiningView.GameData memory g, uint256 day)
        internal
        pure
        returns (uint256 first, uint256 end)
    {
        (first, end) = _dayBounds(g, day);
        end = M.min(end, _capEnd(g));
        if (end < first) end = first;
    }

    function _capState(address vault, address game, IMiningView.GameData memory g)
        internal
        view
        returns (CapState memory c)
    {
        c = capStates[vault][game];
        if (c.nextDay == 0) {
            c.nextDay = uint256(g.switchedAt) / 1 days;
            c.pos = g.globalOrigin;
        }
    }

    /// @dev Evaluate one capped UTC day from finalized history only. A day whose raw emission
    /// exceeds 2M pays exactly the curve segment worth 2M and leaves the rest of its loss
    /// unconsumed, so the curve resumes from there and nothing is forfeited.
    function _nextCapDay(address game, IMiningView.GameData memory g, State memory s, CapState memory c)
        internal
        view
        returns (CapDay memory d)
    {
        (uint256 first, uint256 end) = _capDayBounds(g, c.nextDay);
        d.ready = true;
        d.pos = c.pos;
        uint256 p = c.pos;
        if (first < end) d.lossStart = IHamsterGame(game).cumulativeLossBefore(first);
        for (uint256 k = first; k < end; ++k) {
            (, uint256 total) = _lossRange(game, g, k);
            d.raw += _curve(s, p + total) - _curve(s, p);
            p += total;
        }
        if (d.raw <= NEW_GAME_DAILY_CAP) {
            d.allowance = d.raw;
            c.pos = p;
        } else {
            uint256 target = _inverse(s, _curve(s, c.pos) + NEW_GAME_DAILY_CAP);
            uint256 x = target > c.pos ? target - c.pos : 0;
            d.allowance = _curve(s, c.pos + x) - _curve(s, c.pos);
            c.dropped += (p - c.pos) - x;
            c.pos += x;
        }
        ++c.nextDay;
        if (_firstAt(g.genesis, c.nextDay * 1 days) >= _capEnd(g)) c.complete = true;
    }

    function _advanceCap(address vault, address game, uint256 maxDays) internal returns (CapState memory c) {
        IMiningView.GameData memory g = IMiningView(vault).games(game);
        if (!g.registered) revert UnknownGame();
        if (g.previous == address(0)) {
            c.complete = true;
            return c;
        }
        if (!g.rangeReady) revert NotReady();
        State memory s = _states[vault];
        c = _capState(vault, game, g);
        uint256 nextFinalize = IHamsterGame(game).nextFinalizeWindow();
        for (uint256 i; i < maxDays && !c.complete; ++i) {
            (, uint256 end) = _capDayBounds(g, c.nextDay);
            if (nextFinalize < end) break;
            uint256 day = c.nextDay;
            CapDay memory d = _nextCapDay(game, g, s, c);
            capDays[vault][game][day] = d;
            capDayCurves[vault][game][day] = CapCurve(s.swept, s.sweptLoss);
            emit CapDayPrepared(vault, game, day, d.raw, d.allowance);
        }
        capStates[vault][game] = c;
    }

    /// @notice Cache a successor's capped days for any vault. Permissionless: the result is a
    /// function of finalized history only. Bounded and resumable; stops at the first day whose
    /// windows are not all finalized.
    function prepareCap(address vault, address game, uint256 maxDays)
        external
        returns (bool complete, uint256 dropped)
    {
        if (maxDays == 0 || maxDays > 16) revert TooMany();
        CapState memory c = _advanceCap(vault, game, maxDays);
        return (c.complete, c.dropped);
    }

    /// @dev A capped day and the curve state its windows must be priced on: the cached snapshot
    /// for a cached day, the live state for one evaluated on the fly.
    function _capDayView(address vault, address game, IMiningView.GameData memory g, State memory s, uint256 day)
        internal
        view
        returns (CapDay memory d, State memory priced)
    {
        priced = s;
        d = capDays[vault][game][day];
        if (d.ready) {
            // A fresh struct: `s` is the live state and must not be rewritten through an alias.
            CapCurve memory curve = capDayCurves[vault][game][day];
            priced = State(address(0), 0, address(0), curve.swept, curve.sweptLoss, 0, 0, 0);
            return (d, priced);
        }
        CapState memory c = _capState(vault, game, g);
        if (day < c.nextDay) revert ExcludedWindow();
        while (true) {
            d = _nextCapDay(game, g, s, c);
            if (c.nextDay - 1 == day) return (d, priced);
        }
    }

    function _droppedView(address vault, address game, IMiningView.GameData memory g, State memory s)
        internal
        view
        returns (uint256)
    {
        CapState memory c = _capState(vault, game, g);
        while (!c.complete) _nextCapDay(game, g, s, c);
        return c.dropped;
    }

    /// @notice Effective global loss consumed by the curve through window `end` (exclusive).
    function _effectiveLoss(address vault, address game, IMiningView.GameData memory g, State memory s, uint256 end)
        internal
        view
        returns (uint256)
    {
        uint256 localEnd = end <= g.first ? g.localOrigin : IHamsterGame(game).cumulativeLossAfter(end - 1);
        if (localEnd < g.localOrigin) revert BadLossHistory();
        if (g.previous == address(0)) return g.globalOrigin + (localEnd - g.localOrigin);
        CapState memory c = _capState(vault, game, g);
        while (!c.complete) {
            (, uint256 dayEnd) = _capDayBounds(g, c.nextDay);
            if (dayEnd > end) break;
            _nextCapDay(game, g, s, c);
        }
        if (c.complete) return g.globalOrigin + (localEnd - g.localOrigin) - c.dropped;
        (uint256 first,) = _capDayBounds(g, c.nextDay);
        return end > first ? c.pos + (localEnd - IHamsterGame(game).cumulativeLossBefore(first)) : c.pos;
    }

    function _miningState(address vault) internal view returns (uint256 globalLoss, uint256 rate, uint256 halving) {
        IMiningView v = IMiningView(vault);
        address game = v.currentGame();
        IMiningView.GameData memory g = v.games(game);
        if (!g.rangeReady) {
            // Report the finalized history of the outgoing game until the successor is resolved.
            game = g.previous;
            g = v.games(game);
        }
        State memory s = _states[vault];
        uint256 end = M.min(IHamsterGame(game).nextFinalizeWindow(), g.end);
        globalLoss = _effectiveLoss(vault, game, g, s, end);
        halving = globalLoss / HALF_LOSS;
        rate = halving >= 256 ? 0 : (20_000 ether >> halving);
        if (s.swept && globalLoss >= s.sweptLoss) {
            uint256 room = MINING_ALLOCATION - emissionCurve(s.sweptLoss);
            if (room != 0) rate = M.mulDiv(rate, room + ALLOCATION, room);
        }
    }

    function currentMiningState(address vault)
        external
        view
        returns (uint256 globalLoss, uint256 rate, uint256 halving)
    {
        return _miningState(vault);
    }

    /// @notice Base rate and halving index at a global loss, before any sweep extension.
    function rateAndHalving(uint256 globalLoss) external pure returns (uint256 rate, uint256 halving) {
        halving = globalLoss / HALF_LOSS;
        rate = halving >= 256 ? 0 : (20_000 ether >> halving);
    }

    function _rawBudget(address vault, address game, uint256 k) internal view returns (uint256 budget, uint256 total) {
        IMiningView.GameData memory g = IMiningView(vault).games(game);
        uint256 before_;
        (before_, total) = _lossRange(game, g, k);
        State memory s = _states[vault];
        uint256 pos;
        if (g.previous == address(0)) {
            pos = g.globalOrigin + (before_ - g.localOrigin);
        } else if (k < _capEnd(g)) {
            (CapDay memory d, State memory priced) =
                _capDayView(vault, game, g, s, (uint256(g.genesis) + k * 1 hours) / 1 days);
            pos = d.pos + (before_ - d.lossStart);
            // Same curve as the one that produced d.raw, so the day's shares always sum to at
            // most d.allowance and a window pays the same whenever it is claimed.
            uint256 raw = _curve(priced, pos + total) - _curve(priced, pos);
            return (d.raw == 0 ? 0 : M.mulDiv(d.allowance, raw, d.raw), total);
        } else {
            pos = g.globalOrigin + (before_ - g.localOrigin) - _droppedView(vault, game, g, s);
        }
        budget = _curve(s, pos + total) - _curve(s, pos);
    }

    function windowBudget(address vault, address game, uint256 k)
        external
        view
        returns (uint256 budget, uint256 total)
    {
        (budget, total) = _rawBudget(vault, game, k);
        (bool prepared, uint256 cachedBudget,,,,) = IMiningView(vault).windowAccounting(game, k);
        if (prepared) budget = cachedBudget;
    }
}

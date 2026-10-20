// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OracleAttestation} from "./OracleAttestation.sol";
import {IIntake, IIntakeWithFailure, IERC20} from "./interfaces/IIntake.sol";

/// @title Hamster Hour v2
/// @notice Pari-mutuel IMD betting on the Squeekchain hamster wheel. No owner, pause, upgrade or
/// withdrawal power exists. TEAM (the launch wallet) holds only three 12-hour timelocked settings:
/// the OVER/UNDER line for future windows, the one-shot staking recipient and the one-shot tip jar
/// recipient. Every IMD unit that enters is assigned to a bucket (window funds, pull balances,
/// jackpot seed, jackpot liabilities, oracle reserve) so the contract always holds at least what
/// it owes. Results come only from IMD oracle v2 attestations signed for this contract's domain.
contract HamsterHour {
    using OracleAttestation for OracleAttestation.Attestation;

    // ----------------------------------------------------------------- constants
    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    uint64 public constant GENESIS = 1791847200;
    uint64 public constant ROUND_DURATION = 600;
    uint64 public constant WINDOW_ROUNDS = 6;
    uint64 public constant WINDOW_DURATION = ROUND_DURATION * WINDOW_ROUNDS;
    uint64 public constant TIMEOUT = 48 hours;
    uint64 public constant OPEN_AHEAD = 24 hours;
    uint64 public constant TIMELOCK = 12 hours;
    uint256 public constant MIN_BET = 0.5 ether;
    uint256 public constant TICKET_PRICE = 5 ether;
    uint256 public constant MAX_TICKETS = 256;
    uint256 public constant MAX_GUESS = type(uint64).max;
    uint256 public constant SNOOZE_THRESHOLD = 100;
    uint256 public constant INITIAL_LINE = 2100;
    uint256 public constant ORACLE_PRICE = 0.5 ether;
    /// @notice validForSeconds of the request body: a paid request that neither delivered nor
    /// failed within it is treated as lost, and a new one may be paid.
    uint64 public constant ORACLE_REQUEST_VALIDITY = 86400;
    /// @notice How long after a window's end an outstanding reserve-paid request may hold the public
    /// `settle` back. Half the timeout: whatever the Intake does, at least 24 hours of public
    /// settlement always remain before the window can only time out.
    uint64 public constant PUBLIC_SETTLE_HOLD = 24 hours;
    uint16 public constant MIN_PANEL = 5;
    uint16 public constant MIN_AGREED = 4;
    uint64 public constant ISSUED_AT_TOLERANCE = 5 minutes;
    bytes32 public constant ORACLE_ACTION = "oracle.request@oracle-1";
    string public constant SOURCE = "https://sepolia.squeekchain.com";

    // Binary fee split, in percent of the market pool.
    uint256 public constant BINARY_STAKERS_PCT = 5;
    uint256 public constant BINARY_JACKPOT_PCT = 2;
    uint256 public constant BINARY_ORACLE_PCT = 1;
    uint256 public constant BINARY_TEAM_PCT = 1;
    // EXACT ticket split; the remaining 93% is that window's jackpot contribution.
    uint256 public constant TICKET_STAKERS_PCT = 5;
    uint256 public constant TICKET_ORACLE_PCT = 1;
    uint256 public constant TICKET_TEAM_PCT = 1;
    uint256 public constant JACKPOT_PAYOUT_PCT = 80;
    uint256 public constant FEED_TIP_PCT = 10;

    bytes32 public constant SETTING_STAKING = keccak256("stakingRecipient");
    bytes32 public constant SETTING_TIP = keccak256("tipRecipient");

    // ----------------------------------------------------------------- immutables
    address public immutable TEAM;
    address public immutable ATTESTER;
    address public immutable INTAKE;

    // ----------------------------------------------------------------- types
    enum Status {
        None,
        Open,
        Settled,
        TimedOut
    }

    struct Window {
        Status status;
        bool allocated;
        bool finalized;
        uint32 tickets;
        uint32 jackpotWinners;
        uint64 startsAt;
        uint64 endsAt;
        uint128 over;
        uint128 under;
        uint128 yes;
        uint128 no;
        uint256 line;
        uint256 result;
        uint256 jackpotFees;
        uint256 jackpotContribution;
        uint256 jackpotShare;
        uint256 jackpotPot;
        bytes32 requestId;
    }

    struct Position {
        uint128 over;
        uint128 under;
        uint128 yes;
        uint128 no;
        uint64 guess;
        bool hasTicket;
        bool jackpotPaid;
        uint256 paid;
    }

    struct WindowView {
        uint256 index;
        Status status;
        uint64 startsAt;
        uint64 endsAt;
        uint64 closesAt;
        uint64 timeoutAt;
        uint256 line;
        uint256 result;
        uint256 over;
        uint256 under;
        uint256 yes;
        uint256 no;
        uint256 tickets;
        bool ouVoid;
        bool snVoid;
        bool feesAllocated;
        bool jackpotFinalized;
        uint256 jackpotPot;
        uint256 jackpotWinners;
        uint256 jackpotShare;
        uint256 pendingJackpotDeposits;
        bool oracleRequested;
        bool oracleRequestPending;
        bool publicSettleHeld;
        bytes32 intakeRequestId;
        bytes32 requestId;
    }

    struct Pending {
        bytes32 valueHash;
        uint64 readyAt;
    }

    // ----------------------------------------------------------------- storage
    mapping(uint256 => Window) internal _windows;
    mapping(uint256 => mapping(address => Position)) internal _positions;
    mapping(uint256 => uint64[]) internal _guesses;
    mapping(uint256 => uint256) public windowFunds;
    mapping(uint256 => uint256) public pendingJackpotDeposits;
    /// @notice When the latest reserve-paid request for a window was made; zero if never.
    mapping(uint256 => uint64) public oracleRequestedAt;
    /// @notice The Intake id of the latest reserve-paid request that has neither delivered nor failed.
    mapping(uint256 => bytes32) public pendingIntakeRequest;
    mapping(bytes32 => uint256) internal _intakeWindow;
    mapping(bytes32 => bool) public consumedRequest;
    mapping(bytes32 => Pending) public pendingSetting;
    mapping(address => uint256) public balances;

    uint256 internal _line = INITIAL_LINE;
    /// @notice A scheduled line change: applies to every window from `nextLineFrom` on, none of
    /// which can be bet on before `nextLineReadyAt`. Zero when nothing is scheduled.
    uint256 public nextLine;
    uint64 public nextLineReadyAt;
    uint256 public nextLineFrom;
    address public stakingRecipient;
    address public tipRecipient;
    uint256 public pendingStakingFees;
    uint256 public pendingTips;
    uint256 public oracleReserve;
    uint256 public jackpotSeed;
    uint256 public jackpotOutstanding;
    /// @notice Sum of every `pendingJackpotDeposits[k]` not yet finalized.
    uint256 public totalPendingJackpotDeposits;
    /// @notice Ticket contributions and 2% binary fees of settled windows not yet finalized.
    uint256 public jackpotInFlight;
    uint256 public nextFinalizeWindow;
    uint256 public cumulativeLoss;
    mapping(uint256 => uint256) public totalEligibleLoss;
    mapping(uint256 => uint256) public cumulativeLossBefore;
    mapping(uint256 => uint256) public cumulativeLossAfter;

    uint256 private _lock = 1;

    // ----------------------------------------------------------------- errors
    error ZeroAddress();
    error NotTeam();
    error Reentrancy();
    error TransferFailed();
    error WindowTooFar();
    error BettingClosed();
    error BelowMinimum();
    error PoolLimit();
    error InvalidGuess();
    error DuplicateTicket();
    error TicketsFull();
    error NotSettleable();
    error NotTimedOut();
    error NotFinal();
    error NothingToClaim();
    error WrongQuestion();
    error WrongChain();
    error InvalidAnswer();
    error WeakPanel();
    error InvalidValidity();
    error AttestationPredatesEnd();
    error AlreadyConsumed();
    error BadSignature();
    error NotIntake();
    error UnknownRequest();
    error AlreadyRequested();
    error PaidRequestPending();
    error NoFeePayingActivity();
    error ReserveTooLow();
    error InvalidAmount();
    error InvalidLine();
    error LineChangeInProgress();
    error AlreadySet();
    error TimelockNotReady();
    error NothingScheduled();

    // ----------------------------------------------------------------- events
    event WindowCreated(uint256 indexed k, uint64 startsAt, uint64 endsAt, uint256 line);
    event BinaryBet(uint256 indexed k, address indexed bettor, uint8 indexed market, bool side, uint256 amount);
    event TicketBought(uint256 indexed k, address indexed bettor, uint256 guess);
    event Settled(uint256 indexed k, uint256 result, bytes32 indexed requestId, address indexed settler);
    event MarketVoided(uint256 indexed k, uint8 indexed market);
    event TimedOut(uint256 indexed k);
    event FeesAllocated(uint256 indexed k, uint256 stakers, uint256 jackpot, uint256 oracle, uint256 team);
    event JackpotFinalized(uint256 indexed k, uint256 pot, uint256 winners, uint256 share, uint256 carried);
    event LossHistory(uint256 indexed k, uint256 totalEligibleLoss, uint256 cumulativeBefore, uint256 cumulativeAfter);
    event Claimed(uint256 indexed k, address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event Fed(address indexed from, uint256 amount);
    event JackpotDeposited(address indexed from, uint256 indexed k, uint256 amount);
    event OracleFunded(address indexed from, uint256 amount);
    event OracleRequested(uint256 indexed k, bytes32 indexed intakeRequestId, uint256 price, bool withFailureHook);
    event OracleRequestFailed(uint256 indexed k, bytes32 indexed intakeRequestId, uint8 status, bytes32 reason);
    event LineScheduled(uint256 line, uint64 readyAt, uint256 fromWindow);
    event LineApplied(uint256 line, uint256 fromWindow);
    event SettingScheduled(bytes32 indexed setting, bytes value, uint64 readyAt);
    event SettingExecuted(bytes32 indexed setting, bytes value);

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    modifier onlyTeam() {
        if (msg.sender != TEAM) revert NotTeam();
        _;
    }

    /// @param team_ The launch wallet. Receives the 1% TEAM share and holds the timelocked settings.
    /// @param attester_ IMD's oracle attester key, read from a real attestation (see README).
    /// @param intake_ IMD's on-chain Intake, which sells oracle requests for IMD.
    constructor(address team_, address attester_, address intake_) {
        if (team_ == address(0) || attester_ == address(0) || intake_ == address(0)) revert ZeroAddress();
        TEAM = team_;
        ATTESTER = attester_;
        INTAKE = intake_;
    }

    // ----------------------------------------------------------------- time
    function windowStart(uint256 k) public pure returns (uint64) {
        if (k > (type(uint64).max - GENESIS - TIMEOUT) / WINDOW_DURATION - 1) revert WindowTooFar();
        return GENESIS + uint64(k) * WINDOW_DURATION;
    }

    function windowEnd(uint256 k) public pure returns (uint64) {
        return windowStart(k) + WINDOW_DURATION;
    }

    /// @notice The window whose rounds contain `block.timestamp`; zero before genesis.
    function currentWindow() public view returns (uint256) {
        return block.timestamp < GENESIS ? 0 : (block.timestamp - GENESIS) / WINDOW_DURATION;
    }

    /// @notice The earliest window that has not started: where external jackpot deposits go.
    function earliestNotStartedWindow() public view returns (uint256) {
        return block.timestamp < GENESIS ? 0 : currentWindow() + 1;
    }

    function isBettingOpen(uint256 k) public view returns (bool) {
        uint64 startsAt = windowStart(k);
        return block.timestamp < startsAt && startsAt <= block.timestamp + OPEN_AHEAD;
    }

    // ----------------------------------------------------------------- betting
    /// @notice OVER (side = true) or UNDER (side = false) the window's line. Market id 0.
    function betOverUnder(uint256 k, bool over, uint256 amount) external nonReentrant {
        Window storage w = _openForBet(k, amount);
        Position storage p = _positions[k][msg.sender];
        if (over) {
            w.over = _add(w.over, amount);
            p.over = _add(p.over, amount);
        } else {
            w.under = _add(w.under, amount);
            p.under = _add(p.under, amount);
        }
        windowFunds[k] += amount;
        _pull(msg.sender, amount);
        emit BinaryBet(k, msg.sender, 0, over, amount);
    }

    /// @notice SNOOZE YES (side = true: result below 100) or NO. Market id 1.
    function betSnooze(uint256 k, bool yes, uint256 amount) external nonReentrant {
        Window storage w = _openForBet(k, amount);
        Position storage p = _positions[k][msg.sender];
        if (yes) {
            w.yes = _add(w.yes, amount);
            p.yes = _add(p.yes, amount);
        } else {
            w.no = _add(w.no, amount);
            p.no = _add(p.no, amount);
        }
        windowFunds[k] += amount;
        _pull(msg.sender, amount);
        emit BinaryBet(k, msg.sender, 1, yes, amount);
    }

    /// @notice One 5 IMD EXACT ticket per address per window; wins if within 0.5% of the result.
    function buyTicket(uint256 k, uint256 guess) external nonReentrant {
        Window storage w = _openForBet(k, TICKET_PRICE);
        if (guess > MAX_GUESS) revert InvalidGuess();
        Position storage p = _positions[k][msg.sender];
        if (p.hasTicket) revert DuplicateTicket();
        if (w.tickets >= MAX_TICKETS) revert TicketsFull();
        p.hasTicket = true;
        p.guess = uint64(guess);
        w.tickets += 1;
        _guesses[k].push(uint64(guess));
        windowFunds[k] += TICKET_PRICE;
        _pull(msg.sender, TICKET_PRICE);
        emit TicketBought(k, msg.sender, guess);
    }

    function _openForBet(uint256 k, uint256 amount) private returns (Window storage w) {
        if (amount < MIN_BET) revert BelowMinimum();
        if (!isBettingOpen(k)) revert BettingClosed();
        w = _windows[k];
        if (w.status == Status.None) {
            uint256 windowLine = lineFor(k);
            w.status = Status.Open;
            w.startsAt = windowStart(k);
            w.endsAt = windowEnd(k);
            w.line = windowLine;
            emit WindowCreated(k, w.startsAt, w.endsAt, windowLine);
        }
    }

    function _add(uint128 a, uint256 b) private pure returns (uint128) {
        uint256 c = uint256(a) + b;
        if (c > type(uint128).max) revert PoolLimit();
        return uint128(c);
    }

    // ----------------------------------------------------------------- oracle
    /// @notice The exact question text bound to window `k`'s six round ids, genesis and source.
    function question(uint256 k) public pure returns (string memory) {
        uint256 r = k * WINDOW_ROUNDS;
        return string.concat(
            "What is the total number of wheel passes recorded by Squeekchain for rounds ",
            _str(r),
            ", ",
            _str(r + 1),
            ", ",
            _str(r + 2),
            ", ",
            _str(r + 3),
            ", ",
            _str(r + 4),
            " and ",
            _str(r + 5),
            " (each round lasts 600 seconds and round 0 began at Unix time ",
            _str(GENESIS),
            "), as published at ",
            SOURCE,
            "? Answer as a single uint256 equal to the sum of the six published PASSES values. If any of the six rounds has not been published as settled, the question is unanswerable; never answer 0 for missing data."
        );
    }

    /// @notice Canonical IMD question document (sorted keys) whose keccak-256 the attestation carries.
    function questionDocument(uint256 k, uint64 fromBlock, uint64 toBlock) public view returns (string memory) {
        return string.concat(
            '{"answerType":"uint256","chainId":',
            _str(block.chainid),
            ',"evidence":"panel","question":"',
            question(k),
            '","v":1,"window":{"fromBlock":',
            _str(fromBlock),
            ',"toBlock":',
            _str(toBlock),
            "}}"
        );
    }

    function questionHash(uint256 k, uint64 fromBlock, uint64 toBlock) public view returns (bytes32) {
        return keccak256(bytes(questionDocument(k, fromBlock, toBlock)));
    }

    /// @notice The oracle.request body the contract sends to the Intake for window `k`.
    function requestBody(uint256 k) public view returns (string memory) {
        return string.concat(
            '{"v":1,"question":"',
            question(k),
            '","chainId":',
            _str(block.chainid),
            ',"window":{"hours":24},"answerType":"uint256","evidence":"panel","panelSize":5,"quorum":4,"validForSeconds":86400}'
        );
    }

    function attestationDigest(OracleAttestation.Attestation calldata a) public view returns (bytes32) {
        return a.digest(block.chainid, address(this));
    }

    /// @notice True while a reserve-paid request for `k` is outstanding: made, neither delivered nor
    /// failed, and younger than its validity. `requestOracle` refuses a second payment while it
    /// lasts; the public `settle` waits for it only while `publicSettleHeld(k)`.
    function oracleRequestPending(uint256 k) public view returns (bool) {
        return pendingIntakeRequest[k] != bytes32(0) && block.timestamp < oracleRequestedAt[k] + ORACLE_REQUEST_VALIDITY;
    }

    /// @notice True while the public `settle(k)` must wait for an outstanding reserve-paid request:
    /// never past `PUBLIC_SETTLE_HOLD` after the window's end, however many requests were paid, so a
    /// renewed request cannot keep a correctly signed attestation out until the timeout.
    function publicSettleHeld(uint256 k) public view returns (bool) {
        return oracleRequestPending(k) && block.timestamp < _windows[k].endsAt + PUBLIC_SETTLE_HOLD;
    }

    /// @notice True when window `k` can produce fees that refill the reserve: a two-sided binary
    /// market or at least one EXACT ticket. The reserve pays for no other window.
    function hasFeePayingActivity(uint256 k) public view returns (bool) {
        Window storage w = _windows[k];
        return (w.over > 0 && w.under > 0) || (w.yes > 0 && w.no > 0) || w.tickets > 0;
    }

    /// @notice Pays 0.5 IMD from the oracle reserve to the Intake for window `k`'s question. Anyone
    /// may call once the window has ended while it is settleable, once per outstanding request: a
    /// request that failed or lapsed (validity) may be replaced. The signed answer comes back
    /// through `onOracleResult`, a refusal or an empty panel through `onOracleFailure`.
    function requestOracle(uint256 k) external nonReentrant returns (bytes32 intakeRequestId) {
        Window storage w = _windows[k];
        if (w.status != Status.Open || block.timestamp < w.endsAt || block.timestamp >= w.endsAt + TIMEOUT) {
            revert NotSettleable();
        }
        if (!hasFeePayingActivity(k)) revert NoFeePayingActivity();
        if (oracleRequestPending(k)) revert AlreadyRequested();
        if (oracleReserve < ORACLE_PRICE) revert ReserveTooLow();
        oracleReserve -= ORACLE_PRICE;
        oracleRequestedAt[k] = uint64(block.timestamp);
        if (!IERC20(IMD).approve(INTAKE, ORACLE_PRICE)) revert TransferFailed();
        bool withFailureHook;
        (intakeRequestId, withFailureHook) = _requestFromIntake(bytes(requestBody(k)));
        pendingIntakeRequest[k] = intakeRequestId;
        _intakeWindow[intakeRequestId] = k + 1;
        emit OracleRequested(k, intakeRequestId, ORACLE_PRICE, withFailureHook);
    }

    /// @dev Prefers the variant with a failure hook; falls back to the plain `request` on an Intake
    /// that does not offer it, so the reserve can still buy answers there (without failure calls).
    function _requestFromIntake(bytes memory body) private returns (bytes32 intakeRequestId, bool withFailureHook) {
        IIntake.Callback memory callback = IIntake.Callback(address(this), this.onOracleResult.selector);
        (bool ok, bytes memory ret) = INTAKE.call(
            abi.encodeCall(
                IIntakeWithFailure.requestWithFailure,
                (ORACLE_ACTION, body, callback, this.onOracleFailure.selector, IMD, ORACLE_PRICE)
            )
        );
        if (ok) return (abi.decode(ret, (bytes32)), true);
        intakeRequestId = IIntake(INTAKE).request(ORACLE_ACTION, body, callback, IMD, ORACLE_PRICE);
    }

    /// @notice Intake callback with the signed answer to a request this contract paid for. Kept
    /// within the Intake's 200,000 gas stipend: it verifies and records the result only; fees are
    /// allocated later by `allocate(k)` or `finalize`. Claims never wait for that.
    function onOracleResult(bytes32 intakeRequestId, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
    {
        uint256 k = _takeIntakeRequest(intakeRequestId);
        _recordResult(k, _windows[k], a, signature);
    }

    /// @notice Intake failure hook: refused (status 1) or no result (status 2). Unsigned, so it only
    /// releases the window for a new reserve-paid request or a public `settle`; nothing moves.
    function onOracleFailure(bytes32 intakeRequestId, uint8 status, bytes32 reason, uint16, uint16, bytes calldata)
        external
    {
        uint256 k = _takeIntakeRequest(intakeRequestId);
        emit OracleRequestFailed(k, intakeRequestId, status, reason);
    }

    function _takeIntakeRequest(bytes32 intakeRequestId) private returns (uint256 k) {
        if (msg.sender != INTAKE) revert NotIntake();
        uint256 k1 = _intakeWindow[intakeRequestId];
        if (k1 == 0) revert UnknownRequest();
        delete _intakeWindow[intakeRequestId];
        k = k1 - 1;
        if (pendingIntakeRequest[k] == intakeRequestId) delete pendingIntakeRequest[k];
    }

    /// @notice Settles window `k` from an attestation anyone fetched from the IMD API, and allocates
    /// its fees. Refused while a reserve-paid request for `k` is outstanding and the window ended
    /// less than `PUBLIC_SETTLE_HOLD` ago, so the answer the contract paid for is the one that
    /// settles it; after that the public path is always open until the timeout.
    function settle(uint256 k, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
        nonReentrant
    {
        if (publicSettleHeld(k)) revert PaidRequestPending();
        Window storage w = _windows[k];
        _recordResult(k, w, a, signature);
        _allocate(k, w);
    }

    /// @notice Moves a settled window's fees to stakers, jackpot, reserve and TEAM. Permissionless,
    /// once per window; `finalize` runs it too. Claims do not depend on it.
    function allocate(uint256 k) external {
        Window storage w = _windows[k];
        if (w.status != Status.Settled) revert NotFinal();
        _allocate(k, w);
    }

    function _recordResult(
        uint256 k,
        Window storage w,
        OracleAttestation.Attestation calldata a,
        bytes calldata signature
    ) private {
        if (w.status != Status.Open || block.timestamp < w.endsAt || block.timestamp >= w.endsAt + TIMEOUT) {
            revert NotSettleable();
        }
        if (a.questionHash != questionHash(k, a.fromBlock, a.toBlock)) revert WrongQuestion();
        if (a.chainId != block.chainid) revert WrongChain();
        if (a.answerType != OracleAttestation.ANSWER_UINT256 || a.answer.length != 32) revert InvalidAnswer();
        if (
            a.panelSize < MIN_PANEL || a.agreed < MIN_AGREED || a.agreed < a.quorum || a.agreed > a.panelSize
                || a.quorum == 0
        ) revert WeakPanel();
        if (a.issuedAt < w.endsAt) revert AttestationPredatesEnd();
        if (a.issuedAt > block.timestamp + ISSUED_AT_TOLERANCE || a.issuedAt > a.expiresAt) revert InvalidValidity();
        if (block.timestamp > a.expiresAt) revert InvalidValidity();
        if (consumedRequest[a.requestId]) revert AlreadyConsumed();
        if (OracleAttestation.recover(attestationDigest(a), signature) != ATTESTER) revert BadSignature();
        consumedRequest[a.requestId] = true;

        uint256 result = abi.decode(a.answer, (uint256));
        w.status = Status.Settled;
        w.result = result;
        w.requestId = a.requestId;
        emit Settled(k, result, a.requestId, msg.sender);
    }

    function _allocate(uint256 k, Window storage w) private {
        if (w.allocated) return;
        w.allocated = true;
        uint256 stakers;
        uint256 jackpot;
        uint256 oracle;
        uint256 team;

        // OVER/UNDER: refunded fully when asleep or one-sided.
        if (_ouVoid(w)) {
            emit MarketVoided(k, 0);
        } else {
            uint256 pool = uint256(w.over) + w.under;
            stakers += pool * BINARY_STAKERS_PCT / 100;
            jackpot += pool * BINARY_JACKPOT_PCT / 100;
            oracle += pool * BINARY_ORACLE_PCT / 100;
            team += pool * BINARY_TEAM_PCT / 100;
        }
        // SNOOZE: refunded fully when one-sided.
        if (_snVoid(w)) {
            emit MarketVoided(k, 1);
        } else {
            uint256 pool = uint256(w.yes) + w.no;
            stakers += pool * BINARY_STAKERS_PCT / 100;
            jackpot += pool * BINARY_JACKPOT_PCT / 100;
            oracle += pool * BINARY_ORACLE_PCT / 100;
            team += pool * BINARY_TEAM_PCT / 100;
        }
        // EXACT tickets: 93% to this window's jackpot contribution, fees on the rest.
        if (w.tickets > 0) {
            uint256 pool = uint256(w.tickets) * TICKET_PRICE;
            uint256 s = pool * TICKET_STAKERS_PCT / 100;
            uint256 o = pool * TICKET_ORACLE_PCT / 100;
            uint256 t = pool * TICKET_TEAM_PCT / 100;
            w.jackpotContribution = pool - s - o - t;
            stakers += s;
            oracle += o;
            team += t;
        }
        w.jackpotFees = jackpot;
        jackpotInFlight += jackpot + w.jackpotContribution;
        windowFunds[k] -= stakers + jackpot + oracle + team + w.jackpotContribution;
        _creditStakers(stakers);
        oracleReserve += oracle;
        balances[TEAM] += team;
        emit FeesAllocated(k, stakers, jackpot, oracle, team);
    }

    /// @notice Permissionless terminal transition for a window nobody settled within 48 hours.
    function timeout(uint256 k) external {
        _timeout(k);
    }

    function _timeout(uint256 k) private {
        Window storage w = _windows[k];
        if (w.status != Status.Open) revert NotTimedOut();
        if (block.timestamp < w.endsAt + TIMEOUT) revert NotTimedOut();
        w.status = Status.TimedOut;
        emit TimedOut(k);
    }

    // ----------------------------------------------------------------- jackpot
    /// @notice Finalizes jackpot accounting and loss history strictly in window order, up to
    /// `maxWindows` windows. Stops at a window that is still open and not yet timed out, and at a
    /// window nobody created until it has started (from then on it can never be created).
    function finalize(uint256 maxWindows) external {
        uint256 k = nextFinalizeWindow;
        for (uint256 i; i < maxWindows; ++i) {
            Window storage w = _windows[k];
            if (w.status == Status.Open) {
                if (block.timestamp < w.endsAt + TIMEOUT) break;
                _timeout(k);
            } else if (w.status == Status.None) {
                if (block.timestamp < windowStart(k)) break;
            }
            _finalizeOne(k, w);
            unchecked {
                ++k;
            }
        }
        nextFinalizeWindow = k;
    }

    function _finalizeOne(uint256 k, Window storage w) private {
        uint256 deposits = pendingJackpotDeposits[k];
        uint256 pot = jackpotSeed + deposits;
        pendingJackpotDeposits[k] = 0;
        totalPendingJackpotDeposits -= deposits;
        uint256 winners;
        uint256 share;
        uint256 eligibleLoss;
        if (w.status == Status.Settled) {
            _allocate(k, w);
            uint256 inflow = w.jackpotContribution + w.jackpotFees;
            pot += inflow;
            jackpotInFlight -= inflow;
            if (w.result >= SNOOZE_THRESHOLD) {
                uint64[] storage guesses = _guesses[k];
                uint256 n = guesses.length;
                for (uint256 i; i < n; ++i) {
                    if (isWinningGuess(guesses[i], w.result)) ++winners;
                }
            }
            if (winners > 0) {
                share = pot * JACKPOT_PAYOUT_PCT / 100 / winners;
                w.jackpotWinners = uint32(winners);
                w.jackpotShare = share;
                jackpotOutstanding += share * winners;
            }
            eligibleLoss = _poolLoss(w);
        }
        w.jackpotPot = pot;
        w.finalized = true;
        jackpotSeed = pot - share * winners;
        totalEligibleLoss[k] = eligibleLoss;
        cumulativeLossBefore[k] = cumulativeLoss;
        cumulativeLoss += eligibleLoss;
        cumulativeLossAfter[k] = cumulativeLoss;
        emit JackpotFinalized(k, pot, winners, share, jackpotSeed);
        emit LossHistory(k, eligibleLoss, cumulativeLossBefore[k], cumulativeLoss);
    }

    /// @dev Pool-level netted loss of a settled window, with no loop over users: each losing side
    /// in full, plus a winning side's shortfall when the fee leaves it less than its stake.
    function _poolLoss(Window storage w) private view returns (uint256 total) {
        if (!_ouVoid(w)) {
            (uint256 win, uint256 lose) =
                w.result > w.line ? (uint256(w.over), uint256(w.under)) : (uint256(w.under), uint256(w.over));
            total += lose + _shortfall(win, _winnerPool(win + lose));
        }
        if (!_snVoid(w)) {
            (uint256 win, uint256 lose) =
                w.result < SNOOZE_THRESHOLD ? (uint256(w.yes), uint256(w.no)) : (uint256(w.no), uint256(w.yes));
            total += lose + _shortfall(win, _winnerPool(win + lose));
        }
    }

    function _shortfall(uint256 stake, uint256 payout) private pure returns (uint256) {
        return stake > payout ? stake - payout : 0;
    }

    /// @notice Wins iff |guess - result| * 1000 <= result * 5, evaluated without overflow.
    function isWinningGuess(uint256 guess, uint256 result) public pure returns (bool) {
        uint256 diff = guess > result ? guess - result : result - guess;
        if (diff > type(uint256).max / 200) return false;
        return diff * 200 <= result;
    }

    // ----------------------------------------------------------------- deposits
    /// @notice 90% to the jackpot (earliest not-started window), 10% to the Squeektoshi tip jar.
    function feedHamster(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        uint256 tip = amount * FEED_TIP_PCT / 100;
        _depositJackpot(amount - tip);
        if (tipRecipient == address(0)) pendingTips += tip;
        else balances[tipRecipient] += tip;
        _pull(msg.sender, amount);
        emit Fed(msg.sender, amount);
    }

    /// @notice External jackpot deposit (donations, a future token hook): all to the pending bucket.
    function depositJackpot(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        _depositJackpot(amount);
        _pull(msg.sender, amount);
    }

    function _depositJackpot(uint256 amount) private {
        uint256 k = earliestNotStartedWindow();
        pendingJackpotDeposits[k] += amount;
        totalPendingJackpotDeposits += amount;
        emit JackpotDeposited(msg.sender, k, amount);
    }

    /// @notice Anyone may top up the reserve that pays Intake oracle requests.
    function fundOracleReserve(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        oracleReserve += amount;
        _pull(msg.sender, amount);
        emit OracleFunded(msg.sender, amount);
    }

    // ----------------------------------------------------------------- claims
    /// @notice Pays everything window `k` owes the caller that has not been paid yet. Never expires;
    /// may be called again once the jackpot for `k` is finalized.
    function claim(uint256 k) external nonReentrant {
        Window storage w = _windows[k];
        if (w.status != Status.Settled && w.status != Status.TimedOut) revert NotFinal();
        Position storage p = _positions[k][msg.sender];
        (uint256 binary, uint256 ticket, uint256 jackpot) = _entitlements(w, p);
        // Window entitlements are fixed once terminal; the jackpot share appears at finalization.
        uint256 base = binary + ticket;
        uint256 dueBase = base - p.paid;
        uint256 dueJackpot = jackpot > 0 && !p.jackpotPaid ? jackpot : 0;
        uint256 due = dueBase + dueJackpot;
        if (due == 0) revert NothingToClaim();
        p.paid = base;
        if (dueJackpot > 0) p.jackpotPaid = true;
        windowFunds[k] -= dueBase;
        jackpotOutstanding -= dueJackpot;
        _push(msg.sender, due);
        emit Claimed(k, msg.sender, due);
    }

    /// @notice Pulls an accrued TEAM, tip jar, or staking recipient balance.
    function withdraw() external nonReentrant {
        uint256 amount = balances[msg.sender];
        if (amount == 0) revert NothingToClaim();
        balances[msg.sender] = 0;
        _push(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function _entitlements(Window storage w, Position storage p)
        private
        view
        returns (uint256 binary, uint256 ticket, uint256 jackpot)
    {
        if (w.status == Status.TimedOut) {
            binary = uint256(p.over) + p.under + p.yes + p.no;
            ticket = p.hasTicket ? TICKET_PRICE : 0;
        } else if (w.status == Status.Settled) {
            binary = _binaryEntitlement(w, p, false);
            if (p.hasTicket && w.finalized && w.jackpotShare > 0 && isWinningGuess(p.guess, w.result)) {
                jackpot = w.jackpotShare;
            }
        }
    }

    /// @dev Valid once settled: OVER/UNDER is void when asleep or one-sided.
    function _ouVoid(Window storage w) private view returns (bool) {
        return w.result < SNOOZE_THRESHOLD || w.over == 0 || w.under == 0;
    }

    /// @dev SNOOZE is void when one-sided.
    function _snVoid(Window storage w) private view returns (bool) {
        return w.yes == 0 || w.no == 0;
    }

    /// @notice What a two-sided binary pool pays its winners: the pool less the 9% of fees.
    function _winnerPool(uint256 pool) private pure returns (uint256) {
        return pool - pool * BINARY_STAKERS_PCT / 100 - pool * BINARY_JACKPOT_PCT / 100 - pool * BINARY_ORACLE_PCT / 100
            - pool * BINARY_TEAM_PCT / 100;
    }

    /// @dev Refunds plus pro-rata winnings of both binary markets. Claims round the pro-rata share
    /// down (`roundUp` false); the loss history rounds it up so no account's recorded loss exceeds
    /// its real one, which keeps the sum of `lossOf` within the pool-level `totalEligibleLoss`.
    function _binaryEntitlement(Window storage w, Position storage p, bool roundUp)
        private
        view
        returns (uint256 amount)
    {
        if (_ouVoid(w)) {
            amount = uint256(p.over) + p.under;
        } else {
            uint256 winners = _winnerPool(uint256(w.over) + w.under);
            if (w.result > w.line) amount = _share(p.over, winners, w.over, roundUp);
            else amount = _share(p.under, winners, w.under, roundUp);
        }
        if (_snVoid(w)) {
            amount += uint256(p.yes) + p.no;
        } else {
            uint256 winners = _winnerPool(uint256(w.yes) + w.no);
            if (w.result < SNOOZE_THRESHOLD) amount += _share(p.yes, winners, w.yes, roundUp);
            else amount += _share(p.no, winners, w.no, roundUp);
        }
    }

    /// @dev stake * pool / side, rounded down or up. Both factors fit 128 bits, so no overflow.
    function _share(uint256 stake, uint256 pool, uint256 side, bool roundUp) private pure returns (uint256 q) {
        uint256 product = stake * pool;
        q = product / side;
        if (roundUp && q * side < product) ++q;
    }

    function _loss(Window storage w, Position storage p) private view returns (uint256) {
        uint256 paid = uint256(p.over) + p.under + p.yes + p.no;
        uint256 back = _binaryEntitlement(w, p, true);
        return paid > back ? paid - back : 0;
    }

    // ----------------------------------------------------------------- views
    /// @notice Net binary principal lost by `account` in window `k`: max(0, paid - refunds - payouts),
    /// netted across OVER/UNDER and SNOOZE, EXACT excluded. Zero until settled; zero after a timeout.
    /// Payouts are rounded up here (claims round down), so the value is at most the real loss and
    /// never off by more than one unit per winning side; the sum over all accounts never exceeds
    /// `totalEligibleLoss[k]`.
    function lossOf(uint256 k, address account) external view returns (uint256) {
        Window storage w = _windows[k];
        if (w.status != Status.Settled) return 0;
        return _loss(w, _positions[k][account]);
    }

    /// @notice What `account` can still claim from window `k` right now.
    function claimable(uint256 k, address account) external view returns (uint256) {
        Window storage w = _windows[k];
        if (w.status != Status.Settled && w.status != Status.TimedOut) return 0;
        Position storage p = _positions[k][account];
        (uint256 b, uint256 t, uint256 j) = _entitlements(w, p);
        return b + t - p.paid + (p.jackpotPaid ? 0 : j);
    }

    function position(uint256 k, address account) external view returns (Position memory) {
        return _positions[k][account];
    }

    function guessAt(uint256 k, uint256 i) external view returns (uint256) {
        return _guesses[k][i];
    }

    /// @notice The OVER/UNDER line in force for new windows right now.
    function line() external view returns (uint256) {
        return lineFor(earliestNotStartedWindow());
    }

    /// @notice The line window `k` has, or will be created with. Fixed for every window from the
    /// moment it can be bet on: a scheduled change only reaches windows that open after it is ready.
    function lineFor(uint256 k) public view returns (uint256) {
        Window storage w = _windows[k];
        if (w.status != Status.None) return w.line;
        if (nextLine != 0 && k >= nextLineFrom) return nextLine;
        return _line;
    }

    /// @notice One view per window for the site and agents.
    function windowInfo(uint256 k) external view returns (WindowView memory v) {
        Window storage w = _windows[k];
        v.index = k;
        v.status = w.status;
        v.startsAt = windowStart(k);
        v.endsAt = windowEnd(k);
        v.closesAt = v.startsAt;
        v.timeoutAt = v.endsAt + TIMEOUT;
        v.line = lineFor(k);
        v.result = w.result;
        v.over = w.over;
        v.under = w.under;
        v.yes = w.yes;
        v.no = w.no;
        v.tickets = w.tickets;
        v.ouVoid = w.status == Status.Settled && _ouVoid(w);
        v.snVoid = w.status == Status.Settled && _snVoid(w);
        v.feesAllocated = w.allocated;
        v.jackpotFinalized = w.finalized;
        v.jackpotPot = w.jackpotPot;
        v.jackpotWinners = w.jackpotWinners;
        v.jackpotShare = w.jackpotShare;
        v.pendingJackpotDeposits = pendingJackpotDeposits[k];
        v.oracleRequested = oracleRequestedAt[k] != 0;
        v.oracleRequestPending = oracleRequestPending(k);
        v.publicSettleHeld = publicSettleHeld(k);
        v.intakeRequestId = pendingIntakeRequest[k];
        v.requestId = w.requestId;
    }

    /// @notice Sum of every IMD liability the contract tracks outside per-window funds (read with
    /// `windowFunds(k)`): pull balances, jackpot seed, fixed jackpot shares, jackpot money of settled
    /// windows awaiting finalization, pending external deposits, the oracle reserve and held fees.
    function trackedLiabilities() external view returns (uint256) {
        return _sumBalancesLess() + jackpotSeed + jackpotOutstanding + jackpotInFlight + totalPendingJackpotDeposits
            + oracleReserve + pendingStakingFees + pendingTips;
    }

    function _sumBalancesLess() private view returns (uint256 total) {
        total = balances[TEAM];
        if (stakingRecipient != address(0) && stakingRecipient != TEAM) total += balances[stakingRecipient];
        if (tipRecipient != address(0) && tipRecipient != TEAM && tipRecipient != stakingRecipient) {
            total += balances[tipRecipient];
        }
    }

    // ----------------------------------------------------------------- TEAM settings (12h timelock)
    /// @notice Schedules a new line. It is ready 12 hours later and applies to every window from
    /// `nextLineFrom` on, the first window that cannot be bet on before it is ready, so no window
    /// changes its line once it is open for bets. Overwriting an unready schedule is allowed; a
    /// ready one is locked in until every window below `nextLineFrom` has closed (24 hours).
    function scheduleLine(uint256 newLine) external onlyTeam {
        if (newLine == 0) revert InvalidLine();
        _foldLine();
        if (nextLine != 0 && block.timestamp >= nextLineReadyAt) revert LineChangeInProgress();
        uint64 readyAt = uint64(block.timestamp) + TIMELOCK;
        uint256 from = _firstWindowStartingAfter(readyAt + OPEN_AHEAD);
        nextLine = newLine;
        nextLineReadyAt = readyAt;
        nextLineFrom = from;
        emit LineScheduled(newLine, readyAt, from);
    }

    /// @dev Once every window below `nextLineFrom` has closed, the scheduled line is the only line.
    function _foldLine() private {
        if (nextLine != 0 && block.timestamp >= uint256(nextLineReadyAt) + OPEN_AHEAD) {
            _line = nextLine;
            emit LineApplied(nextLine, nextLineFrom);
            delete nextLine;
            delete nextLineReadyAt;
            delete nextLineFrom;
        }
    }

    function _firstWindowStartingAfter(uint256 t) private pure returns (uint256) {
        return t < GENESIS ? 0 : (t - GENESIS) / WINDOW_DURATION + 1;
    }

    function scheduleStakingRecipient(address recipient) external onlyTeam {
        if (recipient == address(0)) revert ZeroAddress();
        if (stakingRecipient != address(0)) revert AlreadySet();
        _schedule(SETTING_STAKING, abi.encode(recipient));
    }

    function executeStakingRecipient(address recipient) external onlyTeam {
        if (stakingRecipient != address(0)) revert AlreadySet();
        _execute(SETTING_STAKING, abi.encode(recipient));
        stakingRecipient = recipient;
        balances[recipient] += pendingStakingFees;
        pendingStakingFees = 0;
    }

    function scheduleTipRecipient(address recipient) external onlyTeam {
        if (recipient == address(0)) revert ZeroAddress();
        if (tipRecipient != address(0)) revert AlreadySet();
        _schedule(SETTING_TIP, abi.encode(recipient));
    }

    function executeTipRecipient(address recipient) external onlyTeam {
        if (tipRecipient != address(0)) revert AlreadySet();
        _execute(SETTING_TIP, abi.encode(recipient));
        tipRecipient = recipient;
        balances[recipient] += pendingTips;
        pendingTips = 0;
    }

    function _schedule(bytes32 setting, bytes memory value) private {
        uint64 readyAt = uint64(block.timestamp) + TIMELOCK;
        pendingSetting[setting] = Pending(keccak256(value), readyAt);
        emit SettingScheduled(setting, value, readyAt);
    }

    function _execute(bytes32 setting, bytes memory value) private {
        Pending memory p = pendingSetting[setting];
        if (p.readyAt == 0 || p.valueHash != keccak256(value)) revert NothingScheduled();
        if (block.timestamp < p.readyAt) revert TimelockNotReady();
        delete pendingSetting[setting];
        emit SettingExecuted(setting, value);
    }

    // ----------------------------------------------------------------- internals
    function _creditStakers(uint256 amount) private {
        if (amount == 0) return;
        if (stakingRecipient == address(0)) pendingStakingFees += amount;
        else balances[stakingRecipient] += amount;
    }

    function _pull(address from, uint256 amount) private {
        uint256 before = IERC20(IMD).balanceOf(address(this));
        if (!IERC20(IMD).transferFrom(from, address(this), amount)) revert TransferFailed();
        if (IERC20(IMD).balanceOf(address(this)) - before != amount) revert TransferFailed();
    }

    function _push(address to, uint256 amount) private {
        if (!IERC20(IMD).transfer(to, amount)) revert TransferFailed();
    }

    function _str(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            ++digits;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            --digits;
            buffer[digits] = bytes1(uint8(48 + value % 10));
            value /= 10;
        }
        return string(buffer);
    }
}

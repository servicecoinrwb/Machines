// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts@5.0.2/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts@5.0.2/token/ERC20/utils/SafeERC20.sol";

interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (
        uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound
    );
}

/**
 * Bellwether — parimutuel prediction markets in USDC on Arc
 *
 * Two sides, one pot. Everyone who backs the correct outcome splits the
 * whole pool in proportion to what they staked. There is no order book, no
 * counterparty to match, and no way for the contract to owe more than it
 * holds — the payout is always a division of money already deposited.
 *
 * THE HARD PART IS NEVER THE MONEY. IT IS WHO DECIDES THE FACT.
 *
 * A market is only as good as its resolution, so this contract makes the
 * resolver explicit and fixes it at creation, before anyone stakes a dollar.
 * You always know what you're trusting.
 *
 *   FEED        The market names a Chainlink-style price feed, a threshold
 *               and a comparison. After the close, anyone can settle and the
 *               contract reads the answer itself. Nobody decides anything —
 *               but this only works where such a feed exists.
 *
 *   OPTIMISTIC  Anyone proposes the outcome and posts a bond. A challenge
 *               window opens. Silence makes the proposal final and returns
 *               the bond. A challenger posts a matching bond, and the named
 *               arbiter rules — taking the losing bond as payment for the
 *               work. If the arbiter never rules, the market VOIDS and every
 *               stake is refunded in full.
 *
 * That last clause is the important one. A stuck market must not become a
 * confiscated one: when resolution fails, everyone gets their money back
 * rather than the pot sitting in a contract nobody can open.
 *
 * WHAT A CREATOR EARNS
 *
 * Defining a good question and standing behind its resolution is real work,
 * so the creator sets a fee — capped at 5%, taken from the pot only on a
 * genuine resolution. A voided market pays no fee to anyone, which is the
 * correct incentive: you are paid for markets that resolve, not for markets
 * you started.
 */
contract Bellwether {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- errors

    error ZeroAddress();
    error ZeroAmount();
    error BadWindow();
    error BadFee(uint16 bps, uint16 max);
    error NoSuchMarket();
    error NotOpen();
    error StillOpen();
    error AlreadyResolved();
    error NotProposable();
    error AlreadyProposed();
    error ChallengeOpen(uint64 until);
    error ChallengeClosed();
    error NotArbiter();
    error NotDisputed();
    error NotSettled();
    error NothingToClaim();
    error BelowMinStake(uint256 sent, uint256 min);
    error FeedStale(uint256 updatedAt);
    error FeedNotSet();
    error NotFeedMarket();
    error NotOptimisticMarket();
    error Reentrant();

    // ----------------------------------------------------------------- types

    enum Mode { Feed, Optimistic }
    enum Cmp  { Above, AtOrAbove, Below, AtOrBelow }
    enum State { Open, Pending, Disputed, Settled, Void }
    enum Side  { No, Yes }

    struct Market {
        address creator;
        address arbiter;        // optimistic only
        uint64  closesAt;       // staking ends
        uint64  resolvesAt;     // outcome knowable from here
        uint64  challengeEnds;  // set when a proposal lands
        uint64  voidAfter;      // arbiter deadline; past it, anyone can void
        uint128 poolYes;
        uint128 poolNo;
        uint128 bond;           // required to propose or challenge
        uint16  feeBps;
        Mode    mode;
        State   state;
        Side    outcome;
        bool    exists;
        bool    feeTaken;
        // feed mode
        address feed;
        int256  threshold;
        Cmp     cmp;
        // optimistic mode
        address proposer;
        address challenger;
        Side    proposed;
        string  question;
    }

    // -------------------------------------------------------------- constants

    uint16  public constant MAX_FEE_BPS = 500;      // 5%
    uint16  public constant BPS = 10_000;
    uint64  public constant MIN_STAKE_WINDOW = 5 minutes;
    uint64  public constant MIN_CHALLENGE = 5 minutes;
    uint256 public constant MIN_STAKE = 1e5;        // 0.10 USDC
    uint256 public constant FEED_MAX_AGE = 2 hours; // reject a stale answer

    // ----------------------------------------------------------------- state

    IERC20 public immutable token;
    uint256 public nextId = 1;

    mapping(uint256 => Market) private _m;
    mapping(uint256 => mapping(address => uint256)) private _stakeYes;
    mapping(uint256 => mapping(address => uint256)) private _stakeNo;
    mapping(uint256 => mapping(address => bool)) private _claimed;

    uint256 private _lock = 1;

    // ---------------------------------------------------------------- events

    event MarketOpened(uint256 indexed id, address indexed creator, string question, uint8 mode, uint64 closesAt, uint64 resolvesAt, uint16 feeBps);
    event Staked(uint256 indexed id, address indexed who, uint8 side, uint256 amount, uint256 poolYes, uint256 poolNo);
    event Proposed(uint256 indexed id, address indexed proposer, uint8 outcome, uint64 challengeEnds);
    event Challenged(uint256 indexed id, address indexed challenger);
    event Resolved(uint256 indexed id, uint8 outcome, uint256 pot, uint256 fee);
    event Voided(uint256 indexed id, string reason);
    event Claimed(uint256 indexed id, address indexed who, uint256 amount);

    // ------------------------------------------------------------- modifiers

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrant();
        _lock = 2; _; _lock = 1;
    }

    constructor(IERC20 usdc) {
        if (address(usdc) == address(0)) revert ZeroAddress();
        token = usdc;
    }

    // ------------------------------------------------------------------ open

    /// @notice A market that settles itself from a price feed. No human decides.
    function openFeedMarket(
        string calldata question,
        address feed,
        int256 threshold,
        Cmp cmp,
        uint64 closesAt,
        uint64 resolvesAt,
        uint16 feeBps
    ) external returns (uint256 id) {
        if (feed == address(0)) revert FeedNotSet();
        id = _open(question, Mode.Feed, closesAt, resolvesAt, feeBps, address(0), 0);
        Market storage m = _m[id];
        m.feed = feed;
        m.threshold = threshold;
        m.cmp = cmp;
    }

    /**
     * @notice A market resolved by people, with a bond and a named arbiter.
     * @param arbiter Who rules if a proposal is challenged. Named up front so
     *        stakers know exactly whose judgement they're accepting.
     * @param bond What a proposer or challenger must post. Should exceed the
     *        cost of the arbiter's attention, or challenges become free.
     */
    function openOptimisticMarket(
        string calldata question,
        address arbiter,
        uint128 bond,
        uint64 closesAt,
        uint64 resolvesAt,
        uint16 feeBps
    ) external returns (uint256 id) {
        if (arbiter == address(0)) revert ZeroAddress();
        if (bond == 0) revert ZeroAmount();
        id = _open(question, Mode.Optimistic, closesAt, resolvesAt, feeBps, arbiter, bond);
    }

    function _open(
        string calldata question,
        Mode mode,
        uint64 closesAt,
        uint64 resolvesAt,
        uint16 feeBps,
        address arbiter,
        uint128 bond
    ) internal returns (uint256 id) {
        if (feeBps > MAX_FEE_BPS) revert BadFee(feeBps, MAX_FEE_BPS);
        if (closesAt < block.timestamp + MIN_STAKE_WINDOW) revert BadWindow();
        if (resolvesAt < closesAt) revert BadWindow();

        id = nextId++;
        Market storage m = _m[id];
        m.creator = msg.sender;
        m.arbiter = arbiter;
        m.closesAt = closesAt;
        m.resolvesAt = resolvesAt;
        m.bond = bond;
        m.feeBps = feeBps;
        m.mode = mode;
        m.state = State.Open;
        m.exists = true;
        m.question = question;

        emit MarketOpened(id, msg.sender, question, uint8(mode), closesAt, resolvesAt, feeBps);
    }

    // ----------------------------------------------------------------- stake

    /// @notice Back an outcome. Your share of the pot is your share of the
    ///         winning pool — no odds are locked in, they move as others stake.
    function stake(uint256 id, Side side, uint256 amount) external nonReentrant {
        Market storage m = _m[id];
        if (!m.exists) revert NoSuchMarket();
        if (m.state != State.Open) revert NotOpen();
        if (block.timestamp >= m.closesAt) revert NotOpen();
        if (amount < MIN_STAKE) revert BelowMinStake(amount, MIN_STAKE);

        if (side == Side.Yes) {
            _stakeYes[id][msg.sender] += amount;
            m.poolYes += uint128(amount);
        } else {
            _stakeNo[id][msg.sender] += amount;
            m.poolNo += uint128(amount);
        }

        emit Staked(id, msg.sender, uint8(side), amount, m.poolYes, m.poolNo);
        token.safeTransferFrom(msg.sender, address(this), amount);
    }

    // ------------------------------------------------------------- resolution

    /// @notice Settle a feed market. Anyone may call it; the feed decides.
    function settleFromFeed(uint256 id) external nonReentrant {
        Market storage m = _m[id];
        if (!m.exists) revert NoSuchMarket();
        if (m.mode != Mode.Feed) revert NotFeedMarket();
        if (m.state != State.Open) revert AlreadyResolved();
        if (block.timestamp < m.resolvesAt) revert StillOpen();

        (, int256 answer, , uint256 updatedAt, ) = IAggregatorV3(m.feed).latestRoundData();
        // A frozen feed must not silently decide a market.
        if (updatedAt == 0 || block.timestamp - updatedAt > FEED_MAX_AGE) revert FeedStale(updatedAt);

        bool yes;
        if (m.cmp == Cmp.Above)           yes = answer >  m.threshold;
        else if (m.cmp == Cmp.AtOrAbove)  yes = answer >= m.threshold;
        else if (m.cmp == Cmp.Below)      yes = answer <  m.threshold;
        else                              yes = answer <= m.threshold;

        _finalize(id, m, yes ? Side.Yes : Side.No);
    }

    /// @notice Claim an outcome on an optimistic market, backed by a bond.
    function propose(uint256 id, Side outcome) external nonReentrant {
        Market storage m = _m[id];
        if (!m.exists) revert NoSuchMarket();
        if (m.mode != Mode.Optimistic) revert NotOptimisticMarket();
        if (m.state != State.Open) revert NotProposable();
        if (block.timestamp < m.resolvesAt) revert StillOpen();

        m.state = State.Pending;
        m.proposer = msg.sender;
        m.proposed = outcome;
        m.challengeEnds = uint64(block.timestamp) + MIN_CHALLENGE;

        emit Proposed(id, msg.sender, uint8(outcome), m.challengeEnds);
        token.safeTransferFrom(msg.sender, address(this), m.bond);
    }

    /// @notice Disagree with a proposal, backed by a matching bond.
    function challenge(uint256 id) external nonReentrant {
        Market storage m = _m[id];
        if (!m.exists) revert NoSuchMarket();
        if (m.state != State.Pending) revert NotProposable();
        if (block.timestamp >= m.challengeEnds) revert ChallengeClosed();

        m.state = State.Disputed;
        m.challenger = msg.sender;
        // The arbiter has a deadline. Past it the market voids and every
        // stake is refunded — a silent arbiter must not trap the pot.
        m.voidAfter = uint64(block.timestamp) + 7 days;

        emit Challenged(id, msg.sender);
        token.safeTransferFrom(msg.sender, address(this), m.bond);
    }

    /// @notice Nobody objected. Anyone can finalize it.
    function finalizeUnchallenged(uint256 id) external nonReentrant {
        Market storage m = _m[id];
        if (!m.exists) revert NoSuchMarket();
        if (m.state != State.Pending) revert NotProposable();
        if (block.timestamp < m.challengeEnds) revert ChallengeOpen(m.challengeEnds);

        address proposer = m.proposer;
        uint256 bond = m.bond;
        _finalize(id, m, m.proposed);
        token.safeTransfer(proposer, bond);   // honest proposal, bond returned
    }

    /// @notice The named arbiter rules. The losing bond pays for their time.
    function rule(uint256 id, Side outcome) external nonReentrant {
        Market storage m = _m[id];
        if (!m.exists) revert NoSuchMarket();
        if (m.state != State.Disputed) revert NotDisputed();
        if (msg.sender != m.arbiter) revert NotArbiter();

        address winner = (outcome == m.proposed) ? m.proposer : m.challenger;
        uint256 bond = m.bond;
        address arb = m.arbiter;

        _finalize(id, m, outcome);

        token.safeTransfer(winner, bond);   // correct party's bond returned
        token.safeTransfer(arb, bond);      // loser's bond pays the arbiter
    }

    /**
     * @notice Give up and refund everyone. Callable when the arbiter has gone
     *         silent past the deadline, or when a resolved market has nobody
     *         on the winning side.
     */
    function voidMarket(uint256 id) external nonReentrant {
        Market storage m = _m[id];
        if (!m.exists) revert NoSuchMarket();
        if (m.state == State.Settled || m.state == State.Void) revert AlreadyResolved();
        if (m.state != State.Disputed || block.timestamp < m.voidAfter) revert NotDisputed();

        m.state = State.Void;
        emit Voided(id, "arbiter did not rule");

        // Both bonds go back — neither party is at fault for the silence.
        token.safeTransfer(m.proposer, m.bond);
        token.safeTransfer(m.challenger, m.bond);
    }

    function _finalize(uint256 id, Market storage m, Side outcome) internal {
        uint256 winPool = outcome == Side.Yes ? m.poolYes : m.poolNo;

        // A one-sided market has no market in it. Refund rather than hand the
        // whole pot to the only participants for guessing unopposed.
        if (winPool == 0 || m.poolYes == 0 || m.poolNo == 0) {
            m.state = State.Void;
            emit Voided(id, "no opposing stakes");
            return;
        }

        m.outcome = outcome;
        m.state = State.Settled;

        uint256 pot = uint256(m.poolYes) + uint256(m.poolNo);
        uint256 fee = (pot * m.feeBps) / BPS;
        if (fee > 0) {
            m.feeTaken = true;
            token.safeTransfer(m.creator, fee);
        }
        emit Resolved(id, uint8(outcome), pot, fee);
    }

    // ----------------------------------------------------------------- claim

    /// @notice Collect winnings, or a refund on a voided market.
    function claim(uint256 id) external nonReentrant {
        Market storage m = _m[id];
        if (!m.exists) revert NoSuchMarket();
        if (m.state != State.Settled && m.state != State.Void) revert NotSettled();
        if (_claimed[id][msg.sender]) revert NothingToClaim();

        uint256 owed = _owed(id, m, msg.sender);
        if (owed == 0) revert NothingToClaim();

        _claimed[id][msg.sender] = true;
        emit Claimed(id, msg.sender, owed);
        token.safeTransfer(msg.sender, owed);
    }

    function _owed(uint256 id, Market storage m, address who) internal view returns (uint256) {
        if (m.state == State.Void) {
            return _stakeYes[id][who] + _stakeNo[id][who];   // full refund
        }
        uint256 mine = m.outcome == Side.Yes ? _stakeYes[id][who] : _stakeNo[id][who];
        if (mine == 0) return 0;

        uint256 pot = uint256(m.poolYes) + uint256(m.poolNo);
        uint256 fee = (pot * m.feeBps) / BPS;
        uint256 payable_ = pot - fee;
        uint256 winPool = m.outcome == Side.Yes ? m.poolYes : m.poolNo;

        // Floor division: the contract can never owe more than it holds. The
        // few units of rounding dust stay put rather than being handed to
        // whoever claims last.
        return (payable_ * mine) / winPool;
    }

    // ----------------------------------------------------------------- views

    struct MarketView {
        bool exists;
        address creator;
        address arbiter;
        string question;
        uint8 mode;
        uint8 state;
        uint8 outcome;
        uint256 poolYes;
        uint256 poolNo;
        uint256 bond;
        uint16 feeBps;
        uint64 closesAt;
        uint64 resolvesAt;
        uint64 challengeEnds;
        uint64 voidAfter;
        address feed;
        int256 threshold;
        uint8 cmp;
        address proposer;
        uint8 proposed;
    }

    function getMarket(uint256 id) external view returns (MarketView memory v) {
        Market storage m = _m[id];
        if (!m.exists) return v;
        v.exists = true;
        v.creator = m.creator;
        v.arbiter = m.arbiter;
        v.question = m.question;
        v.mode = uint8(m.mode);
        v.state = uint8(m.state);
        v.outcome = uint8(m.outcome);
        v.poolYes = m.poolYes;
        v.poolNo = m.poolNo;
        v.bond = m.bond;
        v.feeBps = m.feeBps;
        v.closesAt = m.closesAt;
        v.resolvesAt = m.resolvesAt;
        v.challengeEnds = m.challengeEnds;
        v.voidAfter = m.voidAfter;
        v.feed = m.feed;
        v.threshold = m.threshold;
        v.cmp = uint8(m.cmp);
        v.proposer = m.proposer;
        v.proposed = uint8(m.proposed);
    }

    function positionOf(uint256 id, address who)
        external
        view
        returns (uint256 yes, uint256 no, bool claimed, uint256 claimable)
    {
        Market storage m = _m[id];
        yes = _stakeYes[id][who];
        no = _stakeNo[id][who];
        claimed = _claimed[id][who];
        claimable = (!m.exists || claimed || (m.state != State.Settled && m.state != State.Void))
            ? 0 : _owed(id, m, who);
    }

    /// @notice What a stake of `amount` on `side` would return if that side
    ///         wins and nothing else changes. Odds move as others stake, so
    ///         this is a snapshot, never a promise.
    function quote(uint256 id, Side side, uint256 amount) external view returns (uint256 payout) {
        Market storage m = _m[id];
        if (!m.exists || amount == 0) return 0;
        uint256 pot = uint256(m.poolYes) + uint256(m.poolNo) + amount;
        uint256 winPool = (side == Side.Yes ? uint256(m.poolYes) : uint256(m.poolNo)) + amount;
        uint256 fee = (pot * m.feeBps) / BPS;
        return ((pot - fee) * amount) / winPool;
    }

    /// @notice Everything the contract still owes on a market, for auditing.
    function outstandingOf(uint256 id) external view returns (uint256) {
        Market storage m = _m[id];
        if (!m.exists) return 0;
        uint256 pot = uint256(m.poolYes) + uint256(m.poolNo);
        if (m.state == State.Settled && m.feeTaken) {
            pot -= (pot * m.feeBps) / BPS;
        }
        return pot;
    }

    /// @dev No owner, no admin, no pause. Once a market is open its rules are
    ///      fixed and nobody — including its creator — can change them.
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts@5.0.2/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts@5.0.2/token/ERC20/utils/SafeERC20.sol";

/**
 * Reckoning — shared expense ledgers settled in USDC on Arc
 *
 * Six people on a trip. One buys the groceries, another the gas, a third
 * covers two nights of the cabin. By Sunday everybody owes everybody and
 * the group settles it with a spreadsheet, a lot of Venmo, and one person
 * quietly eating forty dollars because chasing it isn't worth the phone
 * call.
 *
 * WHAT THIS ACTUALLY SOLVES
 *
 * Not the arithmetic — a spreadsheet does that. What it solves is that
 * the arithmetic and the money live in different places, so the ledger is
 * always somebody's memory and settlement is always somebody's nagging.
 * Here the balance and the payment are the same object.
 *
 * EXPENSES ARE CLAIMS. SETTLEMENT IS REAL.
 *
 * Nobody buys groceries with USDC, so expenses are logged after the fact:
 * a member records what they paid and who owed a share of it. That's a
 * claim about the world, and a public chain can't verify it — so any
 * member named in a split can void an expense inside a challenge window,
 * no bond, no arbiter. It's your friends; the recourse is saying "I didn't
 * agree to that" before the window closes.
 *
 * Settlement is not a claim. Debtors pay real USDC into the ledger and
 * creditors withdraw it, and that part the contract enforces exactly.
 *
 * WHY THERE ARE NO PAIRWISE TRANSFERS
 *
 * The obvious design has Alice pay Bob 40 and Bob pay Carol 15. It reduces
 * to fewer transactions on paper, but it also means Carol's money is
 * hostage to Bob's diligence — one person who never gets round to it
 * strands everyone downstream of them.
 *
 * Instead everyone settles against the ledger. Debtors pay in what they
 * owe, creditors take out what they're owed, and nobody waits on anybody
 * in particular. Total in always equals total out, because every expense
 * credits exactly as much as it debits.
 */
contract Reckoning {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- errors

    error ZeroAddress();
    error ZeroAmount();
    error NoSuchLedger();
    error NotMember();
    error AlreadyMember();
    error TooManyMembers();
    error NoMembers();
    error LedgerClosed();
    error NotCreator();
    error NoSuchExpense();
    error AlreadyVoided();
    error VoidWindowClosed();
    error NotInSplit();
    error SplitMismatch(uint256 sumOfShares, uint256 total);
    error EmptySplit();
    error PayerNotMember();
    error NothingOwed();
    error NothingAvailable();
    error OverSettling(uint256 sent, uint256 owed);
    error HasBalances();
    error Reentrant();

    // ----------------------------------------------------------------- types

    struct Expense {
        address logger;
        address payer;
        uint128 total;
        uint64  loggedAt;
        bool    voided;
        string  note;
    }

    struct Ledger {
        address creator;
        uint32  voidWindow;     // seconds a member has to reject an expense
        bool    exists;
        bool    closed;
        uint128 pot;            // USDC sitting here, settled but unclaimed
        string  name;
    }

    // -------------------------------------------------------------- constants

    uint256 public constant MAX_MEMBERS = 24;
    uint256 public constant MAX_SPLIT = 24;
    uint32  public constant MIN_VOID_WINDOW = 1 minutes;
    uint32  public constant MAX_VOID_WINDOW = 30 days;

    // ----------------------------------------------------------------- state

    IERC20 public immutable token;
    uint256 public nextId = 1;

    mapping(uint256 => Ledger) private _l;
    mapping(uint256 => address[]) private _members;
    mapping(uint256 => mapping(address => bool)) private _isMember;

    /// @dev Signed net position. Positive means the ledger owes them.
    mapping(uint256 => mapping(address => int256)) private _net;

    mapping(uint256 => Expense[]) private _expenses;
    /// @dev expense index => member => their share of it
    mapping(uint256 => mapping(uint256 => mapping(address => uint256))) private _share;
    mapping(uint256 => mapping(uint256 => address[])) private _splitOf;

    uint256 private _lock = 1;

    // ---------------------------------------------------------------- events

    event LedgerOpened(uint256 indexed id, address indexed creator, string name, uint256 memberCount, uint32 voidWindow);
    event MemberAdded(uint256 indexed id, address indexed who);
    event ExpenseLogged(uint256 indexed id, uint256 indexed index, address indexed payer, uint256 total, string note, uint64 voidableUntil);
    event ExpenseVoided(uint256 indexed id, uint256 indexed index, address indexed by);
    event Settled(uint256 indexed id, address indexed who, uint256 amount, int256 netAfter);
    event Withdrawn(uint256 indexed id, address indexed who, uint256 amount, int256 netAfter);
    event LedgerClosedEvent(uint256 indexed id);

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrant();
        _lock = 2; _; _lock = 1;
    }

    constructor(IERC20 usdc) {
        if (address(usdc) == address(0)) revert ZeroAddress();
        token = usdc;
    }

    // ---------------------------------------------------------------- ledgers

    function openLedger(
        string calldata name,
        address[] calldata members,
        uint32 voidWindow
    ) external returns (uint256 id) {
        if (members.length == 0) revert NoMembers();
        if (members.length > MAX_MEMBERS) revert TooManyMembers();
        if (voidWindow < MIN_VOID_WINDOW || voidWindow > MAX_VOID_WINDOW) revert VoidWindowClosed();

        id = nextId++;
        _l[id] = Ledger({
            creator: msg.sender,
            voidWindow: voidWindow,
            exists: true,
            closed: false,
            pot: 0,
            name: name
        });

        // The creator is always a member — you can't run a ledger you're
        // not part of and then log expenses against everyone else.
        _addMember(id, msg.sender);
        for (uint256 i = 0; i < members.length; i++) {
            if (members[i] == address(0)) revert ZeroAddress();
            if (!_isMember[id][members[i]]) _addMember(id, members[i]);
        }

        emit LedgerOpened(id, msg.sender, name, _members[id].length, voidWindow);
    }

    function _addMember(uint256 id, address who) internal {
        if (_members[id].length >= MAX_MEMBERS) revert TooManyMembers();
        _isMember[id][who] = true;
        _members[id].push(who);
        emit MemberAdded(id, who);
    }

    /// @notice Someone joined the trip late.
    function addMember(uint256 id, address who) external {
        Ledger storage L = _l[id];
        if (!L.exists) revert NoSuchLedger();
        if (L.closed) revert LedgerClosed();
        if (msg.sender != L.creator) revert NotCreator();
        if (who == address(0)) revert ZeroAddress();
        if (_isMember[id][who]) revert AlreadyMember();
        _addMember(id, who);
    }

    /// @dev Only closable once everybody is square, so closing can never
    ///      strand a balance.
    function closeLedger(uint256 id) external {
        Ledger storage L = _l[id];
        if (!L.exists) revert NoSuchLedger();
        if (msg.sender != L.creator) revert NotCreator();
        if (L.closed) revert LedgerClosed();
        address[] storage ms = _members[id];
        for (uint256 i = 0; i < ms.length; i++) {
            if (_net[id][ms[i]] != 0) revert HasBalances();
        }
        L.closed = true;
        emit LedgerClosedEvent(id);
    }

    // --------------------------------------------------------------- expenses

    /**
     * @notice Record something one person paid for on behalf of several.
     * @param shares Exactly what each named member owes. Must sum to total.
     * @dev Shares are explicit rather than computed, so an uneven split —
     *      one person had the steak — is exact and no rounding dust can
     *      appear. An equal split is just the caller doing the division.
     */
    function logExpense(
        uint256 id,
        address payer,
        uint256 total,
        address[] calldata debtors,
        uint256[] calldata shares,
        string calldata note
    ) external returns (uint256 index) {
        Ledger storage L = _l[id];
        if (!L.exists) revert NoSuchLedger();
        if (L.closed) revert LedgerClosed();
        if (!_isMember[id][msg.sender]) revert NotMember();
        if (!_isMember[id][payer]) revert PayerNotMember();
        if (total == 0) revert ZeroAmount();
        if (debtors.length == 0) revert EmptySplit();
        if (debtors.length > MAX_SPLIT) revert TooManyMembers();
        if (debtors.length != shares.length) revert SplitMismatch(0, total);

        uint256 sum;
        for (uint256 i = 0; i < debtors.length; i++) {
            if (!_isMember[id][debtors[i]]) revert NotMember();
            if (shares[i] == 0) revert ZeroAmount();
            sum += shares[i];
        }
        if (sum != total) revert SplitMismatch(sum, total);

        index = _expenses[id].length;
        _expenses[id].push(Expense({
            logger: msg.sender,
            payer: payer,
            total: uint128(total),
            loggedAt: uint64(block.timestamp),
            voided: false,
            note: note
        }));

        for (uint256 i = 0; i < debtors.length; i++) {
            _share[id][index][debtors[i]] = shares[i];
            _splitOf[id][index].push(debtors[i]);
            _net[id][debtors[i]] -= int256(shares[i]);
        }
        _net[id][payer] += int256(total);

        emit ExpenseLogged(id, index, payer, total, note, uint64(block.timestamp) + L.voidWindow);
    }

    /**
     * @notice Reject an expense you were named in. No bond, no arbiter —
     *         the whole point is that this is your friends and the recourse
     *         is speaking up before the window closes.
     * @dev The payer can void their own too, for a mistyped amount.
     */
    function voidExpense(uint256 id, uint256 index) external {
        Ledger storage L = _l[id];
        if (!L.exists) revert NoSuchLedger();
        if (index >= _expenses[id].length) revert NoSuchExpense();

        Expense storage e = _expenses[id][index];
        if (e.voided) revert AlreadyVoided();
        if (block.timestamp > uint256(e.loggedAt) + L.voidWindow) revert VoidWindowClosed();

        bool allowed = (msg.sender == e.payer) || (msg.sender == e.logger) || (_share[id][index][msg.sender] > 0);
        if (!allowed) revert NotInSplit();

        e.voided = true;

        // Unwind it exactly.
        address[] storage sp = _splitOf[id][index];
        for (uint256 i = 0; i < sp.length; i++) {
            _net[id][sp[i]] += int256(_share[id][index][sp[i]]);
        }
        _net[id][e.payer] -= int256(uint256(e.total));

        emit ExpenseVoided(id, index, msg.sender);
    }

    // ------------------------------------------------------------- settlement

    /// @notice Pay what you owe into the ledger. Creditors draw from it.
    /// @param amount 0 settles the full amount owed.
    function settle(uint256 id, uint256 amount) external nonReentrant {
        Ledger storage L = _l[id];
        if (!L.exists) revert NoSuchLedger();
        if (!_isMember[id][msg.sender]) revert NotMember();

        int256 net = _net[id][msg.sender];
        if (net >= 0) revert NothingOwed();
        uint256 owed = uint256(-net);

        uint256 amt = amount == 0 ? owed : amount;
        if (amt > owed) revert OverSettling(amt, owed);

        _net[id][msg.sender] = net + int256(amt);
        L.pot += uint128(amt);

        emit Settled(id, msg.sender, amt, _net[id][msg.sender]);
        token.safeTransferFrom(msg.sender, address(this), amt);
    }

    /**
     * @notice Take what the ledger owes you, up to what's been paid in.
     * @dev First come, first served against the pot. Pro-rata would be
     *      fairer in the abstract and worse in practice — it would mean
     *      nobody can be made whole until everybody has paid, which is
     *      exactly the deadlock this design exists to avoid.
     */
    function withdraw(uint256 id, uint256 amount) external nonReentrant {
        Ledger storage L = _l[id];
        if (!L.exists) revert NoSuchLedger();
        if (!_isMember[id][msg.sender]) revert NotMember();

        int256 net = _net[id][msg.sender];
        if (net <= 0) revert NothingOwed();
        uint256 due = uint256(net);
        uint256 avail = due < L.pot ? due : L.pot;
        if (avail == 0) revert NothingAvailable();

        uint256 amt = amount == 0 ? avail : amount;
        if (amt > avail) revert NothingAvailable();

        _net[id][msg.sender] = net - int256(amt);
        L.pot -= uint128(amt);

        emit Withdrawn(id, msg.sender, amt, _net[id][msg.sender]);
        token.safeTransfer(msg.sender, amt);
    }

    // ----------------------------------------------------------------- views

    struct LedgerView {
        bool exists;
        address creator;
        string name;
        bool closed;
        uint32 voidWindow;
        uint256 pot;
        uint256 memberCount;
        uint256 expenseCount;
        uint256 totalLogged;   // sum of live expenses
        uint256 owedOut;       // total the ledger owes creditors
        uint256 owedIn;        // total debtors still owe
    }

    function getLedger(uint256 id) external view returns (LedgerView memory v) {
        Ledger storage L = _l[id];
        if (!L.exists) return v;
        v.exists = true;
        v.creator = L.creator;
        v.name = L.name;
        v.closed = L.closed;
        v.voidWindow = L.voidWindow;
        v.pot = L.pot;
        v.memberCount = _members[id].length;
        v.expenseCount = _expenses[id].length;

        Expense[] storage es = _expenses[id];
        for (uint256 i = 0; i < es.length; i++) {
            if (!es[i].voided) v.totalLogged += es[i].total;
        }
        address[] storage ms = _members[id];
        for (uint256 i = 0; i < ms.length; i++) {
            int256 n = _net[id][ms[i]];
            if (n > 0) v.owedOut += uint256(n);
            else if (n < 0) v.owedIn += uint256(-n);
        }
    }

    struct Balance {
        address who;
        int256 net;         // + owed to them, - they owe
        uint256 claimable;  // what they could withdraw right now
    }

    /// @notice Everyone's position in one call — the whole point of the thing.
    function balances(uint256 id) external view returns (Balance[] memory out) {
        address[] storage ms = _members[id];
        Ledger storage L = _l[id];
        out = new Balance[](ms.length);
        for (uint256 i = 0; i < ms.length; i++) {
            int256 n = _net[id][ms[i]];
            uint256 c = 0;
            if (n > 0) c = uint256(n) < L.pot ? uint256(n) : L.pot;
            out[i] = Balance({who: ms[i], net: n, claimable: c});
        }
    }

    function memberList(uint256 id) external view returns (address[] memory) {
        return _members[id];
    }

    struct ExpenseView {
        address logger;
        address payer;
        uint256 total;
        uint64 loggedAt;
        uint64 voidableUntil;
        bool voided;
        string note;
        address[] debtors;
        uint256[] shares;
    }

    function getExpense(uint256 id, uint256 index) external view returns (ExpenseView memory v) {
        if (index >= _expenses[id].length) revert NoSuchExpense();
        Expense storage e = _expenses[id][index];
        address[] storage sp = _splitOf[id][index];
        v.logger = e.logger;
        v.payer = e.payer;
        v.total = e.total;
        v.loggedAt = e.loggedAt;
        v.voidableUntil = e.loggedAt + _l[id].voidWindow;
        v.voided = e.voided;
        v.note = e.note;
        v.debtors = sp;
        v.shares = new uint256[](sp.length);
        for (uint256 i = 0; i < sp.length; i++) v.shares[i] = _share[id][index][sp[i]];
    }

    function expenseCount(uint256 id) external view returns (uint256) {
        return _expenses[id].length;
    }

    function ledgersOf(address) external pure returns (uint256[] memory) {
        // Deliberately not indexed on chain — a UI reads LedgerOpened and
        // MemberAdded events, which is free, rather than paying storage for
        // a list that only a frontend ever needs.
        revert("read MemberAdded events");
    }

    /// @dev No owner, no admin, no fee. The contract takes nothing and
    ///      cannot move a member's balance except through settle/withdraw.
}

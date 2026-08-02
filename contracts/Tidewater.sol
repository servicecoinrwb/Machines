// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts@5.0.2/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts@5.0.2/token/ERC20/utils/SafeERC20.sol";

/**
 * Tidewater — payment streams in USDC on Arc
 *
 * Money that moves by the second instead of by the invoice. Rent that
 * accrues hourly. A retainer that drains as the month passes. Salary that
 * is genuinely earned continuously rather than settled in arrears.
 *
 * FULLY FUNDED, ON PURPOSE
 *
 * The whole stream is deposited when it's created. The alternative —
 * pulling from the payer's wallet as the recipient withdraws — keeps the
 * payer's capital free, but it means the recipient's "$400 accrued" is a
 * number they might not be able to collect. A stream you can't collect
 * isn't a stream, it's an invoice with extra arithmetic. So the money sits
 * here, visible, and the recipient is never guessing.
 *
 * THE ACCOUNTING RULE THAT MATTERS
 *
 * At any instant the deposit divides in exactly two ways:
 *
 *     streamed   = how much time has earned for the recipient
 *     unstreamed = the rest, still the payer's
 *
 * Cancelling doesn't negotiate that split, it just stops the clock and pays
 * both sides what the arithmetic already says they hold. There is no penalty
 * and no forfeiture in either direction, and no state in which the contract
 * owes more than it holds — every withdrawal is checked against the same
 * elapsed-time formula rather than a running balance that could drift.
 *
 * ROUNDING GOES TO THE RECIPIENT'S DISADVANTAGE, DELIBERATELY
 *
 * Integer division truncates. That means `streamedAmount` is always <= the
 * true real-valued figure, never above it, so the contract can never promise
 * a fraction of a unit it doesn't hold. The remainder isn't lost — it lands
 * in the payer's side of the split, or reaches the recipient on the final
 * second when elapsed == duration and the formula returns the exact deposit.
 */
contract Tidewater {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- errors

    error ZeroAddress();
    error ZeroAmount();
    error SelfStream();
    error BadWindow();
    error DurationTooShort();
    error DepositTooSmall(uint256 deposit, uint256 minimum);
    error NoSuchStream();
    error NotSender();
    error NotParty();
    error AlreadyCancelled();
    error NotCancellable();
    error NothingToWithdraw();
    error MoreThanAvailable(uint256 asked, uint256 available);
    error Reentrant();

    // ----------------------------------------------------------------- types

    struct Stream {
        address sender;
        address recipient;
        uint128 deposit;        // total funded
        uint128 withdrawn;      // paid to recipient so far
        uint64  startTime;
        uint64  stopTime;
        uint64  cancelledAt;    // 0 while running
        bool    exists;
        bool    cancellable;    // set at creation, never changes
        string  memo;
    }

    // -------------------------------------------------------------- constants

    /// @dev A stream shorter than this is just a transfer with extra steps,
    ///      and makes per-second rounding dominate the arithmetic.
    uint64 public constant MIN_DURATION = 60;

    /// @dev Streams that can't pay at least one token unit per second are
    ///      mostly rounding. Enforced as deposit >= duration.
    uint256 public constant MIN_RATE_UNITS = 1;

    // ----------------------------------------------------------------- state

    IERC20 public immutable token;
    uint256 public nextId = 1;

    mapping(uint256 => Stream) private _streams;
    mapping(address => uint256[]) private _outgoing;
    mapping(address => uint256[]) private _incoming;

    uint256 private _lock = 1;

    // ---------------------------------------------------------------- events

    event StreamOpened(
        uint256 indexed id,
        address indexed sender,
        address indexed recipient,
        uint256 deposit,
        uint64 startTime,
        uint64 stopTime,
        bool cancellable,
        string memo
    );
    event Withdrawn(uint256 indexed id, address indexed recipient, uint256 amount, uint256 remaining);
    event Cancelled(
        uint256 indexed id,
        address indexed by,
        uint256 toRecipient,
        uint256 toSender
    );

    // ------------------------------------------------------------- modifiers

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrant();
        _lock = 2;
        _;
        _lock = 1;
    }

    // ----------------------------------------------------------- constructor

    constructor(IERC20 usdc) {
        if (address(usdc) == address(0)) revert ZeroAddress();
        token = usdc;
    }

    // ---------------------------------------------------------------- create

    /**
     * @notice Open a stream. The full deposit moves here now.
     * @param startTime 0 for "right now", or a future timestamp.
     * @param cancellable If false, nobody can stop it — the recipient is
     *        guaranteed the whole deposit over the whole window. Fixed at
     *        creation so it can't be revoked later by the party it protects.
     */
    function open(
        address recipient,
        uint256 deposit,
        uint64 startTime,
        uint64 stopTime,
        bool cancellable,
        string calldata memo
    ) external nonReentrant returns (uint256 id) {
        if (recipient == address(0)) revert ZeroAddress();
        if (recipient == msg.sender) revert SelfStream();
        if (deposit == 0) revert ZeroAmount();

        uint64 start = startTime == 0 ? uint64(block.timestamp) : startTime;
        if (stopTime <= start) revert BadWindow();
        if (start < block.timestamp) revert BadWindow();

        uint64 duration = stopTime - start;
        if (duration < MIN_DURATION) revert DurationTooShort();
        // Every second must be able to carry at least one unit, or the
        // stream is mostly rounding error.
        if (deposit < uint256(duration) * MIN_RATE_UNITS) {
            revert DepositTooSmall(deposit, uint256(duration) * MIN_RATE_UNITS);
        }

        id = nextId++;
        _streams[id] = Stream({
            sender: msg.sender,
            recipient: recipient,
            deposit: uint128(deposit),
            withdrawn: 0,
            startTime: start,
            stopTime: stopTime,
            cancelledAt: 0,
            exists: true,
            cancellable: cancellable,
            memo: memo
        });
        _outgoing[msg.sender].push(id);
        _incoming[recipient].push(id);

        emit StreamOpened(id, msg.sender, recipient, deposit, start, stopTime, cancellable, memo);

        token.safeTransferFrom(msg.sender, address(this), deposit);
    }

    // ------------------------------------------------------------- accounting

    /// @dev The one formula. Everything else defers to it.
    function _streamed(Stream storage s) internal view returns (uint256) {
        uint64 at = s.cancelledAt == 0 ? uint64(block.timestamp) : s.cancelledAt;
        if (at <= s.startTime) return 0;
        if (at >= s.stopTime) return s.deposit;   // exact at the end, no drift
        unchecked {
            return (uint256(s.deposit) * (at - s.startTime)) / (s.stopTime - s.startTime);
        }
    }

    /// @notice Total earned by the recipient so far, withdrawn or not.
    function streamedAmount(uint256 id) public view returns (uint256) {
        Stream storage s = _streams[id];
        if (!s.exists) revert NoSuchStream();
        return _streamed(s);
    }

    /// @notice Collectable right now.
    function withdrawable(uint256 id) public view returns (uint256) {
        Stream storage s = _streams[id];
        if (!s.exists) revert NoSuchStream();
        return _streamed(s) - s.withdrawn;
    }

    /// @notice Still the sender's — what a cancel would return to them.
    function refundable(uint256 id) public view returns (uint256) {
        Stream storage s = _streams[id];
        if (!s.exists) revert NoSuchStream();
        return uint256(s.deposit) - _streamed(s);
    }

    /// @notice Units per second, for display. Truncated the same way the
    ///         contract truncates, so the UI can't promise a better rate.
    function ratePerSecond(uint256 id) external view returns (uint256) {
        Stream storage s = _streams[id];
        if (!s.exists) revert NoSuchStream();
        return uint256(s.deposit) / (s.stopTime - s.startTime);
    }

    // -------------------------------------------------------------- withdraw

    /// @notice Take some or all of what's accrued. Recipient only.
    function withdraw(uint256 id, uint256 amount) public nonReentrant {
        Stream storage s = _streams[id];
        if (!s.exists) revert NoSuchStream();
        if (msg.sender != s.recipient) revert NotParty();

        uint256 avail = _streamed(s) - s.withdrawn;
        if (avail == 0) revert NothingToWithdraw();
        uint256 amt = amount == 0 ? avail : amount;
        if (amt > avail) revert MoreThanAvailable(amt, avail);

        s.withdrawn += uint128(amt);
        emit Withdrawn(id, s.recipient, amt, avail - amt);

        token.safeTransfer(s.recipient, amt);
    }

    /// @notice Take everything available.
    function withdrawAll(uint256 id) external {
        withdraw(id, 0);
    }

    // ---------------------------------------------------------------- cancel

    /**
     * @notice Stop the clock and settle both sides at once.
     * @dev Either party may cancel. That's symmetric on purpose: the sender
     *      shouldn't be locked into a stream indefinitely, and the recipient
     *      shouldn't be forced to keep receiving from someone they'd rather
     *      not. Neither side can take more than the arithmetic already
     *      assigned them, so cancelling is never an attack — it only ends
     *      the future, never rewrites the past.
     */
    function cancel(uint256 id) external nonReentrant {
        Stream storage s = _streams[id];
        if (!s.exists) revert NoSuchStream();
        if (!s.cancellable) revert NotCancellable();
        if (s.cancelledAt != 0) revert AlreadyCancelled();
        if (msg.sender != s.sender && msg.sender != s.recipient) revert NotParty();

        // Freeze the clock first — every figure below reads from it.
        s.cancelledAt = uint64(block.timestamp);

        uint256 earned = _streamed(s);
        uint256 toRecipient = earned - s.withdrawn;
        uint256 toSender = uint256(s.deposit) - earned;

        s.withdrawn = uint128(earned);   // nothing further can be drawn

        emit Cancelled(id, msg.sender, toRecipient, toSender);

        address r = s.recipient;
        address snd = s.sender;
        if (toRecipient > 0) token.safeTransfer(r, toRecipient);
        if (toSender > 0) token.safeTransfer(snd, toSender);
    }

    // ----------------------------------------------------------------- views

    function getStream(uint256 id)
        external
        view
        returns (
            bool exists,
            address sender,
            address recipient,
            uint256 deposit,
            uint256 withdrawn,
            uint256 streamed,
            uint256 available,
            uint64 startTime,
            uint64 stopTime,
            uint64 cancelledAt,
            bool cancellable,
            string memory memo
        )
    {
        Stream storage s = _streams[id];
        if (!s.exists) return (false, address(0), address(0), 0, 0, 0, 0, 0, 0, 0, false, "");
        streamed = _streamed(s);
        return (
            true, s.sender, s.recipient, s.deposit, s.withdrawn, streamed,
            streamed - s.withdrawn, s.startTime, s.stopTime, s.cancelledAt,
            s.cancellable, s.memo
        );
    }

    function outgoingOf(address who) external view returns (uint256[] memory) {
        return _outgoing[who];
    }

    function incomingOf(address who) external view returns (uint256[] memory) {
        return _incoming[who];
    }

    /// @notice Total this contract owes across every live stream. Should
    ///         always be <= its token balance; a UI can assert that.
    function totalObligation() external view returns (uint256 owed) {
        for (uint256 i = 1; i < nextId; i++) {
            Stream storage s = _streams[i];
            if (!s.exists) continue;
            owed += uint256(s.deposit) - s.withdrawn;
        }
    }

    /// @dev No receive(), no fallback, no admin, no owner. Tokens enter only
    ///      through open() and leave only to the two parties on a stream.
}

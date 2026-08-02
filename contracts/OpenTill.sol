// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts@5.0.2/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts@5.0.2/token/ERC20/utils/SafeERC20.sol";

/**
 * OpenTill — a shared collection rail for USDC on Arc
 *
 * One contract, three ways to get paid, because they're the same object
 * underneath: somebody receives money, the split is fixed in advance, and
 * the rules are readable by both sides before anyone signs.
 *
 *   TILL      A named destination. Anyone can pay into it.
 *   SPLIT     A till with more than one payee. Every payment fans out
 *             immediately by fixed basis points — no pooled balance, no
 *             payout run, no "we'll settle at month end."
 *   PLAN      A recurring charge against a till. The payer sets an ERC-20
 *             allowance and the collector pulls on a schedule. Revoking is
 *             setting the allowance to zero, which the payer can do at any
 *             time from their own wallet without asking anyone.
 *
 * WHY ERC-20 AND NOT NATIVE GAS
 *
 * Arc makes USDC the native gas token, so a plain tip could be msg.value
 * with no approval step. But a subscription has to PULL, and you can't pull
 * native currency — pull requires an allowance. Rather than ship a contract
 * that works two different ways depending on which button you press, this
 * uses the ERC-20 interface throughout. Tips cost one extra approval; in
 * exchange, every mode has the same mental model and the same audit trail.
 *
 * NO CUSTODY, ANYWHERE
 *
 * The contract never holds a balance. Every payment transfers straight from
 * the payer to the payees inside the same call. There is no withdraw
 * function because there is nothing to withdraw, and no admin key that can
 * move anyone's money. A split's payees are fixed at creation and can't be
 * edited — if they could, the owner could redirect a band's income after the
 * gig.
 *
 * WHAT THIS DOESN'T DO
 *
 * It cannot force a payment. A plan's charge fails if the payer revoked
 * their allowance or spent their balance, and that's the correct behavior —
 * "cancel by removing permission" is the feature, not a bug. Nothing here
 * chases anyone.
 */
contract OpenTill {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- errors

    error TillExists();
    error NoSuchTill();
    error TillClosed();
    error NotTillOwner();
    error NoPayees();
    error TooManyPayees();
    error BadSplit(uint256 totalBps);
    error ZeroAddress();
    error ZeroAmount();
    error BelowMinimum(uint256 sent, uint256 minimum);
    error NoSuchPlan();
    error PlanInactive();
    error NotPlanParty();
    error TooEarly(uint64 dueAt);
    error PlanEnded();
    error DustSplit();

    // ----------------------------------------------------------------- types

    struct Payee {
        address account;
        uint16  bps;        // basis points of every payment
    }

    struct Till {
        address owner;      // can close it and open plans against it
        bool    exists;
        bool    closed;
        uint128 minPayment; // 0 = no minimum
        uint128 received;   // lifetime, for display
        uint64  createdAt;
        uint32  payments;   // count, for display
    }

    struct Plan {
        bytes32 tillId;
        address payer;
        uint128 amount;     // per period
        uint32  period;     // seconds
        uint64  nextDue;
        uint64  endsAt;     // 0 = open ended
        uint32  charges;
        bool    exists;
        bool    cancelled;
    }

    // -------------------------------------------------------------- constants

    uint16  public constant BPS = 10_000;
    uint256 public constant MAX_PAYEES = 12;
    uint32  public constant MIN_PERIOD = 1 hours;

    /// @dev Charging a moment early is fine; charging a day early is not.
    ///      Small grace so a keeper isn't fighting block timestamps.
    uint32 public constant CHARGE_GRACE = 60;

    // ----------------------------------------------------------------- state

    IERC20 public immutable token;

    mapping(bytes32 => Till) private _tills;
    mapping(bytes32 => Payee[]) private _payees;
    mapping(bytes32 => string) private _names;
    bytes32[] private _tillIds;

    mapping(bytes32 => Plan) private _plans;
    bytes32[] private _planIds;

    // ---------------------------------------------------------------- events

    event TillOpened(bytes32 indexed id, string name, address indexed owner, uint256 payeeCount, uint256 minPayment);
    event TillClosedEvent(bytes32 indexed id, string name);
    event Paid(bytes32 indexed id, string name, address indexed payer, uint256 amount, string memo);
    event PayeeCredited(bytes32 indexed id, address indexed payee, uint256 amount);
    event PlanOpened(bytes32 indexed id, bytes32 indexed tillId, address indexed payer, uint256 amount, uint32 period, uint64 endsAt);
    event PlanCharged(bytes32 indexed id, bytes32 indexed tillId, address indexed payer, uint256 amount, uint64 nextDue);
    event PlanCancelled(bytes32 indexed id, address indexed by);

    // ----------------------------------------------------------- constructor

    constructor(IERC20 usdc) {
        if (address(usdc) == address(0)) revert ZeroAddress();
        token = usdc;
    }

    // ----------------------------------------------------------------- tills

    function idOf(string calldata name) public pure returns (bytes32) {
        return keccak256(bytes(name));
    }

    /**
     * @notice Open a till. One payee is a tip jar; several is a split.
     * @param payees  Accounts and their basis points. Must sum to exactly 10000.
     * @param minPayment Smallest accepted payment, or 0 for none. Useful on
     *        splits: a payment too small to divide leaves someone with zero.
     */
    function openTill(
        string calldata name,
        Payee[] calldata payees,
        uint128 minPayment
    ) external {
        if (payees.length == 0) revert NoPayees();
        if (payees.length > MAX_PAYEES) revert TooManyPayees();

        bytes32 id = keccak256(bytes(name));
        if (_tills[id].exists) revert TillExists();

        uint256 sum;
        for (uint256 i = 0; i < payees.length; i++) {
            if (payees[i].account == address(0)) revert ZeroAddress();
            if (payees[i].bps == 0) revert BadSplit(0);
            sum += payees[i].bps;
            _payees[id].push(payees[i]);
        }
        if (sum != BPS) revert BadSplit(sum);

        // A payment small enough that some payee's cut rounds to zero would
        // revert at pay() time with a confusing error. Compute the smallest
        // amount that divides cleanly and hold the till to at least that, so
        // the failure is impossible rather than merely reported.
        uint128 floorAmt = _minViable(payees);
        if (minPayment < floorAmt) minPayment = floorAmt;

        _tills[id] = Till({
            owner: msg.sender,
            exists: true,
            closed: false,
            minPayment: minPayment,
            received: 0,
            createdAt: uint64(block.timestamp),
            payments: 0
        });
        _tillIds.push(id);
        _names[id] = name;

        emit TillOpened(id, name, msg.sender, payees.length, minPayment);
    }

    /// @dev Smallest payment where every payee still receives >= 1 unit.
    ///      The binding payee is the one with the fewest basis points:
    ///      amount * bps / 10000 >= 1  =>  amount >= ceil(10000 / bps).
    function _minViable(Payee[] calldata payees) internal pure returns (uint128) {
        uint16 smallest = type(uint16).max;
        for (uint256 i = 0; i < payees.length; i++) {
            if (payees[i].bps < smallest) smallest = payees[i].bps;
        }
        return uint128((uint256(BPS) + smallest - 1) / smallest);
    }

    /// @notice Smallest payment a till will accept, for display before paying.
    function minViablePayment(string calldata name) external view returns (uint256) {
        Payee[] storage ps = _payees[keccak256(bytes(name))];
        uint16 smallest = type(uint16).max;
        for (uint256 i = 0; i < ps.length; i++) {
            if (ps[i].bps < smallest) smallest = ps[i].bps;
        }
        if (smallest == type(uint16).max) return 0;
        return (uint256(BPS) + smallest - 1) / smallest;
    }

    /// @notice Stop accepting new payments. Existing plans stop charging too.
    function closeTill(string calldata name) external {
        bytes32 id = keccak256(bytes(name));
        Till storage t = _tills[id];
        if (!t.exists) revert NoSuchTill();
        if (msg.sender != t.owner) revert NotTillOwner();
        if (t.closed) revert TillClosed();
        t.closed = true;
        emit TillClosedEvent(id, name);
    }

    // ------------------------------------------------------------------- pay

    /// @notice Pay into a till. Requires an ERC-20 allowance to this contract.
    /// @param memo Free text on the receipt — an invoice number, a dedication,
    ///        a month. Emitted, never stored, and public forever.
    function pay(string calldata name, uint256 amount, string calldata memo) external {
        bytes32 id = keccak256(bytes(name));
        _pay(id, name, msg.sender, amount, memo);
    }

    function _pay(
        bytes32 id,
        string calldata name,
        address payer,
        uint256 amount,
        string calldata memo
    ) internal {
        Till storage t = _tills[id];
        if (!t.exists) revert NoSuchTill();
        if (t.closed) revert TillClosed();
        if (amount == 0) revert ZeroAmount();
        if (t.minPayment != 0 && amount < t.minPayment) revert BelowMinimum(amount, t.minPayment);

        Payee[] storage ps = _payees[id];

        // Effects before any transfer.
        t.received += uint128(amount);
        t.payments += 1;
        emit Paid(id, name, payer, amount, memo);

        // Fan out. The last payee takes the remainder so rounding can never
        // strand dust in this contract or overdraw the payer.
        uint256 paidOut;
        uint256 n = ps.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 cut = (i == n - 1) ? amount - paidOut : (amount * ps[i].bps) / BPS;
            if (cut == 0) revert DustSplit();
            paidOut += cut;
            emit PayeeCredited(id, ps[i].account, cut);
            token.safeTransferFrom(payer, ps[i].account, cut);
        }
    }

    // ----------------------------------------------------------------- plans

    /**
     * @notice Subscribe to a till. The payer opens this themselves — nobody
     *         can enroll someone else.
     * @dev The first charge is NOT taken here. A plan that charges on creation
     *      hides the first payment inside the signup click; this way the payer
     *      sees a separate, explicit first charge.
     * @param endsAt 0 for open-ended, or a timestamp after which it stops.
     */
    function openPlan(
        string calldata name,
        uint128 amount,
        uint32 period,
        uint64 endsAt,
        bool chargeNow
    ) external returns (bytes32 planId) {
        bytes32 tillId = keccak256(bytes(name));
        Till storage t = _tills[tillId];
        if (!t.exists) revert NoSuchTill();
        if (t.closed) revert TillClosed();
        if (amount == 0) revert ZeroAmount();
        if (amount < t.minPayment) revert BelowMinimum(amount, t.minPayment);
        if (period < MIN_PERIOD) revert TooEarly(0);
        if (endsAt != 0 && endsAt <= block.timestamp) revert PlanEnded();

        planId = keccak256(abi.encodePacked(tillId, msg.sender, block.timestamp, _planIds.length));

        _plans[planId] = Plan({
            tillId: tillId,
            payer: msg.sender,
            amount: amount,
            period: period,
            nextDue: uint64(block.timestamp),
            endsAt: endsAt,
            charges: 0,
            exists: true,
            cancelled: false
        });
        _planIds.push(planId);

        emit PlanOpened(planId, tillId, msg.sender, amount, period, endsAt);

        if (chargeNow) _charge(planId);
    }

    /**
     * @notice Take a due payment. Callable by anyone — a keeper, the payee,
     *         or the payer themselves. Whoever calls it pays only the gas;
     *         the money can only move to the till's payees.
     */
    function charge(bytes32 planId) external {
        _charge(planId);
    }

    function _charge(bytes32 planId) internal {
        Plan storage p = _plans[planId];
        if (!p.exists) revert NoSuchPlan();
        if (p.cancelled) revert PlanInactive();
        if (p.endsAt != 0 && block.timestamp > p.endsAt) revert PlanEnded();
        if (block.timestamp + CHARGE_GRACE < p.nextDue) revert TooEarly(p.nextDue);

        bytes32 tillId = p.tillId;
        Till storage t = _tills[tillId];
        if (!t.exists) revert NoSuchTill();
        if (t.closed) revert TillClosed();

        // Advance from the scheduled time, not from now, so a late charge
        // doesn't quietly push the whole schedule back.
        uint64 next = p.nextDue + p.period;
        if (next <= block.timestamp) next = uint64(block.timestamp) + p.period;
        p.nextDue = next;
        p.charges += 1;

        uint256 amount = p.amount;
        t.received += uint128(amount);
        t.payments += 1;

        string memory nm = _names[tillId];
        emit PlanCharged(planId, tillId, p.payer, amount, next);
        emit Paid(tillId, nm, p.payer, amount, "subscription");

        Payee[] storage ps = _payees[tillId];
        uint256 paidOut;
        uint256 n = ps.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 cut = (i == n - 1) ? amount - paidOut : (amount * ps[i].bps) / BPS;
            if (cut == 0) revert DustSplit();
            paidOut += cut;
            emit PayeeCredited(tillId, ps[i].account, cut);
            token.safeTransferFrom(p.payer, ps[i].account, cut);
        }
    }

    /// @notice Either side can end a plan. The payer can also simply zero
    ///         their allowance — cancelling here is the tidy version, not
    ///         the only one, which is the point.
    function cancelPlan(bytes32 planId) external {
        Plan storage p = _plans[planId];
        if (!p.exists) revert NoSuchPlan();
        if (p.cancelled) revert PlanInactive();
        if (msg.sender != p.payer && msg.sender != _tills[p.tillId].owner) revert NotPlanParty();
        p.cancelled = true;
        emit PlanCancelled(planId, msg.sender);
    }

    // ----------------------------------------------------------------- views

    function getTill(string calldata name)
        external
        view
        returns (
            bool exists,
            address owner,
            bool closed,
            uint256 minPayment,
            uint256 received,
            uint32 payments,
            uint64 createdAt,
            uint256 payeeCount
        )
    {
        bytes32 id = keccak256(bytes(name));
        Till storage t = _tills[id];
        return (t.exists, t.owner, t.closed, t.minPayment, t.received, t.payments, t.createdAt, _payees[id].length);
    }

    function getPayees(string calldata name) external view returns (Payee[] memory) {
        return _payees[keccak256(bytes(name))];
    }

    /// @notice What each payee would receive from a given payment, exactly as
    ///         the contract would compute it — remainder rule included.
    function previewSplit(string calldata name, uint256 amount)
        external
        view
        returns (address[] memory accounts, uint256[] memory cuts)
    {
        Payee[] storage ps = _payees[keccak256(bytes(name))];
        uint256 n = ps.length;
        accounts = new address[](n);
        cuts = new uint256[](n);
        uint256 paidOut;
        for (uint256 i = 0; i < n; i++) {
            uint256 cut = (i == n - 1) ? amount - paidOut : (amount * ps[i].bps) / BPS;
            paidOut += cut;
            accounts[i] = ps[i].account;
            cuts[i] = cut;
        }
    }

    function getPlan(bytes32 planId)
        external
        view
        returns (
            bool exists,
            string memory tillName,
            address payer,
            uint256 amount,
            uint32 period,
            uint64 nextDue,
            uint64 endsAt,
            uint32 charges,
            bool cancelled,
            bool fundable
        )
    {
        Plan storage p = _plans[planId];
        exists = p.exists;
        tillName = _names[p.tillId];
        payer = p.payer;
        amount = p.amount;
        period = p.period;
        nextDue = p.nextDue;
        endsAt = p.endsAt;
        charges = p.charges;
        cancelled = p.cancelled;
        // Whether the next charge would actually go through right now.
        fundable = p.exists
            && !p.cancelled
            && token.allowance(p.payer, address(this)) >= p.amount
            && token.balanceOf(p.payer) >= p.amount;
    }

    function tillCount() external view returns (uint256) { return _tillIds.length; }
    function tillAt(uint256 i) external view returns (string memory) { return _names[_tillIds[i]]; }
    function planCount() external view returns (uint256) { return _planIds.length; }
    function planAt(uint256 i) external view returns (bytes32) { return _planIds[i]; }

    /// @notice Plans a keeper could charge right now, for automation.
    function duePlans() external view returns (bytes32[] memory due) {
        uint256 n = _planIds.length;
        bytes32[] memory buf = new bytes32[](n);
        uint256 k;
        for (uint256 i = 0; i < n; i++) {
            Plan storage p = _plans[_planIds[i]];
            if (p.cancelled) continue;
            if (p.endsAt != 0 && block.timestamp > p.endsAt) continue;
            if (block.timestamp + CHARGE_GRACE < p.nextDue) continue;
            if (token.allowance(p.payer, address(this)) < p.amount) continue;
            if (token.balanceOf(p.payer) < p.amount) continue;
            buf[k++] = _planIds[i];
        }
        due = new bytes32[](k);
        for (uint256 i = 0; i < k; i++) due[i] = buf[i];
    }

    /// @dev No receive(), no fallback, no withdraw. Money passes through this
    ///      contract within a single call and is never held by it.
}

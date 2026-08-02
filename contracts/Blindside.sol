// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts@5.0.2/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts@5.0.2/token/ERC20/utils/SafeERC20.sol";

/**
 * Blindside — sealed-bid auctions in USDC on Arc
 *
 * A public blockchain is the worst possible place to run an ordinary
 * auction: every bid is visible the moment it's sent, so the last bidder
 * always wins by a penny and everyone else learns their bid was pointless.
 * Commit-reveal fixes that with nothing but a hash.
 *
 *   COMMIT   You publish keccak(bid, salt, yourAddress) and lock a deposit
 *            of AT LEAST your bid. Nobody can read the bid out of a hash,
 *            and because you may deposit more than you bid, the deposit
 *            amount leaks nothing either. That second part is what makes
 *            this actually sealed rather than merely obfuscated.
 *
 *   REVEAL   After bidding closes you republish the bid and salt. The
 *            contract recomputes the hash and checks it matches. A bid that
 *            doesn't match, or exceeds what you deposited, simply doesn't
 *            count — you can't raise your bid after seeing others.
 *
 *   SETTLE   Highest revealed bid wins and pays exactly that. Everyone else
 *            takes their whole deposit back. The winner takes back the
 *            difference between what they locked and what they bid.
 *
 * WHY THE ADDRESS IS IN THE HASH
 *
 * Without it, anyone watching the reveal transactions could copy a winning
 * (bid, salt) pair and submit it as their own commitment in a later
 * auction. Binding the hash to the committer makes a stolen pair useless.
 *
 * WHAT HAPPENS TO A BID THAT NEVER REVEALS
 *
 * Nothing punitive. Their deposit is returned in full. Non-revealing is
 * only a way to withhold a bid you no longer want, and since you can't see
 * others' bids before the reveal window opens, withholding gains you no
 * information. Forfeiting deposits would punish someone whose laptop died
 * more often than it would deter a strategist.
 *
 * NO CUSTODY BEYOND THE AUCTION
 *
 * There is no owner and no admin key. The seller cannot cancel after bids
 * exist, cannot see bids early, and cannot choose a winner. Once the reveal
 * window closes, settlement is mechanical and callable by anyone.
 */
contract Blindside {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- errors

    error ZeroAddress();
    error ZeroAmount();
    error BadWindow();
    error PhaseTooShort();
    error NoSuchLot();
    error NotSeller();
    error SellerCannotBid();
    error BiddingClosed();
    error BiddingOpen();
    error RevealClosed();
    error RevealOpen();
    error AlreadyCommitted();
    error NoCommitment();
    error AlreadyRevealed();
    error BadReveal();
    error BidOverDeposit(uint256 bid, uint256 deposit);
    error BelowReserve(uint256 bid, uint256 reserve);
    error AlreadySettled();
    error NotSettled();
    error NothingToClaim();
    error HasBids();
    error Reentrant();

    // ----------------------------------------------------------------- types

    enum Phase { Bidding, Revealing, Settled }

    struct Lot {
        address seller;
        uint128 reserve;        // 0 = no reserve
        uint64  commitEnd;
        uint64  revealEnd;
        uint128 topBid;
        address topBidder;
        uint32  commits;
        uint32  reveals;
        bool    exists;
        bool    settled;
        bool    cancelled;
        string  title;
    }

    struct Bid {
        bytes32 hash;
        uint128 deposit;
        uint128 revealedBid;
        bool    revealed;
        bool    claimed;
    }

    // -------------------------------------------------------------- constants

    /// @dev Each phase needs to be long enough that a bidder can't be
    ///      griefed by network congestion into missing their own reveal.
    uint64 public constant MIN_PHASE = 5 minutes;

    // ----------------------------------------------------------------- state

    IERC20 public immutable token;
    uint256 public nextId = 1;

    mapping(uint256 => Lot) private _lots;
    mapping(uint256 => mapping(address => Bid)) private _bids;
    mapping(uint256 => address[]) private _bidders;

    uint256 private _lock = 1;

    // ---------------------------------------------------------------- events

    event LotOpened(uint256 indexed id, address indexed seller, string title, uint256 reserve, uint64 commitEnd, uint64 revealEnd);
    event Committed(uint256 indexed id, address indexed bidder, uint256 deposit);
    event Revealed(uint256 indexed id, address indexed bidder, uint256 bid, bool leading);
    event Settled(uint256 indexed id, address indexed winner, uint256 price, uint256 reveals);
    event NoSale(uint256 indexed id, string reason);
    event Claimed(uint256 indexed id, address indexed bidder, uint256 amount);
    event LotCancelled(uint256 indexed id);

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

    // ------------------------------------------------------------------ open

    /**
     * @notice List something for sealed bids.
     * @param reserve Minimum acceptable bid, or 0 for none. Public from the
     *        start — a hidden reserve is just the seller bidding against you.
     */
    function openLot(
        string calldata title,
        uint128 reserve,
        uint64 commitSeconds,
        uint64 revealSeconds
    ) external returns (uint256 id) {
        if (commitSeconds < MIN_PHASE || revealSeconds < MIN_PHASE) revert PhaseTooShort();

        id = nextId++;
        uint64 cEnd = uint64(block.timestamp) + commitSeconds;
        uint64 rEnd = cEnd + revealSeconds;

        _lots[id] = Lot({
            seller: msg.sender,
            reserve: reserve,
            commitEnd: cEnd,
            revealEnd: rEnd,
            topBid: 0,
            topBidder: address(0),
            commits: 0,
            reveals: 0,
            exists: true,
            settled: false,
            cancelled: false,
            title: title
        });

        emit LotOpened(id, msg.sender, title, reserve, cEnd, rEnd);
    }

    /// @notice Pull a lot, but only while nobody has bid on it.
    function cancelLot(uint256 id) external {
        Lot storage L = _lots[id];
        if (!L.exists) revert NoSuchLot();
        if (msg.sender != L.seller) revert NotSeller();
        if (L.settled || L.cancelled) revert AlreadySettled();
        if (L.commits > 0) revert HasBids();
        L.cancelled = true;
        L.settled = true;
        emit LotCancelled(id);
    }

    // ---------------------------------------------------------------- commit

    /**
     * @notice Lock a deposit against a hidden bid.
     * @param blob keccak256(abi.encodePacked(bidAmount, salt, msg.sender))
     * @param deposit At or above your bid. Deposit MORE than you bid if you
     *        want the amount to say nothing — that's the whole point.
     */
    function commit(uint256 id, bytes32 blob, uint256 deposit) external nonReentrant {
        Lot storage L = _lots[id];
        if (!L.exists) revert NoSuchLot();
        if (L.cancelled) revert AlreadySettled();
        if (block.timestamp >= L.commitEnd) revert BiddingClosed();
        if (msg.sender == L.seller) revert SellerCannotBid();
        if (deposit == 0) revert ZeroAmount();
        if (_bids[id][msg.sender].deposit != 0) revert AlreadyCommitted();

        _bids[id][msg.sender] = Bid({
            hash: blob,
            deposit: uint128(deposit),
            revealedBid: 0,
            revealed: false,
            claimed: false
        });
        _bidders[id].push(msg.sender);
        L.commits += 1;

        emit Committed(id, msg.sender, deposit);

        token.safeTransferFrom(msg.sender, address(this), deposit);
    }

    /// @notice Compute a commitment offchain-style, for building or checking.
    function hashBid(uint256 bidAmount, bytes32 salt, address bidder) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(bidAmount, salt, bidder));
    }

    // ---------------------------------------------------------------- reveal

    /**
     * @notice Prove what you bid. Only during the reveal window.
     * @dev A bid above your deposit isn't slashed — it just doesn't count,
     *      and the deposit comes back. Overbidding your collateral is a
     *      mistake, not an attack: the contract simply can't honour it.
     */
    function reveal(uint256 id, uint256 bidAmount, bytes32 salt) external {
        Lot storage L = _lots[id];
        if (!L.exists) revert NoSuchLot();
        if (block.timestamp < L.commitEnd) revert BiddingOpen();
        if (block.timestamp >= L.revealEnd) revert RevealClosed();

        Bid storage B = _bids[id][msg.sender];
        if (B.deposit == 0) revert NoCommitment();
        if (B.revealed) revert AlreadyRevealed();
        if (hashBid(bidAmount, salt, msg.sender) != B.hash) revert BadReveal();
        if (bidAmount > B.deposit) revert BidOverDeposit(bidAmount, B.deposit);
        if (L.reserve != 0 && bidAmount < L.reserve) revert BelowReserve(bidAmount, L.reserve);

        B.revealed = true;
        B.revealedBid = uint128(bidAmount);
        L.reveals += 1;

        bool leading = bidAmount > L.topBid;
        if (leading) {
            L.topBid = uint128(bidAmount);
            L.topBidder = msg.sender;
        }

        emit Revealed(id, msg.sender, bidAmount, leading);
    }

    // ---------------------------------------------------------------- settle

    /**
     * @notice Close the auction and pay the seller. Callable by anyone —
     *         the outcome is already determined by the revealed bids, so
     *         who sends the transaction is irrelevant.
     */
    function settle(uint256 id) external nonReentrant {
        Lot storage L = _lots[id];
        if (!L.exists) revert NoSuchLot();
        if (L.settled) revert AlreadySettled();
        if (block.timestamp < L.revealEnd) revert RevealOpen();

        L.settled = true;

        if (L.topBidder == address(0)) {
            emit NoSale(id, L.commits == 0 ? "no bids" : "no valid reveals");
            return;
        }

        uint256 price = L.topBid;
        emit Settled(id, L.topBidder, price, L.reveals);

        token.safeTransfer(L.seller, price);
    }

    /**
     * @notice Take your money back — all of it if you lost or didn't reveal,
     *         or the overpayment if you won.
     * @dev Pull rather than push. A settle() that looped over every bidder
     *      could be made to run out of gas by anyone willing to commit a
     *      thousand dust bids, which would freeze the auction permanently.
     *      Each bidder collecting their own is immune to that.
     */
    function claim(uint256 id) external nonReentrant {
        Lot storage L = _lots[id];
        if (!L.exists) revert NoSuchLot();
        if (!L.settled && !L.cancelled) revert NotSettled();

        Bid storage B = _bids[id][msg.sender];
        if (B.deposit == 0) revert NoCommitment();
        if (B.claimed) revert NothingToClaim();

        uint256 back = B.deposit;
        if (msg.sender == L.topBidder) back -= uint256(L.topBid);   // winner's change
        if (back == 0) revert NothingToClaim();

        B.claimed = true;
        emit Claimed(id, msg.sender, back);

        token.safeTransfer(msg.sender, back);
    }

    // ----------------------------------------------------------------- views

    function phaseOf(uint256 id) public view returns (Phase) {
        Lot storage L = _lots[id];
        if (L.settled) return Phase.Settled;
        if (block.timestamp < L.commitEnd) return Phase.Bidding;
        if (block.timestamp < L.revealEnd) return Phase.Revealing;
        return Phase.Settled;
    }

    /// @dev Returned as a struct: thirteen separate return values overflow
    ///      the EVM's stack in a plain view function.
    struct LotView {
        bool exists;
        address seller;
        string title;
        uint256 reserve;
        uint64 commitEnd;
        uint64 revealEnd;
        uint32 commits;
        uint32 reveals;
        uint256 topBid;
        address topBidder;
        bool settled;
        bool cancelled;
        uint8 phase;
    }

    function getLot(uint256 id) external view returns (LotView memory v) {
        Lot storage L = _lots[id];
        if (!L.exists) return v;
        // The leading bid stays hidden until reveals begin — surfacing it
        // during commit would defeat the entire mechanism.
        bool showTop = block.timestamp >= L.commitEnd;
        v.exists = true;
        v.seller = L.seller;
        v.title = L.title;
        v.reserve = L.reserve;
        v.commitEnd = L.commitEnd;
        v.revealEnd = L.revealEnd;
        v.commits = L.commits;
        v.reveals = L.reveals;
        v.topBid = showTop ? uint256(L.topBid) : 0;
        v.topBidder = showTop ? L.topBidder : address(0);
        v.settled = L.settled;
        v.cancelled = L.cancelled;
        v.phase = uint8(phaseOf(id));
    }

    function getBid(uint256 id, address who)
        external
        view
        returns (bool committed, uint256 deposit, bool revealed, uint256 revealedBid, bool claimed, uint256 claimable)
    {
        Lot storage L = _lots[id];
        Bid storage B = _bids[id][who];
        committed = B.deposit != 0;
        deposit = B.deposit;
        revealed = B.revealed;
        revealedBid = B.revealedBid;
        claimed = B.claimed;
        if (!committed || B.claimed || (!L.settled && !L.cancelled)) {
            claimable = 0;
        } else {
            claimable = B.deposit;
            if (who == L.topBidder) claimable -= uint256(L.topBid);
        }
    }

    function bidderCount(uint256 id) external view returns (uint256) {
        return _bidders[id].length;
    }

    function bidderAt(uint256 id, uint256 i) external view returns (address) {
        return _bidders[id][i];
    }

    /// @notice Everything the contract still owes on a lot, for auditing.
    function outstandingOf(uint256 id) external view returns (uint256 owed) {
        Lot storage L = _lots[id];
        address[] storage bs = _bidders[id];
        for (uint256 i = 0; i < bs.length; i++) {
            Bid storage B = _bids[id][bs[i]];
            if (B.claimed) continue;
            uint256 back = B.deposit;
            if (bs[i] == L.topBidder && L.settled) back -= uint256(L.topBid);
            owed += back;
        }
        if (!L.settled && L.topBidder != address(0)) owed += uint256(L.topBid);
    }

    /// @dev No receive(), no fallback, no owner. Tokens enter through commit()
    ///      and leave only to the seller at settlement or to bidders at claim.
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * Ondersign — a document notary on Arc
 *
 * Hash a file, put the hash on chain, and you can prove afterwards that
 * exactly that file existed at exactly that moment. Change one byte of the
 * PDF and the hash no longer matches, so "this is the version we agreed to"
 * stops being one person's word against another's.
 *
 * WHY COUNTERSIGNING IS THE WHOLE POINT
 *
 * A timestamp alone only proves the person who posted it had the file.
 * That settles nothing in an argument, because nobody disputes that the
 * contractor had the change order — they dispute whether the customer
 * agreed to it.
 *
 * So a record can name required signers up front. Each one signs the same
 * hash from their own wallet, and the record is only complete when all of
 * them have. What you end up with isn't "I sent this," it's "both of us
 * put our name to this exact file on this date," which is the thing that
 * actually ends the conversation.
 *
 * WHAT THIS PROVES, AND WHAT IT DOESN'T
 *
 *   It proves    a file with this exact hash existed no later than this
 *                block, and that these addresses signed it.
 *
 *   It does not  prove what the file says — the chain never sees it. It
 *                does not prove anyone read it, understood it, or had the
 *                authority to agree to it. And it cannot prove the file
 *                did NOT exist earlier.
 *
 * That last clause matters and is usually left out. A timestamp is an
 * upper bound on a document's age, never a lower one.
 *
 * NOTHING IS STORED BUT A HASH
 *
 * The document never touches the chain, so nothing confidential is
 * published. The tradeoff is that losing the file means losing the ability
 * to prove anything — the hash alone is not the document, and cannot be
 * turned back into it.
 */
contract Ondersign {

    // ---------------------------------------------------------------- errors

    error ZeroHash();
    error AlreadyFiled();
    error NoSuchRecord();
    error NotASigner();
    error AlreadySigned();
    error TooManySigners();
    error VoidWindowPassed();
    error NotFiler();
    error AlreadyVoided();
    error SignedAlready();

    // ----------------------------------------------------------------- types

    struct Record {
        address filer;
        uint64  filedAt;
        uint64  completedAt;    // when the last required signer signed
        uint32  signedCount;
        bool    exists;
        bool    voided;
        string  label;          // a human name; the hash is the truth
        string  uri;            // optional pointer — IPFS, a URL, or empty
    }

    // -------------------------------------------------------------- constants

    uint256 public constant MAX_SIGNERS = 10;

    /// @dev A filer can retract a record only before anyone else signs it and
    ///      only briefly — long enough to fix a mistyped hash, not long
    ///      enough to erase something inconvenient.
    uint64 public constant RETRACT_WINDOW = 1 hours;

    // ----------------------------------------------------------------- state

    mapping(bytes32 => Record) private _rec;
    mapping(bytes32 => address[]) private _required;
    mapping(bytes32 => mapping(address => uint64)) private _signedAt;
    bytes32[] private _all;

    // ---------------------------------------------------------------- events

    event Filed(bytes32 indexed docHash, address indexed filer, string label, uint256 requiredSigners, string uri);
    event Signed(bytes32 indexed docHash, address indexed signer, uint256 signedCount, bool complete);
    event Retracted(bytes32 indexed docHash, address indexed by);

    // ------------------------------------------------------------------ file

    /**
     * @notice Put a document's hash on record.
     * @param docHash keccak256 of the file's bytes. Computed in the browser —
     *        the file itself never leaves the machine.
     * @param signers Who must sign for this to count as agreed. Pass an empty
     *        list for a plain timestamp with no counterparty.
     * @param uri Optional pointer to where the file lives. Storing one makes
     *        the record more useful and less private; leaving it blank keeps
     *        the document entirely off the record.
     */
    function file(
        bytes32 docHash,
        string calldata label,
        address[] calldata signers,
        string calldata uri
    ) external {
        if (docHash == bytes32(0)) revert ZeroHash();
        if (_rec[docHash].exists) revert AlreadyFiled();
        if (signers.length > MAX_SIGNERS) revert TooManySigners();

        _rec[docHash] = Record({
            filer: msg.sender,
            filedAt: uint64(block.timestamp),
            completedAt: 0,
            signedCount: 0,
            exists: true,
            voided: false,
            label: label,
            uri: uri
        });

        for (uint256 i = 0; i < signers.length; i++) {
            _required[docHash].push(signers[i]);
        }
        _all.push(docHash);

        emit Filed(docHash, msg.sender, label, signers.length, uri);

        // Filing is itself a signature if the filer is one of the required
        // parties — nobody should have to sign their own document twice.
        for (uint256 i = 0; i < signers.length; i++) {
            if (signers[i] == msg.sender) { _sign(docHash, msg.sender); break; }
        }
    }

    /// @notice Put your name to a document someone filed.
    function sign(bytes32 docHash) external {
        Record storage r = _rec[docHash];
        if (!r.exists) revert NoSuchRecord();
        if (r.voided) revert AlreadyVoided();
        if (_signedAt[docHash][msg.sender] != 0) revert AlreadySigned();

        bool required;
        address[] storage req = _required[docHash];
        for (uint256 i = 0; i < req.length; i++) {
            if (req[i] == msg.sender) { required = true; break; }
        }
        if (!required) revert NotASigner();

        _sign(docHash, msg.sender);
    }

    function _sign(bytes32 docHash, address who) internal {
        Record storage r = _rec[docHash];
        _signedAt[docHash][who] = uint64(block.timestamp);
        r.signedCount += 1;
        bool complete = r.signedCount >= _required[docHash].length;
        if (complete && r.completedAt == 0) r.completedAt = uint64(block.timestamp);
        emit Signed(docHash, who, r.signedCount, complete);
    }

    /**
     * @notice Retract a record you filed. Narrow on purpose.
     * @dev Only the filer, only within the first hour, and only while nobody
     *      else has signed. A notary you can quietly unmake later is not a
     *      notary — this exists to fix a fat-fingered hash and nothing else.
     *      The retraction itself stays on chain permanently.
     */
    function retract(bytes32 docHash) external {
        Record storage r = _rec[docHash];
        if (!r.exists) revert NoSuchRecord();
        if (r.voided) revert AlreadyVoided();
        if (msg.sender != r.filer) revert NotFiler();
        if (block.timestamp > uint256(r.filedAt) + RETRACT_WINDOW) revert VoidWindowPassed();

        address[] storage req = _required[docHash];
        for (uint256 i = 0; i < req.length; i++) {
            if (req[i] != r.filer && _signedAt[docHash][req[i]] != 0) revert SignedAlready();
        }

        r.voided = true;
        emit Retracted(docHash, msg.sender);
    }

    // ----------------------------------------------------------------- views

    struct RecordView {
        bool exists;
        bool voided;
        address filer;
        string label;
        string uri;
        uint64 filedAt;
        uint64 completedAt;
        uint32 signedCount;
        address[] required;
        uint64[] signedAt;      // 0 where a required signer hasn't signed
        bool complete;
    }

    /// @notice Everything about a document, given its hash.
    function verify(bytes32 docHash) external view returns (RecordView memory v) {
        Record storage r = _rec[docHash];
        if (!r.exists) return v;
        address[] storage req = _required[docHash];
        v.exists = true;
        v.voided = r.voided;
        v.filer = r.filer;
        v.label = r.label;
        v.uri = r.uri;
        v.filedAt = r.filedAt;
        v.completedAt = r.completedAt;
        v.signedCount = r.signedCount;
        v.required = req;
        v.signedAt = new uint64[](req.length);
        for (uint256 i = 0; i < req.length; i++) {
            v.signedAt[i] = _signedAt[docHash][req[i]];
        }
        v.complete = req.length > 0 && r.signedCount >= req.length;
    }

    /// @notice Did this exact address sign this exact document, and when.
    function signatureOf(bytes32 docHash, address who) external view returns (uint64) {
        return _signedAt[docHash][who];
    }

    function recordCount() external view returns (uint256) {
        return _all.length;
    }

    function recordAt(uint256 i) external view returns (bytes32) {
        return _all[i];
    }

    /// @dev No owner, no admin, no fee, and no way to alter a filed record
    ///      beyond the filer's one-hour window to retract an unsigned one.
    ///      A notary that anyone can rewrite proves nothing.
}

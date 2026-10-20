// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {IChainHistory} from "./IChainHistory.sol";
import {Statement, Window, Anchor, END_OF_BLOCK} from "./IncomeStatementTypes.sol";
import {IncomeStatementCodec as Codec} from "./IncomeStatementCodec.sol";
import {IncomeStatementWindows as Windows} from "./IncomeStatementWindows.sol";

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

/// @title IncomeStatementChecker
/// @notice Reference reader of the Agent Income Statements draft. It applies the reader rules to entries of the
///         ERC-8004 Reputation Registry (the fields of their `NewFeedback` logs), their files and the fields the files
///         decode to, against the chain as an `IChainHistory` reports it. Each rule that fails reverts with its own
///         error; `readAll` turns a failure into a failed writer and goes on with the others.
/// @dev Not audited. A reference for the interface. Run it with `eth_call` over an `IChainHistory` backed by an RPC
///      endpoint, or in tests over a recorded history.
contract IncomeStatementChecker {
    enum Status {
        NoData, // no statement from that writer, or no counted chain: not "no income"
        Sampled, // light checks passed: the totals are the writer's claim
        Rebuilt, // every statement rebuilt from the asset's logs
        Failed, // a rule failed: that writer fails for that agent
        AssetNotCounted // the reader does not count that asset
    }

    /// @notice The reader's setting: the identity registry its Reputation Registry reports (`getIdentityRegistry()`),
    ///         that registry's chain, the Reputation Registry, and the chain reads.
    struct Context {
        uint256 chainId;
        address identityRegistry;
        address reputationRegistry;
        IChainHistory history;
    }

    /// @notice One entry: the fields of the registry's `NewFeedback` log, the block it was emitted in, and whether
    ///         `readFeedback` reports it revoked.
    struct Entry {
        uint256 agentId;
        address client;
        uint64 feedbackIndex;
        int128 value;
        uint8 valueDecimals;
        string tag1;
        string tag2;
        string feedbackURI;
        bytes32 feedbackHash;
        uint64 blockNumber;
        bool revoked;
    }

    /// @notice Every entry `writer` has given `agentId`, statements or not, in `feedbackIndex` order; and, at the same
    ///         index, the file and decoded fields of each entry that is a statement (ignored for the others).
    struct Chain {
        uint256 agentId;
        address writer;
        Entry[] entries;
        bytes[] files;
        Statement[] statements;
    }

    /// @notice What a reader may report for one chain, or for an agent and an asset: the income through the end of
    ///         the last window (`value`), and where that is.
    struct Result {
        Status status;
        address writer;
        address asset;
        uint256 value;
        uint64 throughBlock;
        uint32 throughLog;
        uint64 throughTime;
    }

    // entry and file
    error FileTooLarge();
    error TooManyAnchors();
    error NumberTooLarge();
    error DecimalsTooLarge();
    error ValueTooLarge();
    error NotDataURI();
    error HashMismatch();
    error NotCanonical();
    error RegistryMismatch();
    error EntryMismatch();
    error Revoked();
    error WrongDecimals();
    // the chain of statements
    error IndexGap();
    error SeqGap();
    error PrevMismatch();
    error NotBackToBack();
    error ConstantChanged();
    error ValueNotCumulative();
    error LengthMismatch();
    // the window
    error PostedTooEarly();
    error WrongToTime();
    error BadWindowStart();
    error BadWindowEnd();
    error ChangeInsideWindow();
    error NoOwner();
    error OwnerMismatch();
    error PayToMismatch();
    error StateChangedInWindow();
    // totals and leaves
    error PaymentsWithoutPayTo();
    error RootCountMismatch();
    error BadAnchor();
    error RebuildMismatch();

    // ------------------------------------------------------------- one entry and its file

    /// @notice The entry carries exactly `file`, `file` is the canonical encoding of `s`, and `s` matches the entry,
    ///         the registry, the limits and the asset's `decimals()`.
    function checkEntry(Context memory ctx, Entry memory e, bytes memory file, Statement memory s) public view {
        if (file.length > Codec.MAX_FILE_BYTES) revert FileTooLarge();
        if (s.anchors.length > Codec.MAX_ANCHORS) revert TooManyAnchors();
        _numbers(s);
        if (s.decimals > Codec.MAX_DECIMALS) revert DecimalsTooLarge();
        if (s.value > Codec.MAX_VALUE) revert ValueTooLarge();
        if (keccak256(bytes(e.feedbackURI)) != keccak256(Codec.dataURI(file))) revert NotDataURI();
        if (e.feedbackHash != keccak256(file)) revert HashMismatch();
        if (keccak256(file) != keccak256(Codec.encode(s))) revert NotCanonical();
        if (s.chainId != ctx.chainId || s.identityRegistry != ctx.identityRegistry) revert RegistryMismatch();
        if (
            e.agentId != s.agentId || e.client != s.writer || e.valueDecimals != s.decimals || e.value < 0
                || uint256(int256(e.value)) != s.value || keccak256(bytes(e.tag1)) != keccak256("revenues")
                || keccak256(bytes(e.tag2)) != keccak256("x402.statement")
        ) revert EntryMismatch();
        if (e.revoked) revert Revoked();
        try IERC20Decimals(s.asset).decimals() returns (uint8 d) {
            if (d != s.decimals) revert WrongDecimals();
        } catch {
            revert WrongDecimals();
        }
    }

    function _numbers(Statement memory s) private pure {
        uint256 m = Codec.MAX_JSON_NUMBER;
        Window memory w = s.window;
        if (s.since > m || s.seq > m || s.count > m || s.payers > m) revert NumberTooLarge();
        if (w.fromBlock > m || w.toBlock > m || w.toTime > m) revert NumberTooLarge();
        for (uint256 i; i < s.anchors.length; ++i) {
            if (s.anchors[i].blockNumber > m || s.anchors[i].paidAt > m) revert NumberTooLarge();
        }
    }

    // ------------------------------------------------------------- the window

    /// @notice The window ended before the entry's block, `toTime` is its last block's time, it starts and ends where
    ///         the agent's change logs allow, none falls inside it, and `owner` and `payTo` are the registry's state in
    ///         force during it.
    function checkWindow(Context memory ctx, Statement memory s, uint64 postedIn) public view {
        Window memory w = s.window;
        IChainHistory h = ctx.history;
        if (w.toBlock >= postedIn) revert PostedTooEarly();
        if (w.toTime != h.blockTime(w.toBlock)) revert WrongToTime();

        // start: log 0 of a block where that is no change log, or the agent's last change log in its block
        (uint32 expected, bool atChange) = Windows.startAt(h, s.identityRegistry, s.agentId, w.fromBlock, w.fromLog);
        if (atChange ? expected != w.fromLog : w.fromLog != 0) revert BadWindowStart();

        // end: after the start, at the end of toBlock or just before a change log
        if (w.toBlock < w.fromBlock || (w.toBlock == w.fromBlock && w.toLog < w.fromLog)) revert BadWindowEnd();
        if (w.toLog != END_OF_BLOCK && !Windows.isChange(h, s.identityRegistry, s.agentId, w.toBlock, w.toLog + 1)) {
            revert BadWindowEnd();
        }

        // no change log after the first position
        IChainHistory.ChangeLog[] memory c = h.changeLogs(s.identityRegistry, s.agentId, w.fromBlock, w.toBlock);
        for (uint256 i; i < c.length; ++i) {
            bool first = c[i].blockNumber == w.fromBlock && c[i].logIndex == w.fromLog;
            if (!first && Windows.contains(w, c[i].blockNumber, c[i].logIndex)) revert ChangeInsideWindow();
        }

        uint64 at = Windows.stateBlock(w.fromBlock, atChange);
        address owner = h.ownerAt(s.identityRegistry, s.agentId, at);
        if (owner == address(0)) revert NoOwner();
        if (s.owner != owner) revert OwnerMismatch();
        if (s.payTo != h.walletAt(s.identityRegistry, s.agentId, at)) revert PayToMismatch();

        // the same owner and wallet at the end of the last block that ends inside the window: a change the registry
        // made without its log would show here, unless it was undone within the window
        (bool hasEnd, uint64 end) = Windows.lastBlockEnd(w);
        if (
            hasEnd
                && (h.ownerAt(s.identityRegistry, s.agentId, end) != owner
                    || h.walletAt(s.identityRegistry, s.agentId, end) != s.payTo)
        ) revert StateChangedInWindow();

        if (s.payTo == address(0) && s.count != 0) revert PaymentsWithoutPayTo();
        if ((s.root == bytes32(0)) != (s.count == 0)) revert RootCountMismatch();
    }

    // ------------------------------------------------------------- anchors (light) and rebuild (full)

    /// @notice Each anchor is a payment of the window in the asset's logs, at its time, in leaf order.
    function checkAnchors(Context memory ctx, Statement memory s) public view {
        if (s.anchors.length > s.count) revert BadAnchor();
        for (uint256 i; i < s.anchors.length; ++i) {
            Anchor memory a = s.anchors[i];
            (bool found, IChainHistory.TransferLog memory t) =
                ctx.history.transferLog(s.asset, a.blockNumber, a.logIndex);
            if (
                !found || t.from != a.payer || t.to != s.payTo || t.value != a.amount || t.txHash != a.txHash
                    || !_isPayment(s, t) || a.paidAt != ctx.history.blockTime(a.blockNumber)
            ) revert BadAnchor();
            if (i > 0) {
                Anchor memory p = s.anchors[i - 1];
                if (p.blockNumber > a.blockNumber || (p.blockNumber == a.blockNumber && p.logIndex >= a.logIndex)) {
                    revert BadAnchor();
                }
            }
        }
    }

    /// @notice The statement is exactly what the asset's logs give: every payment of the window and no other, its
    ///         count, amount, distinct payers, root, and anchors that are its latest leaves.
    function rebuild(Context memory ctx, Statement memory s) public view {
        Anchor[] memory leaves = _payments(ctx.history, s);
        bytes32[] memory hashes = new bytes32[](leaves.length);
        uint256 amount;
        for (uint256 i; i < leaves.length; ++i) {
            amount += leaves[i].amount;
            hashes[i] = Codec.leafHash(
                s.chainId,
                s.asset,
                s.agentId,
                leaves[i].payer,
                s.payTo,
                leaves[i].amount,
                leaves[i].paidAt,
                leaves[i].txHash,
                leaves[i].logIndex
            );
        }
        if (
            leaves.length != s.count || amount != s.amount || _distinctPayers(leaves) != s.payers
                || Codec.root(hashes) != s.root
        ) revert RebuildMismatch();
        uint256 n = s.anchors.length;
        for (uint256 i; i < n; ++i) {
            if (keccak256(abi.encode(s.anchors[i])) != keccak256(abi.encode(leaves[leaves.length - n + i]))) {
                revert RebuildMismatch();
            }
        }
    }

    function _payments(IChainHistory h, Statement memory s) private view returns (Anchor[] memory leaves) {
        if (s.payTo == address(0)) return new Anchor[](0);
        IChainHistory.TransferLog[] memory logs = h.transferLogs(s.asset, s.payTo, s.window.fromBlock, s.window.toBlock);
        leaves = new Anchor[](logs.length);
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (!_isPayment(s, logs[i])) continue;
            IChainHistory.TransferLog memory t = logs[i];
            leaves[n++] = Anchor(t.from, t.value, h.blockTime(t.blockNumber), t.blockNumber, t.txHash, t.logIndex);
        }
        assembly ("memory-safe") {
            mstore(leaves, n)
        }
    }

    /// @dev A Transfer of the asset inside the window, to payTo, of more than nothing, from neither the zero address,
    ///      nor payTo, nor the owner.
    function _isPayment(Statement memory s, IChainHistory.TransferLog memory t) private pure returns (bool) {
        return Windows.contains(s.window, t.blockNumber, t.logIndex) && t.to == s.payTo && s.payTo != address(0)
            && t.value != 0 && t.from != address(0) && t.from != s.payTo && t.from != s.owner;
    }

    /// @dev SHORTCUT: quadratic in the window's payments; a reference, not for windows of thousands of payments.
    function _distinctPayers(Anchor[] memory leaves) private pure returns (uint256 n) {
        for (uint256 i; i < leaves.length; ++i) {
            bool seen;
            for (uint256 j; j < i && !seen; ++j) {
                seen = leaves[j].payer == leaves[i].payer;
            }
            if (!seen) ++n;
        }
    }

    // ------------------------------------------------------------- the chain

    /// @notice The chain holds every entry of its writer for its agent: one per `feedbackIndex` from 1 to the
    ///         Reputation Registry's `getLastIndex(agentId, writer)`, in order, none missing, none twice.
    function checkEntries(Context memory ctx, Chain memory c) public view {
        uint64 last = ctx.history.lastIndex(ctx.reputationRegistry, c.agentId, c.writer);
        if (c.entries.length != last) revert IndexGap();
        for (uint256 i; i < c.entries.length; ++i) {
            Entry memory e = c.entries[i];
            if (e.feedbackIndex != i + 1) revert IndexGap();
            if (e.agentId != c.agentId || e.client != c.writer) revert EntryMismatch();
        }
    }

    /// @notice Whether an entry is a statement of this profile: `tag1` `revenues` and `tag2` `x402.statement`.
    function isStatement(Entry memory e) public pure returns (bool) {
        return
            keccak256(bytes(e.tag1)) == keccak256("revenues") && keccak256(bytes(e.tag2)) == keccak256("x402.statement");
    }

    /// @notice Seq 1: no `prev`, its window starts where `since` allows, and its value is its own amount.
    function checkFirst(Context memory ctx, Statement memory s) public view {
        if (s.seq != 1) revert SeqGap();
        if (s.prev != bytes32(0)) revert PrevMismatch();
        if (s.window.fromBlock != s.since) revert NotBackToBack();
        (uint32 fromLog,) = Windows.startAt(ctx.history, s.identityRegistry, s.agentId, s.since, 0);
        if (s.window.fromLog != fromLog) revert NotBackToBack();
        if (s.value != s.amount) revert ValueNotCumulative();
    }

    /// @notice `s` follows `prev` (whose entry's `feedbackHash` is `prevHash`): next seq, `prev` set, the same agent,
    ///         writer, asset, decimals and `since`, a window that starts right after the previous one, and a value
    ///         that adds this window's amount.
    function checkLink(Context memory ctx, Statement memory prev, bytes32 prevHash, Statement memory s) public view {
        if (s.seq != prev.seq + 1) revert SeqGap();
        if (s.prev != prevHash) revert PrevMismatch();
        if (
            s.chainId != prev.chainId || s.identityRegistry != prev.identityRegistry || s.agentId != prev.agentId
                || s.writer != prev.writer || s.asset != prev.asset || s.decimals != prev.decimals
                || s.since != prev.since
        ) revert ConstantChanged();
        (uint64 b, uint32 l) = Windows.nextPosition(prev.window);
        (uint32 fromLog,) = Windows.startAt(ctx.history, s.identityRegistry, s.agentId, b, l);
        if (s.window.fromBlock != b || s.window.fromLog != fromLog) revert NotBackToBack();
        if (s.value != prev.value + s.amount) revert ValueNotCumulative();
    }

    /// @notice Every check of one writer's chain about one agent. The chain must hold all of the writer's entries for
    ///         the agent; the checker picks the statements among them, so a malformed statement or a repeated `seq`
    ///         anywhere fails the writer. Light (`full` false) samples the anchors, so its result is `Sampled`; full
    ///         rebuilds every statement, and only then is the result `Rebuilt`. The value is the last statement's
    ///         cumulative value, through the end of its window.
    function readChain(Context memory ctx, Chain memory c, bool full) public view returns (Result memory r) {
        uint256 n = c.entries.length;
        if (c.files.length != n || c.statements.length != n) revert LengthMismatch();
        checkEntries(ctx, c);
        Statement memory last;
        bytes32 lastHash;
        bool any;
        for (uint256 i; i < n; ++i) {
            if (!isStatement(c.entries[i])) continue;
            Statement memory s = c.statements[i];
            checkEntry(ctx, c.entries[i], c.files[i], s);
            checkWindow(ctx, s, c.entries[i].blockNumber);
            checkAnchors(ctx, s);
            if (!any) checkFirst(ctx, s);
            else checkLink(ctx, last, lastHash, s);
            if (full) rebuild(ctx, s);
            (last, lastHash, any) = (s, c.entries[i].feedbackHash, true);
        }
        if (!any) return r; // Status.NoData
        r = Result(
            full ? Status.Rebuilt : Status.Sampled,
            last.writer,
            last.asset,
            last.value,
            last.window.toBlock,
            last.window.toLog,
            last.window.toTime
        );
    }

    /// @notice `readChain` for several writers about one agent; a writer whose chain fails any rule is `Failed`, and
    ///         the others are read as usual.
    function readAll(Context memory ctx, Chain[] memory chains, bool full) external view returns (Result[] memory out) {
        out = new Result[](chains.length);
        for (uint256 i; i < chains.length; ++i) {
            try this.readChain(ctx, chains[i], full) returns (Result memory r) {
                out[i] = r;
            } catch {
                out[i].status = Status.Failed;
            }
        }
    }

    /// @notice The agent's income in `asset`: one chain's value, never a sum or an average of several. A rebuilt
    ///         chain is preferred to a sampled one, and among those the one that reaches furthest. `NoData` when no
    ///         chain qualifies, `AssetNotCounted` when the reader does not count `asset`.
    function income(Result[] memory results, address asset, address[] memory countedAssets)
        public
        pure
        returns (Result memory best)
    {
        bool counted;
        for (uint256 i; i < countedAssets.length; ++i) {
            counted = counted || countedAssets[i] == asset;
        }
        if (!counted) {
            best.status = Status.AssetNotCounted;
            best.asset = asset;
            return best;
        }
        for (uint256 i; i < results.length; ++i) {
            Result memory r = results[i];
            if (r.asset != asset || (r.status != Status.Sampled && r.status != Status.Rebuilt)) continue;
            if (best.status == Status.NoData || _better(r, best)) best = r;
        }
    }

    function _better(Result memory a, Result memory b) private pure returns (bool) {
        if (a.status != b.status) return a.status == Status.Rebuilt;
        if (a.throughBlock != b.throughBlock) return a.throughBlock > b.throughBlock;
        return a.throughLog > b.throughLog;
    }
}

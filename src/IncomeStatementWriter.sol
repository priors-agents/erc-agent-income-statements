// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {IChainHistory} from "./IChainHistory.sol";
import {Statement, Window, Anchor, END_OF_BLOCK} from "./IncomeStatementTypes.sol";
import {IncomeStatementCodec as Codec} from "./IncomeStatementCodec.sol";
import {IncomeStatementWindows as Windows} from "./IncomeStatementWindows.sol";

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

/// @title IncomeStatementWriter
/// @notice Reference writer of the Agent Income Statements draft: builds an agent's next statement from the chain (a
///         window that stops before the agent's next change log, its payments, totals, root and anchors) and returns
///         the canonical file with its `data:` URI and `feedbackHash`, ready for `giveFeedback`. It only reads: posting
///         is the writer's own transaction.
/// @dev Not audited. A reference for the interface.
contract IncomeStatementWriter {
    /// @notice What the writer is asked for. `lastBlock` is the last block the window may cover, at the latest the
    ///         block before the one the entry will be posted in; `anchors` is how many leaves to carry in full.
    struct Input {
        uint256 chainId;
        address identityRegistry;
        uint256 agentId;
        address writer;
        address asset;
        uint8 decimals;
        uint64 lastBlock;
        uint64 createdAt;
        uint256 anchors;
    }

    struct Output {
        Statement statement;
        bytes file;
        string feedbackURI;
        bytes32 feedbackHash;
    }

    error NothingToWrite();
    error NoOwner();
    error ChainMismatch();
    error DecimalsTooLarge();
    error WrongDecimals();
    error TooManyAnchors();
    error NumberTooLarge();
    error ValueTooLarge();
    error FileTooLarge();
    error ChangeWithoutLog();

    /// @notice Seq 1, starting at block `since`.
    function first(Input memory input, uint64 since, IChainHistory h) external view returns (Output memory out) {
        _checkInput(input);
        (uint32 fromLog, bool atChange) = Windows.startAt(h, input.identityRegistry, input.agentId, since, 0);
        out.statement.seq = 1;
        out.statement.since = since;
        _build(input, out, since, fromLog, atChange, 0, h);
    }

    /// @notice The statement after `prev`, whose entry's `feedbackHash` is `prevHash`.
    function next(Input memory input, Statement memory prev, bytes32 prevHash, IChainHistory h)
        external
        view
        returns (Output memory out)
    {
        // what a chain keeps comes from its previous statement; an input that differs is a mistake, not a new chain
        if (
            input.chainId != prev.chainId || input.identityRegistry != prev.identityRegistry
                || input.agentId != prev.agentId || input.writer != prev.writer || input.asset != prev.asset
                || input.decimals != prev.decimals
        ) revert ChainMismatch();
        _checkInput(input);
        (uint64 b, uint32 l) = Windows.nextPosition(prev.window);
        (uint32 fromLog, bool atChange) = Windows.startAt(h, input.identityRegistry, input.agentId, b, l);
        out.statement.seq = prev.seq + 1;
        out.statement.prev = prevHash;
        out.statement.since = prev.since;
        _build(input, out, b, fromLog, atChange, prev.value, h);
    }

    function _build(
        Input memory input,
        Output memory out,
        uint64 fromBlock,
        uint32 fromLog,
        bool atChange,
        uint256 before,
        IChainHistory h
    ) private view {
        if (input.lastBlock < fromBlock) revert NothingToWrite();
        Statement memory s = out.statement;
        s.chainId = input.chainId;
        s.identityRegistry = input.identityRegistry;
        s.agentId = input.agentId;
        s.writer = input.writer;
        s.createdAt = input.createdAt;
        s.asset = input.asset;
        s.decimals = input.decimals;

        (uint64 toBlock, uint32 toLog) =
            Windows.endFrom(h, input.identityRegistry, input.agentId, fromBlock, fromLog, input.lastBlock);
        s.window = Window(fromBlock, fromLog, toBlock, toLog, h.blockTime(toBlock));

        uint64 at = Windows.stateBlock(fromBlock, atChange);
        s.owner = h.ownerAt(input.identityRegistry, input.agentId, at);
        if (s.owner == address(0)) revert NoOwner();
        s.payTo = h.walletAt(input.identityRegistry, input.agentId, at);
        _checkUnchanged(s, h);

        Anchor[] memory leaves = _payments(s, h);
        s.count = leaves.length;
        bytes32[] memory hashes = new bytes32[](leaves.length);
        for (uint256 i; i < leaves.length; ++i) {
            s.amount += leaves[i].amount;
            hashes[i] = _leaf(s, leaves[i]);
        }
        s.payers = _distinctPayers(leaves);
        s.root = Codec.root(hashes);
        s.value = before + s.amount;

        uint256 n = input.anchors < leaves.length ? input.anchors : leaves.length;
        s.anchors = new Anchor[](n);
        for (uint256 i; i < n; ++i) {
            s.anchors[i] = leaves[leaves.length - n + i];
        }

        out.file = Codec.encode(s);
        while (out.file.length > Codec.TARGET_FILE_BYTES && s.anchors.length > 0) {
            Anchor[] memory fewer = new Anchor[](s.anchors.length - 1);
            for (uint256 i; i < fewer.length; ++i) {
                fewer[i] = s.anchors[i + 1]; // the oldest goes first
            }
            s.anchors = fewer;
            out.file = Codec.encode(s);
        }
        _checkLimits(s, out.file);
        out.feedbackURI = string(Codec.dataURI(out.file));
        out.feedbackHash = keccak256(out.file);
    }

    /// @dev The owner and wallet at the end of the last block ending inside the window are those at its start: a
    ///      registry that changed either without its log is outside this profile.
    function _checkUnchanged(Statement memory s, IChainHistory h) private view {
        (bool hasEnd, uint64 end) = Windows.lastBlockEnd(s.window);
        if (
            hasEnd
                && (h.ownerAt(s.identityRegistry, s.agentId, end) != s.owner
                    || h.walletAt(s.identityRegistry, s.agentId, end) != s.payTo)
        ) revert ChangeWithoutLog();
    }

    function _checkInput(Input memory input) private view {
        if (input.decimals > Codec.MAX_DECIMALS) revert DecimalsTooLarge();
        if (input.anchors > Codec.MAX_ANCHORS) revert TooManyAnchors();
        try IERC20Decimals(input.asset).decimals() returns (uint8 d) {
            if (d != input.decimals) revert WrongDecimals();
        } catch {
            revert WrongDecimals();
        }
    }

    /// @dev The limits a reader enforces. The file cannot pass 4 KB with the anchors dropped above, and a file with no
    ///      anchor is under 1 KB, so the size check guards the encoding rather than any input.
    function _checkLimits(Statement memory s, bytes memory file) private pure {
        uint256 m = Codec.MAX_JSON_NUMBER;
        if (s.since > m || s.window.toBlock > m || s.window.toTime > m || s.count > m) revert NumberTooLarge();
        if (s.value > Codec.MAX_VALUE) revert ValueTooLarge();
        if (file.length > Codec.MAX_FILE_BYTES) revert FileTooLarge();
    }

    /// @dev Every Transfer of the asset to payTo inside the window that is a payment, in log order.
    function _payments(Statement memory s, IChainHistory h) private view returns (Anchor[] memory leaves) {
        if (s.payTo == address(0)) return new Anchor[](0);
        IChainHistory.TransferLog[] memory logs = h.transferLogs(s.asset, s.payTo, s.window.fromBlock, s.window.toBlock);
        leaves = new Anchor[](logs.length);
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            IChainHistory.TransferLog memory t = logs[i];
            if (!Windows.contains(s.window, t.blockNumber, t.logIndex)) continue;
            if (t.value == 0 || t.from == address(0) || t.from == s.payTo || t.from == s.owner) continue;
            leaves[n++] = Anchor(t.from, t.value, h.blockTime(t.blockNumber), t.blockNumber, t.txHash, t.logIndex);
        }
        assembly ("memory-safe") {
            mstore(leaves, n) // shrink to the payments found
        }
    }

    function _leaf(Statement memory s, Anchor memory a) private pure returns (bytes32) {
        return Codec.leafHash(s.chainId, s.asset, s.agentId, a.payer, s.payTo, a.amount, a.paidAt, a.txHash, a.logIndex);
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
}

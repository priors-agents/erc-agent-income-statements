// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {IChainHistory} from "./IChainHistory.sol";
import {Window, END_OF_BLOCK} from "./IncomeStatementTypes.sol";

/// @title IncomeStatementWindows
/// @notice Where windows start and end. An agent's change logs (an ERC-721 `Transfer` of the agent, a `MetadataSet` for
///         its `agentWallet`) cut windows at log positions, so a transfer is counted under the owner and wallet in force
///         at its own log, never under ones set later in the same block.
/// @dev Not audited. A reference for the draft.
library IncomeStatementWindows {
    /// @notice The first position after the window's last one.
    function nextPosition(Window memory w) internal pure returns (uint64 blockNumber, uint32 logIndex) {
        if (w.toLog == END_OF_BLOCK) return (w.toBlock + 1, 0);
        return (w.toBlock, w.toLog + 1);
    }

    /// @notice Where a window that would start at (`b`, `l`) starts: at the agent's last change log in block `b` when
    ///         (`b`, `l`) is one of its change logs, and at (`b`, `l`) otherwise. `atChange` says which.
    function startAt(IChainHistory h, address registry, uint256 agentId, uint64 b, uint32 l)
        internal
        view
        returns (uint32 fromLog, bool atChange)
    {
        IChainHistory.ChangeLog[] memory c = h.changeLogs(registry, agentId, b, b);
        for (uint256 i; i < c.length; ++i) {
            if (c[i].logIndex == l) return (c[c.length - 1].logIndex, true);
        }
        return (l, false);
    }

    /// @notice Whether (`b`, `l`) is one of the agent's change logs.
    function isChange(IChainHistory h, address registry, uint256 agentId, uint64 b, uint32 l)
        internal
        view
        returns (bool)
    {
        IChainHistory.ChangeLog[] memory c = h.changeLogs(registry, agentId, b, b);
        for (uint256 i; i < c.length; ++i) {
            if (c[i].logIndex == l) return true;
        }
        return false;
    }

    /// @notice The last position of a window that starts at (`b`, `fromLog`) and runs at most through block `last`:
    ///         the position just before the agent's next change log, or the end of `last`.
    function endFrom(IChainHistory h, address registry, uint256 agentId, uint64 b, uint32 fromLog, uint64 last)
        internal
        view
        returns (uint64 toBlock, uint32 toLog)
    {
        IChainHistory.ChangeLog[] memory c = h.changeLogs(registry, agentId, b, last);
        for (uint256 i; i < c.length; ++i) {
            if (c[i].blockNumber > b || c[i].logIndex > fromLog) {
                if (c[i].logIndex == 0) return (c[i].blockNumber - 1, END_OF_BLOCK);
                return (c[i].blockNumber, c[i].logIndex - 1);
            }
        }
        return (last, END_OF_BLOCK);
    }

    /// @notice The block at whose end the registry holds the owner and wallet in force during a window: its first block
    ///         when it starts at a change log, the block before otherwise.
    function stateBlock(uint64 fromBlock, bool atChange) internal pure returns (uint64) {
        return atChange ? fromBlock : fromBlock - 1;
    }

    /// @notice The last block whose end lies inside the window: `toBlock` when the window runs to its end, the block
    ///         before when it ends inside `toBlock`, and none when the window lies inside a single block.
    function lastBlockEnd(Window memory w) internal pure returns (bool hasEnd, uint64 blockNumber) {
        if (w.toLog == END_OF_BLOCK) return (true, w.toBlock);
        if (w.toBlock > w.fromBlock) return (true, w.toBlock - 1);
        return (false, 0);
    }

    /// @notice Whether the log position (`b`, `l`) is inside the window.
    function contains(Window memory w, uint64 b, uint32 l) internal pure returns (bool) {
        bool afterStart = b > w.fromBlock || (b == w.fromBlock && l >= w.fromLog);
        bool beforeEnd = b < w.toBlock || (b == w.toBlock && (w.toLog == END_OF_BLOCK || l <= w.toLog));
        return afterStart && beforeEnd;
    }
}

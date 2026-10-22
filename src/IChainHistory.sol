// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

/// @title IChainHistory
/// @notice The chain reads an income statement reader makes, as one interface: a contract cannot read past blocks, so
///         the reference writer and checker take them from an implementation of this. A reader implements it over an
///         RPC endpoint (block headers, `eth_call` at a block, `eth_getLogs`, the Reputation Registry's
///         `getLastIndex`); the tests implement it with a recorded history.
interface IChainHistory {
    /// @notice An ERC-20 `Transfer` log.
    struct TransferLog {
        uint64 blockNumber;
        uint32 logIndex;
        bytes32 txHash;
        address from;
        address to;
        uint256 value;
    }

    /// @notice The position of one of an agent's change logs: an ERC-721 `Transfer` of the agent, or a `MetadataSet`
    ///         of the agent for the key `agentWallet`, both emitted by the identity registry.
    struct ChangeLog {
        uint64 blockNumber;
        uint32 logIndex;
    }

    /// @notice `getLastIndex(agentId, client)` on the ERC-8004 Reputation Registry: how many entries `client` has
    ///         given the agent, statements or not.
    function lastIndex(address reputationRegistry, uint256 agentId, address client) external view returns (uint64);

    /// @notice The timestamp of a block.
    function blockTime(uint64 blockNumber) external view returns (uint64);

    /// @notice `ownerOf(agentId)` at the end of a block; the zero address when it reverts.
    function ownerAt(address registry, uint256 agentId, uint64 blockNumber) external view returns (address);

    /// @notice `getAgentWallet(agentId)` at the end of a block.
    function walletAt(address registry, uint256 agentId, uint64 blockNumber) external view returns (address);

    /// @notice `getMetadata(agentId, key)` at the end of a block.
    function metadataAt(address registry, uint256 agentId, string calldata key, uint64 blockNumber)
        external
        view
        returns (bytes memory);

    /// @notice The agent's change logs in blocks `fromBlock` to `toBlock`, in log order.
    function changeLogs(address registry, uint256 agentId, uint64 fromBlock, uint64 toBlock)
        external
        view
        returns (ChangeLog[] memory);

    /// @notice Every `Transfer` log of `asset` whose `to` is `to`, in blocks `fromBlock` to `toBlock`, in log order.
    function transferLogs(address asset, address to, uint64 fromBlock, uint64 toBlock)
        external
        view
        returns (TransferLog[] memory);

    /// @notice The `Transfer` log of `asset` at (`blockNumber`, `logIndex`), if there is one.
    function transferLog(address asset, uint64 blockNumber, uint32 logIndex)
        external
        view
        returns (bool found, TransferLog memory log);
}

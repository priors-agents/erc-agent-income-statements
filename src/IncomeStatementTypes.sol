// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

/// @dev `Window.toLog` when the window runs to the end of `toBlock` (written `null` in the file).
uint32 constant END_OF_BLOCK = type(uint32).max;

/// @notice A statement's window: from the log position (`fromBlock`, `fromLog`) to (`toBlock`, `toLog`), both
///         included. Positions are ordered by block, then by log index within the block.
struct Window {
    uint64 fromBlock;
    uint32 fromLog;
    uint64 toBlock;
    uint32 toLog; // END_OF_BLOCK: through the end of toBlock
    uint64 toTime; // the timestamp of toBlock
}

/// @notice A leaf written in full in the file.
struct Anchor {
    address payer;
    uint256 amount;
    uint64 paidAt;
    uint64 blockNumber;
    bytes32 txHash;
    uint32 logIndex;
}

/// @notice The decoded fields of a statement file. Its canonical encoding (IncomeStatementCodec.encode) is the file.
struct Statement {
    uint256 chainId; // the chain of the identity registry, the writer and the asset
    address identityRegistry;
    uint256 agentId;
    address writer; // clientAddress
    uint64 createdAt;
    uint256 value; // cumulative income from seq 1's first position through this window's last position
    address asset;
    uint8 decimals;
    uint64 since; // seq 1's fromBlock
    uint64 seq;
    bytes32 prev; // the previous statement's feedbackHash; zero (null in the file) for seq 1
    Window window;
    address owner;
    address payTo; // zero: null in the file, no agentWallet during the window
    uint256 count;
    uint256 amount;
    uint256 payers;
    bytes32 root;
    Anchor[] anchors;
}

// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

/// @title Agent Income Statements verifier (draft ERC)
/// @notice Checks on chain that one payment an agent received is a leaf of an income statement's Merkle root. It checks
///         membership only: whether to trust the root is the caller's decision.
/// @dev The ERC-165 identifier is `type(IIncomeStatementVerifier).interfaceId`.
interface IIncomeStatementVerifier {
    /// @notice One payment: a `Transfer` log of `asset` from `payer` to the agent's `payTo`. Every field is committed.
    struct Payment {
        uint256 chainId; // the chain the asset and the log are on
        address asset; // the ERC-20 token that emitted the log
        uint256 agentId;
        address owner; // the agent's owner during the statement's window
        address payer; // the log's `from`
        address payTo; // the log's `to`: the agent's agentWallet during the statement's window
        uint256 amount; // the log's `value`, in the asset's base units
        uint64 paidAt; // the timestamp of the block holding the log
        bytes32 txHash;
        uint32 logIndex; // the log's index in its block
    }

    event PaymentProven(uint256 indexed agentId, bytes32 indexed root, bytes32 txHash, uint32 logIndex);

    /// @notice The leaf hash of `payment`, as the statement's Merkle tree commits it.
    function leafHash(Payment calldata payment) external pure returns (bytes32);

    /// @notice True, with a `PaymentProven` event, when `payment` is a payment and `proof` proves its leaf in `root`;
    ///         false otherwise, without an event and without reverting.
    function verifyPayment(bytes32 root, bytes32[] calldata proof, Payment calldata payment) external returns (bool);
}

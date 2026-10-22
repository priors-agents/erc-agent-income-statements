// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {IIncomeStatementVerifier} from "./IIncomeStatementVerifier.sol";

interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

/// @title IncomeStatementVerifier
/// @notice Reference implementation of the Agent Income Statements verifier. It holds no state: it computes a payment's
///         leaf hash, refuses a transfer that cannot be a payment, and checks a Merkle proof with sorted pairs, the
///         tree OpenZeppelin's `MerkleProof` verifies, written out here so it needs no dependency.
/// @dev Not audited. A reference for the interface.
contract IncomeStatementVerifier is IIncomeStatementVerifier, IERC165 {
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IIncomeStatementVerifier).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @dev keccak256(bytes.concat(keccak256(abi.encode(fields)))): the double hash keeps a leaf from ever being read
    ///      as an inner node of the tree.
    function leafHash(Payment calldata p) public pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(
                        p.chainId,
                        p.asset,
                        p.agentId,
                        p.owner,
                        p.payer,
                        p.payTo,
                        p.amount,
                        p.paidAt,
                        p.txHash,
                        p.logIndex
                    )
                )
            )
        );
    }

    function verifyPayment(bytes32 root, bytes32[] calldata proof, Payment calldata p) external returns (bool) {
        // A mint, a transfer to oneself, a transfer from the owner or a transfer of nothing is never a leaf of a valid
        // statement.
        if (p.amount == 0 || p.payer == address(0) || p.payer == p.payTo || p.payer == p.owner) return false;
        bytes32 h = leafHash(p);
        for (uint256 i; i < proof.length; ++i) {
            h = _hashPair(h, proof[i]);
        }
        if (h != root) return false;
        emit PaymentProven(p.agentId, root, p.txHash, p.logIndex);
        return true;
    }

    /// @dev The smaller hash first, as OpenZeppelin's `Hashes.commutativeKeccak256`.
    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? _hash(a, b) : _hash(b, a);
    }

    function _hash(bytes32 a, bytes32 b) private pure returns (bytes32 value) {
        assembly ("memory-safe") {
            mstore(0x00, a)
            mstore(0x20, b)
            value := keccak256(0x00, 0x40)
        }
    }
}

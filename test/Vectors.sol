// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IIncomeStatementVerifier} from "../src/IIncomeStatementVerifier.sol";

/// The test vectors of the ERC text ("Test Cases"): one window of Transfer logs into an agent's payTo, the five payments
/// among them, their leaf hashes, proofs and root, two chained statement files with their exact bytes, and a Merkle
/// tree builder written independently of the reference code.
abstract contract Vectors is Test {
    address constant REGISTRY = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
    address constant WRITER = 0x00000000000000000000000000000000000000C1;
    uint256 constant CHAIN_ID = 1;
    address constant ASSET = 0x00000000000000000000000000000000000a55E7;
    uint256 constant AGENT = 9007199254740993; // 2^53 + 1: read as a floating-point number, it is another agent
    address constant OWNER = 0x000000000000000000000000000000000000041E;
    address constant PAY_TO = 0x0000000000000000000000000000000000000402;
    uint64 constant FIRST_BLOCK = 26000000;
    uint64 constant FIRST_TIME = 1790000000;

    bytes32 constant ROOT = 0x520ba6ddc52623d5852649d9c9237f6ad5b35794d9413bc3903741f428abf238;

    string constant FILE1 =
        '{"agentId":"9007199254740993","agentRegistry":"eip155:1:0x8004A169FB4a3325136EB29fA0ceB6D2e539a432","clientAddress":"eip155:1:0x00000000000000000000000000000000000000C1","createdAt":"2026-09-28T13:53:08Z","income":{"anchors":[{"amount":"10000","block":26000010,"log":3,"paidAt":1790000120,"payer":"0x00000000000000000000000000000000000000B1","tx":"0x00000000000000000000000000000000000000000000000000000000000000a1"},{"amount":"2500","block":26000010,"log":7,"paidAt":1790000120,"payer":"0x00000000000000000000000000000000000000b2","tx":"0x00000000000000000000000000000000000000000000000000000000000000a2"},{"amount":"1000000","block":26003001,"log":0,"paidAt":1790036012,"payer":"0x00000000000000000000000000000000000000B1","tx":"0x00000000000000000000000000000000000000000000000000000000000000a3"},{"amount":"50000","block":26020000,"log":12,"paidAt":1790240000,"payer":"0x00000000000000000000000000000000000000b3","tx":"0x00000000000000000000000000000000000000000000000000000000000000a4"},{"amount":"10000","block":26049999,"log":1,"paidAt":1790599988,"payer":"0x00000000000000000000000000000000000000B4","tx":"0x00000000000000000000000000000000000000000000000000000000000000a5"}],"asset":"eip155:1/erc20:0x00000000000000000000000000000000000a55E7","decimals":6,"owner":"0x000000000000000000000000000000000000041E","payTo":"0x0000000000000000000000000000000000000402","payers":4,"prev":null,"received":{"amount":"1072500","count":5},"root":"0x520ba6ddc52623d5852649d9c9237f6ad5b35794d9413bc3903741f428abf238","seq":1,"since":26000000,"v":"erc8004-income/v1","window":{"fromBlock":26000000,"fromLog":0,"toBlock":26049999,"toLog":null,"toTime":1790599988}},"tag1":"revenues","tag2":"x402.statement","value":"1072500","valueDecimals":6}';
    bytes32 constant FILE1_HASH = 0xbf23a8780b9fbdf0e12b68a92d3f66556c4c6d0ce6e15c5e0df1810af6e368ee;

    string constant FILE2 =
        '{"agentId":"9007199254740993","agentRegistry":"eip155:1:0x8004A169FB4a3325136EB29fA0ceB6D2e539a432","clientAddress":"eip155:1:0x00000000000000000000000000000000000000C1","createdAt":"2026-10-05T12:33:08Z","income":{"anchors":[],"asset":"eip155:1/erc20:0x00000000000000000000000000000000000a55E7","decimals":6,"owner":"0x000000000000000000000000000000000000041E","payTo":"0x0000000000000000000000000000000000000402","payers":0,"prev":"0xbf23a8780b9fbdf0e12b68a92d3f66556c4c6d0ce6e15c5e0df1810af6e368ee","received":{"amount":"0","count":0},"root":"0x0000000000000000000000000000000000000000000000000000000000000000","seq":2,"since":26000000,"v":"erc8004-income/v1","window":{"fromBlock":26050000,"fromLog":0,"toBlock":26099999,"toLog":null,"toTime":1791199988}},"tag1":"revenues","tag2":"x402.statement","value":"1072500","valueDecimals":6}';
    bytes32 constant FILE2_HASH = 0xeea2227a6c70110c0d147bbd5b8bb7a80ea6ea21a3e0dab7c1545db0f8488520;

    /// A Transfer log of ASSET whose `to` is PAY_TO.
    struct VectorLog {
        uint64 blockNumber;
        uint32 logIndex;
        address from;
        uint256 amount;
        bytes32 txHash;
    }

    // ------------------------------------------------------------- vectors

    /// Every Transfer log of ASSET to PAY_TO in seq 1's window, blocks 26000000 to 26049999, in log order.
    function _window() internal pure returns (VectorLog[] memory l) {
        l = new VectorLog[](9);
        l[0] = VectorLog(26000010, 3, 0x00000000000000000000000000000000000000B1, 10000, bytes32(uint256(0xa1)));
        l[1] = VectorLog(26000010, 7, 0x00000000000000000000000000000000000000b2, 2500, bytes32(uint256(0xa2)));
        l[2] = VectorLog(26000500, 2, OWNER, 500000, bytes32(uint256(0xa6))); // the owner: not a payment
        l[3] = VectorLog(26003001, 0, 0x00000000000000000000000000000000000000B1, 1000000, bytes32(uint256(0xa3)));
        l[4] = VectorLog(26010000, 4, 0x00000000000000000000000000000000000000b5, 0, bytes32(uint256(0xa7))); // zero
        l[5] = VectorLog(26020000, 12, 0x00000000000000000000000000000000000000b3, 50000, bytes32(uint256(0xa4)));
        l[6] = VectorLog(26030000, 0, address(0), 7000, bytes32(uint256(0xa8))); // a mint: not a payment
        l[7] = VectorLog(26040000, 5, PAY_TO, 3000, bytes32(uint256(0xa9))); // to itself: not a payment
        l[8] = VectorLog(26049999, 1, 0x00000000000000000000000000000000000000B4, 10000, bytes32(uint256(0xa5)));
    }

    function _leafHashes() internal pure returns (bytes32[] memory h) {
        h = new bytes32[](5);
        h[0] = 0x973838fd10839c33761186ef4e63069cb758e3ec534221eaa42705f06c46c4ec;
        h[1] = 0x9e191334aadc974cad9b88b02911142857fbecfb0d4db28e6d561c880dc54e60;
        h[2] = 0x04e8b3fcfeca684cb61d0f4a3d48965c91250c785218d23d20e25367df5b00e4;
        h[3] = 0xe94b8baca86013e08d72e5cbf5e8c6daafba4961cdd79c441e3e444e9735c132;
        h[4] = 0x46894c3239fd5fda0dbf685ec1e94b3b81dbc215f4b07d4e747e36530d0effbd;
    }

    function _vectorProof(uint256 i) internal pure returns (bytes32[] memory p) {
        bytes32 l01 = 0x04dbfb095919cbe6bf6dffbe366a9899d44bfd271495dc7b820f6e24d56e2830;
        bytes32 l23 = 0x9705053cd0b8cdc5dd701db3fa3b5bc7b150cf53d42c09e1e05d1e130ae84047;
        bytes32 l0123 = 0x94f6220ecbb45711f1cb5c30a80950a103742d8831136ae8db6abc2efa379fda;
        bytes32[] memory h = _leafHashes();
        if (i == 4) {
            p = new bytes32[](1);
            p[0] = l0123;
            return p;
        }
        p = new bytes32[](3);
        p[0] = h[i ^ 1];
        p[1] = i < 2 ? l23 : l01;
        p[2] = h[4];
    }

    function _time(uint64 blockNumber) internal pure returns (uint64) {
        return FIRST_TIME + 12 * (blockNumber - FIRST_BLOCK);
    }

    function _paymentOf(VectorLog memory l) internal pure returns (IIncomeStatementVerifier.Payment memory) {
        return IIncomeStatementVerifier.Payment({
            chainId: CHAIN_ID,
            asset: ASSET,
            agentId: AGENT,
            owner: OWNER,
            payer: l.from,
            payTo: PAY_TO,
            amount: l.amount,
            paidAt: _time(l.blockNumber),
            txHash: l.txHash,
            logIndex: l.logIndex
        });
    }

    /// The reader's rule: a Transfer to payTo is a payment unless it is of zero, from the zero address, from payTo itself
    /// or from the agent's owner.
    function _isPayment(VectorLog memory l) internal pure returns (bool) {
        return l.amount != 0 && l.from != address(0) && l.from != PAY_TO && l.from != OWNER;
    }

    /// The window's payments, in leaf order (the logs are already in block and log order).
    function _payments() internal pure returns (IIncomeStatementVerifier.Payment[] memory p) {
        VectorLog[] memory logs = _window();
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (_isPayment(logs[i])) ++n;
        }
        p = new IIncomeStatementVerifier.Payment[](n);
        n = 0;
        for (uint256 i; i < logs.length; ++i) {
            if (_isPayment(logs[i])) p[n++] = _paymentOf(logs[i]);
        }
    }

    // ------------------------------------------------------------- a tree builder, independent of the verifier

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /// Root over leaf hashes in order: pairs hashed sorted, an odd last node carried up, bytes32(0) for none.
    function _root(bytes32[] memory level) internal pure returns (bytes32) {
        if (level.length == 0) return bytes32(0);
        while (level.length > 1) {
            bytes32[] memory next = new bytes32[]((level.length + 1) / 2);
            for (uint256 i; i < level.length; i += 2) {
                next[i / 2] = i + 1 < level.length ? _pair(level[i], level[i + 1]) : level[i];
            }
            level = next;
        }
        return level[0];
    }

    function _proofOf(bytes32[] memory level, uint256 index) internal pure returns (bytes32[] memory proof) {
        bytes32[] memory buf = new bytes32[](64);
        uint256 n;
        while (level.length > 1) {
            uint256 sibling = index ^ 1;
            if (sibling < level.length) buf[n++] = level[sibling];
            bytes32[] memory next = new bytes32[]((level.length + 1) / 2);
            for (uint256 i; i < level.length; i += 2) {
                next[i / 2] = i + 1 < level.length ? _pair(level[i], level[i + 1]) : level[i];
            }
            level = next;
            index >>= 1;
        }
        proof = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            proof[i] = buf[i];
        }
    }
}

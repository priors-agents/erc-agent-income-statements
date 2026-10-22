// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {Statement, Window, Anchor, END_OF_BLOCK} from "./IncomeStatementTypes.sol";

/// @title IncomeStatementCodec
/// @notice The statement file's canonical encoding (RFC 8785 for this fixed schema: keys sorted, no whitespace, integers
///         only), its `data:` URI, and the leaf and Merkle root of the Agent Income Statements draft. No dependency.
/// @dev Not audited. A reference for the draft.
library IncomeStatementCodec {
    bytes internal constant DATA_URI_PREFIX = "data:application/json;base64,";
    uint256 internal constant MAX_FILE_BYTES = 8192;
    uint256 internal constant TARGET_FILE_BYTES = 4096;
    uint256 internal constant MAX_ANCHORS = 16;
    uint256 internal constant MAX_JSON_NUMBER = 2 ** 53 - 1;
    uint256 internal constant MAX_VALUE = 2 ** 127 - 1;
    uint8 internal constant MAX_DECIMALS = 18;

    bytes16 private constant HEX = "0123456789abcdef";
    bytes16 private constant HEX_UPPER = "0123456789ABCDEF";
    bytes1 private constant PAD = 0x3d; // "="
    bytes private constant BASE64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    // ------------------------------------------------------------- the file

    /// @notice The canonical bytes of a statement file.
    function encode(Statement memory s) internal pure returns (bytes memory) {
        bytes memory head = bytes.concat(
            '{"agentId":"',
            decimal(s.agentId),
            '","agentRegistry":"',
            caip10(s.chainId, s.identityRegistry),
            '","clientAddress":"',
            caip10(s.chainId, s.writer),
            '","createdAt":"',
            isoTime(s.createdAt),
            '","income":'
        );
        bytes memory tail = bytes.concat(
            ',"tag1":"revenues","tag2":"x402.statement","value":"',
            decimal(s.value),
            '","valueDecimals":',
            decimal(s.decimals),
            "}"
        );
        return bytes.concat(head, _income(s), tail);
    }

    function _income(Statement memory s) private pure returns (bytes memory) {
        bytes memory a = bytes.concat(
            '{"anchors":[',
            _anchors(s.anchors),
            '],"asset":"eip155:',
            decimal(s.chainId),
            "/erc20:",
            checksum(s.asset),
            '","decimals":',
            decimal(s.decimals),
            ',"owner":"',
            checksum(s.owner),
            '","payTo":',
            s.payTo == address(0) ? bytes("null") : bytes.concat('"', checksum(s.payTo), '"')
        );
        bytes memory b = bytes.concat(
            ',"payers":',
            decimal(s.payers),
            ',"prev":',
            s.seq == 1 ? bytes("null") : bytes.concat('"', hex32(s.prev), '"'),
            ',"received":{"amount":"',
            decimal(s.amount),
            '","count":',
            decimal(s.count),
            '},"root":"',
            hex32(s.root),
            '"'
        );
        bytes memory c = bytes.concat(
            ',"seq":',
            decimal(s.seq),
            ',"since":',
            decimal(s.since),
            ',"v":"erc8004-income/v1","window":',
            _window(s.window),
            "}"
        );
        return bytes.concat(a, b, c);
    }

    function _window(Window memory w) private pure returns (bytes memory) {
        return bytes.concat(
            '{"fromBlock":',
            decimal(w.fromBlock),
            ',"fromLog":',
            decimal(w.fromLog),
            ',"toBlock":',
            decimal(w.toBlock),
            ',"toLog":',
            w.toLog == END_OF_BLOCK ? bytes("null") : decimal(w.toLog),
            ',"toTime":',
            decimal(w.toTime),
            "}"
        );
    }

    function _anchors(Anchor[] memory anchors) private pure returns (bytes memory out) {
        for (uint256 i; i < anchors.length; ++i) {
            Anchor memory a = anchors[i];
            out = bytes.concat(
                out,
                i == 0 ? bytes("") : bytes(","),
                '{"amount":"',
                decimal(a.amount),
                '","block":',
                decimal(a.blockNumber),
                ',"log":',
                decimal(a.logIndex),
                ',"paidAt":',
                decimal(a.paidAt),
                ',"payer":"',
                checksum(a.payer),
                '","tx":"',
                hex32(a.txHash),
                '"}'
            );
        }
    }

    /// @notice `data:application/json;base64,` and the padded standard base64 of `file` (RFC 4648).
    function dataURI(bytes memory file) internal pure returns (bytes memory) {
        return bytes.concat(DATA_URI_PREFIX, base64(file));
    }

    function base64(bytes memory data) internal pure returns (bytes memory out) {
        if (data.length == 0) return "";
        bytes memory table = BASE64;
        out = new bytes(4 * ((data.length + 2) / 3));
        uint256 j;
        for (uint256 i; i < data.length; i += 3) {
            uint256 n = uint256(uint8(data[i])) << 16;
            if (i + 1 < data.length) n |= uint256(uint8(data[i + 1])) << 8;
            if (i + 2 < data.length) n |= uint256(uint8(data[i + 2]));
            out[j] = table[(n >> 18) & 63];
            out[j + 1] = table[(n >> 12) & 63];
            out[j + 2] = i + 1 < data.length ? table[(n >> 6) & 63] : PAD;
            out[j + 3] = i + 2 < data.length ? table[n & 63] : PAD;
            j += 4;
        }
    }

    // ------------------------------------------------------------- values

    function decimal(uint256 v) internal pure returns (bytes memory b) {
        if (v == 0) return "0";
        uint256 len;
        for (uint256 t = v; t != 0; t /= 10) {
            ++len;
        }
        b = new bytes(len);
        while (v != 0) {
            b[--len] = HEX[v % 10];
            v /= 10;
        }
    }

    /// @notice An address in ERC-55 mixed-case checksum form.
    function checksum(address a) internal pure returns (bytes memory out) {
        uint256 v = uint256(uint160(a));
        bytes memory lower = new bytes(40);
        for (uint256 i; i < 40; ++i) {
            lower[i] = HEX[(v >> (4 * (39 - i))) & 0xf];
        }
        uint256 h = uint256(keccak256(lower));
        out = new bytes(42);
        out[0] = "0";
        out[1] = "x";
        for (uint256 i; i < 40; ++i) {
            uint256 nibble = (v >> (4 * (39 - i))) & 0xf;
            bool upper = nibble > 9 && ((h >> (4 * (63 - i))) & 0xf) >= 8;
            out[i + 2] = upper ? HEX_UPPER[nibble] : HEX[nibble];
        }
    }

    function hex32(bytes32 v) internal pure returns (bytes memory out) {
        out = new bytes(66);
        out[0] = "0";
        out[1] = "x";
        for (uint256 i; i < 64; ++i) {
            out[i + 2] = HEX[(uint256(v) >> (4 * (63 - i))) & 0xf];
        }
    }

    function caip10(uint256 chainId, address a) internal pure returns (bytes memory) {
        return bytes.concat("eip155:", decimal(chainId), ":", checksum(a));
    }

    /// @notice A unix time as UTC to the second, `YYYY-MM-DDTHH:MM:SSZ`.
    function isoTime(uint256 t) internal pure returns (bytes memory) {
        (uint256 y, uint256 m, uint256 d) = _civil(t / 86400);
        uint256 s = t % 86400;
        return bytes.concat(
            _digits(y, 4),
            "-",
            _digits(m, 2),
            "-",
            _digits(d, 2),
            "T",
            _digits(s / 3600, 2),
            ":",
            _digits((s / 60) % 60, 2),
            ":",
            _digits(s % 60, 2),
            "Z"
        );
    }

    /// @dev Days since 1970-01-01 to a civil date (H. Hinnant, "chrono-Compatible Low-Level Date Algorithms").
    function _civil(uint256 day) private pure returns (uint256 y, uint256 m, uint256 d) {
        uint256 z = day + 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        d = doy - (153 * mp + 2) / 5 + 1;
        m = mp < 10 ? mp + 3 : mp - 9;
        y = yoe + era * 400 + (m <= 2 ? 1 : 0);
    }

    function _digits(uint256 v, uint256 width) private pure returns (bytes memory b) {
        b = new bytes(width);
        for (uint256 i = width; i > 0; --i) {
            b[i - 1] = HEX[v % 10];
            v /= 10;
        }
    }

    // ------------------------------------------------------------- leaves and root

    /// @notice keccak256(bytes.concat(keccak256(abi.encode(the ten fields)))), as OpenZeppelin's MerkleProof expects.
    function leafHash(
        uint256 chainId,
        address asset,
        uint256 agentId,
        address owner,
        address payer,
        address payTo,
        uint256 amount,
        uint64 paidAt,
        bytes32 txHash,
        uint32 logIndex
    ) internal pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                keccak256(abi.encode(chainId, asset, agentId, owner, payer, payTo, amount, paidAt, txHash, logIndex))
            )
        );
    }

    /// @notice The root over leaf hashes in leaf order: pairs hashed sorted, an odd last node carried up unchanged,
    ///         bytes32(0) for none. Overwrites `level`.
    function root(bytes32[] memory level) internal pure returns (bytes32) {
        uint256 n = level.length;
        if (n == 0) return bytes32(0);
        while (n > 1) {
            for (uint256 i; i < n; i += 2) {
                level[i / 2] = i + 1 < n ? hashPair(level[i], level[i + 1]) : level[i];
            }
            n = (n + 1) / 2;
        }
        return level[0];
    }

    function hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }
}

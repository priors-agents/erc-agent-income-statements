// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {Vectors} from "./Vectors.sol";
import {MockChainHistory, MockDecimals, NoDecimals} from "./mocks/Mocks.sol";
import {IChainHistory} from "../src/IChainHistory.sol";
import {IIncomeStatementVerifier} from "../src/IIncomeStatementVerifier.sol";
import {IncomeStatementVerifier} from "../src/IncomeStatementVerifier.sol";
import {Statement, Anchor, END_OF_BLOCK} from "../src/IncomeStatementTypes.sol";
import {IncomeStatementCodec as Codec} from "../src/IncomeStatementCodec.sol";
import {IncomeStatementWriter as Writer} from "../src/IncomeStatementWriter.sol";
import {IncomeStatementChecker as Checker} from "../src/IncomeStatementChecker.sol";

/// The reference writer and checker against a recorded chain: the vectors' window (seq 1 and 2), then four windows cut
/// by the agent's change logs (a wallet change, an owner transfer that clears the wallet, a new wallet).
contract IncomeStatementReaderTest is Vectors {
    address constant P1 = 0x00000000000000000000000000000000000000B1;
    address constant P2 = 0x00000000000000000000000000000000000000b2;
    address constant P3 = 0x00000000000000000000000000000000000000b3;
    address constant P4 = 0x00000000000000000000000000000000000000B4;
    address constant P5 = 0x00000000000000000000000000000000000000b5;
    address constant NEW_WALLET = address(0x4030);
    address constant NEW_OWNER = address(0x0e1);
    address constant NEW_OWNER_WALLET = address(0x4040);
    address constant OTHER = address(0xbad);
    uint64 constant LAST = 26200000;
    address constant REPUTATION = address(0x8004b);

    MockChainHistory h;
    Writer writer;
    Checker checker;

    function setUp() public {
        h = new MockChainHistory(REGISTRY, AGENT, FIRST_BLOCK, FIRST_TIME);
        h.setOwner(25990000, 1, OWNER); // registration: the mint
        h.setWallet(25990000, 2, OWNER); // agentWallet starts as the owner
        h.setWallet(25995000, 0, PAY_TO);
        VectorLog[] memory w = _window();
        for (uint256 i; i < w.length; ++i) {
            h.addTransfer(ASSET, w[i].blockNumber, w[i].logIndex, w[i].txHash, w[i].from, PAY_TO, w[i].amount);
        }
        deployCodeTo("Mocks.sol:MockDecimals", abi.encode(uint8(6)), ASSET);
        writer = new Writer();
        checker = new Checker();
    }

    /// After the vectors' two windows: the wallet moves to NEW_WALLET at (26100005, 3); the owner transfers the agent
    /// to NEW_OWNER at (26150000, 8), the registry clearing the wallet at (26150000, 6); NEW_OWNER sets
    /// NEW_OWNER_WALLET at (26160000, 0).
    function _transitions() internal {
        h.addTransfer(ASSET, 26100005, 1, bytes32(uint256(0xb1)), P3, PAY_TO, 9000); // old wallet, before the change
        h.addTransfer(ASSET, 26100005, 2, bytes32(uint256(0xb2)), P1, NEW_WALLET, 7000); // new wallet, before it is
        h.setWallet(26100005, 3, NEW_WALLET);
        h.addTransfer(ASSET, 26100005, 4, bytes32(uint256(0xb3)), P2, NEW_WALLET, 8000); // new wallet, after
        h.addTransfer(ASSET, 26100005, 5, bytes32(uint256(0xb4)), P4, PAY_TO, 6000); // old wallet, after
        h.addTransfer(ASSET, 26150000, 5, bytes32(uint256(0xb5)), P1, NEW_WALLET, 1111);
        h.setWallet(26150000, 6, address(0)); // a transfer clears the wallet
        h.addTransfer(ASSET, 26150000, 7, bytes32(uint256(0xb6)), P3, NEW_WALLET, 3333); // between the two logs
        h.setOwner(26150000, 8, NEW_OWNER);
        h.addTransfer(ASSET, 26150000, 9, bytes32(uint256(0xb7)), P2, NEW_WALLET, 2222); // no wallet any more
        h.setWallet(26160000, 0, NEW_OWNER_WALLET);
        h.addTransfer(ASSET, 26160000, 1, bytes32(uint256(0xb8)), P5, NEW_OWNER_WALLET, 4444);
        h.addTransfer(ASSET, 26160000, 2, bytes32(uint256(0xb9)), NEW_OWNER, NEW_OWNER_WALLET, 5555); // the owner
    }

    // ------------------------------------------------------------- helpers

    function _ctx() internal view returns (Checker.Context memory) {
        return Checker.Context(CHAIN_ID, REGISTRY, REPUTATION, IChainHistory(address(h)));
    }

    function _input(uint64 lastBlock, uint256 anchors) internal view returns (Writer.Input memory) {
        return
            Writer.Input(CHAIN_ID, REGISTRY, AGENT, WRITER, ASSET, 6, lastBlock, h.blockTime(lastBlock) + 3600, anchors);
    }

    function _s1() internal view returns (Writer.Output memory) {
        return writer.first(_input(26049999, 5), FIRST_BLOCK, h);
    }

    function _s2() internal view returns (Writer.Output memory) {
        Writer.Output memory o1 = _s1();
        return writer.next(_input(26099999, 5), o1.statement, o1.feedbackHash, h);
    }

    /// Seq 1 and 2 (the vectors), then seq 3 to 6 when the transitions are recorded.
    function _outputs(uint256 n) internal view returns (Writer.Output[] memory o) {
        o = new Writer.Output[](n);
        o[0] = _s1();
        for (uint256 i = 1; i < n; ++i) {
            o[i] = writer.next(_input(i == 1 ? 26099999 : LAST, 5), o[i - 1].statement, o[i - 1].feedbackHash, h);
        }
    }

    function _i128(uint256 v) internal pure returns (int128 r) {
        require(v < 2 ** 127, "int128");
        assembly {
            r := v
        }
    }

    function _entry(Writer.Output memory o, uint64 index, uint64 postedIn)
        internal
        pure
        returns (Checker.Entry memory)
    {
        Statement memory s = o.statement;
        return Checker.Entry(
            s.agentId,
            s.writer,
            index,
            _i128(s.value),
            s.decimals,
            "revenues",
            "x402.statement",
            o.feedbackURI,
            o.feedbackHash,
            postedIn,
            false
        );
    }

    /// The entry and file a writer would post for `s` as it is.
    function _signed(Statement memory s) internal pure returns (Checker.Entry memory e, bytes memory file) {
        file = Codec.encode(s);
        Writer.Output memory o;
        o.statement = s;
        o.file = file;
        o.feedbackURI = string(Codec.dataURI(file));
        o.feedbackHash = keccak256(file);
        e = _entry(o, 1, s.window.toBlock + 1);
    }

    /// The writer's chain for the agent: one entry per output, at indexes 1 to n, and getLastIndex set to n.
    function _chain(Writer.Output[] memory o) internal returns (Checker.Chain memory c) {
        uint256 n = o.length;
        c.agentId = AGENT;
        c.writer = WRITER;
        c.entries = new Checker.Entry[](n);
        c.files = new bytes[](n);
        c.statements = new Statement[](n);
        uint64 index;
        for (uint256 i; i < n; ++i) {
            ++index;
            c.entries[i] = _entry(o[i], index, LAST + 1);
            c.files[i] = o[i].file;
            c.statements[i] = o[i].statement;
        }
        h.setLastIndex(WRITER, index);
    }

    /// An entry of the writer that is not a statement, such as a rating, at `index`.
    function _rating(uint64 index) internal pure returns (Checker.Entry memory) {
        return Checker.Entry(AGENT, WRITER, index, 87, 0, "starred", "", "", bytes32(0), 26000001, false);
    }

    /// A copy of `c` with `e` (and its file and fields) inserted at position `at`, every entry renumbered 1 to n and
    /// getLastIndex set to n. `c` itself is left as it was.
    function _insert(Checker.Chain memory c, uint256 at, Checker.Entry memory e, bytes memory file, Statement memory st)
        internal
        returns (Checker.Chain memory out)
    {
        uint256 n = c.entries.length + 1;
        out.agentId = c.agentId;
        out.writer = c.writer;
        out.entries = new Checker.Entry[](n);
        out.files = new bytes[](n);
        out.statements = new Statement[](n);
        uint64 index;
        for (uint256 i; i < n; ++i) {
            uint256 j = i < at ? i : i - 1;
            Checker.Entry memory pick = i == at ? e : c.entries[j];
            out.entries[i] = abi.decode(abi.encode(pick), (Checker.Entry));
            out.files[i] = i == at ? file : c.files[j];
            out.statements[i] = i == at ? st : c.statements[j];
            out.entries[i].feedbackIndex = ++index;
        }
        h.setLastIndex(c.writer, index);
    }

    function _leaf(Statement memory s, Anchor memory a) internal pure returns (bytes32) {
        return Codec.leafHash(
            s.chainId, s.asset, s.agentId, s.owner, a.payer, s.payTo, a.amount, a.paidAt, a.txHash, a.logIndex
        );
    }

    /// The payment a contract would hand the verifier for leaf `a` of `s`.
    function _paymentFrom(Statement memory s, Anchor memory a)
        internal
        pure
        returns (IIncomeStatementVerifier.Payment memory)
    {
        return IIncomeStatementVerifier.Payment(
            s.chainId, s.asset, s.agentId, s.owner, a.payer, s.payTo, a.amount, a.paidAt, a.txHash, a.logIndex
        );
    }

    /// Seq 1 with only the given leaves (in order): count, amount, payers, root and anchors made to agree with them.
    function _s1With(uint256[] memory keep) internal view returns (Statement memory s) {
        Statement memory full = _s1().statement; // five anchors: every leaf
        s = _s1().statement;
        Anchor[] memory leaves = new Anchor[](keep.length);
        bytes32[] memory hashes = new bytes32[](keep.length);
        s.amount = 0;
        for (uint256 i; i < keep.length; ++i) {
            leaves[i] = full.anchors[keep[i]];
            hashes[i] = _leaf(s, leaves[i]);
            s.amount += leaves[i].amount;
        }
        s.count = keep.length;
        s.root = Codec.root(hashes);
        s.anchors = leaves;
        s.value = s.amount;
    }

    // ------------------------------------------------------------- the writer

    function test_writer_matchesTheVectors() public view {
        Writer.Output memory o1 = _s1();
        assertEq(o1.file, bytes(FILE1));
        assertEq(o1.feedbackHash, FILE1_HASH);
        assertEq(o1.feedbackURI, string.concat("data:application/json;base64,", vm.toBase64(bytes(FILE1))));
        assertEq(o1.statement.root, ROOT);
        Writer.Output memory o2 = _s2();
        assertEq(o2.file, bytes(FILE2));
        assertEq(o2.feedbackHash, FILE2_HASH);
        assertEq(o2.feedbackURI, string.concat("data:application/json;base64,", vm.toBase64(bytes(FILE2))));
    }

    function test_writer_windowsCutAtChangeLogs() public {
        _transitions();
        Writer.Output[] memory o = _outputs(6);

        Statement memory s3 = o[2].statement; // the old wallet, up to the wallet change
        assertEq(s3.window.fromBlock, 26100000);
        assertEq(s3.window.fromLog, 0);
        assertEq(s3.window.toBlock, 26100005);
        assertEq(s3.window.toLog, 2);
        assertEq(s3.payTo, PAY_TO);
        assertEq(s3.count, 1);
        assertEq(s3.amount, 9000); // log 1; not log 5, sent to the old wallet after the change
        assertEq(s3.value, 1072500 + 9000);

        Statement memory s4 = o[3].statement; // the new wallet, from its MetadataSet to the owner transfer
        assertEq(s4.window.fromBlock, 26100005);
        assertEq(s4.window.fromLog, 3);
        assertEq(s4.window.toBlock, 26150000);
        assertEq(s4.window.toLog, 5);
        assertEq(s4.owner, OWNER);
        assertEq(s4.payTo, NEW_WALLET);
        assertEq(s4.count, 2);
        assertEq(s4.amount, 8000 + 1111); // not the 7000 at log 2, paid before NEW_WALLET was the agentWallet
        assertEq(s4.anchors[0].txHash, bytes32(uint256(0xb3)));
        assertEq(s4.anchors[1].txHash, bytes32(uint256(0xb5)));

        Statement memory s5 = o[4].statement; // the new owner, no wallet: starts at the block's last change log
        assertEq(s5.window.fromBlock, 26150000);
        assertEq(s5.window.fromLog, 8);
        assertEq(s5.window.toBlock, 26159999);
        assertEq(s5.window.toLog, END_OF_BLOCK);
        assertEq(s5.owner, NEW_OWNER);
        assertEq(s5.payTo, address(0));
        assertEq(s5.count, 0);

        Statement memory s6 = o[5].statement; // the new owner's wallet
        assertEq(s6.window.fromBlock, 26160000);
        assertEq(s6.window.fromLog, 0);
        assertEq(s6.window.toBlock, LAST);
        assertEq(s6.window.toLog, END_OF_BLOCK);
        assertEq(s6.payTo, NEW_OWNER_WALLET);
        assertEq(s6.count, 1);
        assertEq(s6.amount, 4444); // not the owner's 5555
        assertEq(s6.value, 1072500 + 9000 + 9111 + 4444);
    }

    function test_writer_anchorsAreTheLatestLeaves() public view {
        Writer.Output memory o = writer.first(_input(26049999, 2), FIRST_BLOCK, h);
        assertEq(o.statement.anchors.length, 2);
        assertEq(o.statement.anchors[0].txHash, bytes32(uint256(0xa4)));
        assertEq(o.statement.anchors[1].txHash, bytes32(uint256(0xa5)));
        assertEq(o.statement.root, ROOT);
    }

    function test_writer_refusesAWindowWithNoOwnerOrNoBlocks() public {
        Writer.Input memory early = _input(25980010, 5);
        vm.expectRevert(Writer.NoOwner.selector);
        writer.first(early, 25980000, h); // before the agent was registered
        Writer.Output memory o1 = _s1();
        Writer.Input memory same = _input(26049999, 5);
        vm.expectRevert(Writer.NothingToWrite.selector);
        writer.next(same, o1.statement, o1.feedbackHash, h);
    }

    function test_writer_nextKeepsTheChainOfItsPreviousStatement() public {
        Writer.Output memory o1 = _s1();
        Writer.Input[6] memory bad;
        for (uint256 i; i < bad.length; ++i) {
            bad[i] = _input(26099999, 5);
        }
        bad[0].chainId = 8453;
        bad[1].identityRegistry = OTHER;
        bad[2].agentId = AGENT + 1;
        bad[3].writer = OTHER;
        bad[4].asset = OTHER;
        bad[5].decimals = 18;
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(Writer.ChainMismatch.selector);
            writer.next(bad[i], o1.statement, o1.feedbackHash, h);
        }
    }

    function test_writer_profileLimits() public {
        Writer.Input memory input = _input(26049999, 5);
        input.decimals = 19;
        vm.expectRevert(Writer.DecimalsTooLarge.selector);
        writer.first(input, FIRST_BLOCK, h);
        input = _input(26049999, 17);
        vm.expectRevert(Writer.TooManyAnchors.selector);
        writer.first(input, FIRST_BLOCK, h);
        input = _input(26049999, 5);
        input.decimals = 18; // the token has 6
        vm.expectRevert(Writer.WrongDecimals.selector);
        writer.first(input, FIRST_BLOCK, h);
        input = _input(2 ** 53 + 10, 5);
        vm.expectRevert(Writer.NumberTooLarge.selector);
        writer.first(input, 2 ** 53, h);
        deployCodeTo("Mocks.sol:NoDecimals", ASSET);
        input = _input(26049999, 5);
        vm.expectRevert(Writer.WrongDecimals.selector);
        writer.first(input, FIRST_BLOCK, h);
    }

    function test_writer_valueBound() public {
        _transitions();
        Writer.Output memory o2 = _s2();
        o2.statement.value = 2 ** 127 - 5000; // seq 3 adds 9000
        Writer.Input memory input = _input(LAST, 5);
        vm.expectRevert(Writer.ValueTooLarge.selector);
        writer.next(input, o2.statement, o2.feedbackHash, h);
    }

    /// Fifteen large payments with sixteen anchors asked for: the writer drops the oldest anchors until the file fits
    /// 4 KB (so it never nears the 8,192-byte limit), and the checker accepts the result.
    function test_writer_fileFits4KB_andTheCheckerAcceptsIt() public {
        for (uint32 i; i < 15; ++i) {
            h.addTransfer(ASSET, 26049999, 10 + i, keccak256(abi.encode(i)), OTHER, PAY_TO, 1e37 + i);
        }
        Writer.Output memory o = writer.first(_input(26049999, 16), FIRST_BLOCK, h);
        assertLe(o.file.length, 4096);
        assertEq(o.statement.count, 20);
        assertLt(o.statement.anchors.length, 16);
        assertEq(o.statement.anchors[o.statement.anchors.length - 1].logIndex, 24); // the latest leaf is kept
        Writer.Output[] memory one = new Writer.Output[](1);
        one[0] = o;
        Checker.Result memory r = checker.readChain(_ctx(), _chain(one), true);
        assertEq(uint256(r.status), uint256(Checker.Status.Rebuilt));
    }

    // ------------------------------------------------------------- reading: the whole chain

    function test_read_writerOutputIsAccepted_lightSampled_fullRebuilt() public {
        Checker.Chain memory c = _chain(_outputs(2));
        Checker.Result memory light = checker.readChain(_ctx(), c, false);
        assertEq(uint256(light.status), uint256(Checker.Status.Sampled));
        Checker.Result memory full = checker.readChain(_ctx(), c, true);
        assertEq(uint256(full.status), uint256(Checker.Status.Rebuilt));
        assertEq(full.writer, WRITER);
        assertEq(full.asset, ASSET);
        assertEq(full.value, 1072500);
        // where the chain ends
        assertEq(full.throughBlock, 26099999);
        assertEq(full.throughLog, END_OF_BLOCK);
        assertEq(full.throughTime, h.blockTime(26099999));
    }

    function test_read_transitionsAreAccepted_andIncomeIsTheLatestValue() public {
        _transitions();
        Writer.Output[] memory o = _outputs(6);
        Checker.Result memory light = checker.readChain(_ctx(), _chain(o), false);
        assertEq(uint256(light.status), uint256(Checker.Status.Sampled));
        Checker.Result memory r = checker.readChain(_ctx(), _chain(o), true);
        assertEq(uint256(r.status), uint256(Checker.Status.Rebuilt));
        uint256 sum;
        for (uint256 i; i < o.length; ++i) {
            sum += o[i].statement.value;
        }
        assertEq(r.value, o[5].statement.value); // the latest cumulative value
        assertTrue(r.value != sum && r.value != sum / o.length); // never a sum or an average of the values
        assertEq(r.throughBlock, LAST);
    }

    function test_read_noStatementIsNoData() public view {
        Checker.Chain memory c;
        Checker.Result memory r = checker.readChain(_ctx(), c, true);
        assertEq(uint256(r.status), uint256(Checker.Status.NoData));
    }

    function test_read_lengthsMustMatch() public {
        Checker.Chain memory c = _chain(_outputs(2));
        c.files = new bytes[](1);
        vm.expectRevert(Checker.LengthMismatch.selector);
        checker.readChain(_ctx(), c, false);
    }

    function test_readAll_aFailedWriterFailsAlone() public {
        Checker.Chain[] memory chains = new Checker.Chain[](2);
        chains[0] = _chain(_outputs(2));
        chains[1] = _chain(_outputs(2));
        chains[1].entries[1].revoked = true;
        Checker.Result[] memory r = checker.readAll(_ctx(), chains, true);
        assertEq(uint256(r[0].status), uint256(Checker.Status.Rebuilt));
        assertEq(uint256(r[1].status), uint256(Checker.Status.Failed));
    }

    // ------------------------------------------------------------- reading: entry and file

    function test_entry_valid() public view {
        Writer.Output memory o = _s1();
        checker.checkEntry(_ctx(), _entry(o, 1, 26050000), o.file, o.statement);
    }

    function test_entry_fileTooLarge() public {
        Writer.Output memory o = _s1();
        vm.expectRevert(Checker.FileTooLarge.selector);
        checker.checkEntry(_ctx(), _entry(o, 1, 26050000), new bytes(8193), o.statement);
    }

    function test_entry_tooManyAnchors() public {
        Writer.Output memory o = _s1();
        Anchor[] memory many = new Anchor[](17);
        for (uint256 i; i < many.length; ++i) {
            many[i] = o.statement.anchors[i % 5];
        }
        o.statement.anchors = many;
        vm.expectRevert(Checker.TooManyAnchors.selector);
        checker.checkEntry(_ctx(), _entry(o, 1, 26050000), o.file, o.statement);
    }

    function test_entry_numberPast2pow53() public {
        Writer.Output memory o = _s1();
        o.statement.since = 2 ** 53;
        vm.expectRevert(Checker.NumberTooLarge.selector);
        checker.checkEntry(_ctx(), _entry(o, 1, 26050000), o.file, o.statement);
        o = _s1();
        o.statement.anchors[0].paidAt = 2 ** 53;
        vm.expectRevert(Checker.NumberTooLarge.selector);
        checker.checkEntry(_ctx(), _entry(o, 1, 26050000), o.file, o.statement);
    }

    function test_entry_decimalsAbove18() public {
        Writer.Output memory o = _s1();
        o.statement.decimals = 19;
        vm.expectRevert(Checker.DecimalsTooLarge.selector);
        checker.checkEntry(_ctx(), _entry(o, 1, 26050000), o.file, o.statement);
    }

    function test_entry_valueAboveInt128() public {
        Writer.Output memory o = _s1();
        Checker.Entry memory e = _entry(o, 1, 26050000);
        o.statement.value = 2 ** 127;
        vm.expectRevert(Checker.ValueTooLarge.selector);
        checker.checkEntry(_ctx(), e, o.file, o.statement);
    }

    function test_entry_uriNotExactlyThePrefixAndCanonicalBase64() public {
        Writer.Output memory o = _s1();
        Checker.Entry memory e = _entry(o, 1, 26050000);
        string memory b64 = vm.toBase64(o.file);
        string[3] memory bad = [
            string.concat("data:application/json;charset=utf-8;base64,", b64), // another prefix
            string.concat("data:application/json;base64,", _unpadded(b64)), // no padding
            string.concat("data:application/json;base64,", b64, "\n") // anything after it
        ];
        for (uint256 i; i < bad.length; ++i) {
            e.feedbackURI = bad[i];
            vm.expectRevert(Checker.NotDataURI.selector);
            checker.checkEntry(_ctx(), e, o.file, o.statement);
        }
    }

    function _unpadded(string memory b64) internal pure returns (string memory) {
        bytes memory b = bytes(b64);
        uint256 n = b.length;
        while (n > 0 && b[n - 1] == "=") {
            --n;
        }
        assembly {
            mstore(b, n)
        }
        return string(b);
    }

    function test_entry_feedbackHashIsKeccakOfTheBytes() public {
        Writer.Output memory o = _s1();
        Checker.Entry memory e = _entry(o, 1, 26050000);
        e.feedbackHash = keccak256(bytes(FILE2));
        vm.expectRevert(Checker.HashMismatch.selector);
        checker.checkEntry(_ctx(), e, o.file, o.statement);
    }

    function test_entry_bytesAreTheCanonicalEncoding() public {
        // whitespace, carried consistently in the URI and the hash
        Statement memory s = _s1().statement;
        bytes memory spaced = bytes.concat(" ", Codec.encode(s));
        Checker.Entry memory e = _entry(_s1(), 1, 26050000);
        e.feedbackURI = string(Codec.dataURI(spaced));
        e.feedbackHash = keccak256(spaced);
        vm.expectRevert(Checker.NotCanonical.selector);
        checker.checkEntry(_ctx(), e, spaced, s);
        // a decoded field that is not what the bytes say
        Writer.Output memory o = _s1();
        Checker.Entry memory signed = _entry(o, 1, 26050000);
        o.statement.amount += 1;
        vm.expectRevert(Checker.NotCanonical.selector);
        checker.checkEntry(_ctx(), signed, o.file, o.statement);
    }

    function test_entry_registryIsTheReadersRegistry() public {
        Writer.Output memory o = _s1();
        Checker.Context memory ctx = _ctx();
        ctx.identityRegistry = OTHER;
        vm.expectRevert(Checker.RegistryMismatch.selector);
        checker.checkEntry(ctx, _entry(o, 1, 26050000), o.file, o.statement);
        ctx = _ctx();
        ctx.chainId = 8453;
        vm.expectRevert(Checker.RegistryMismatch.selector);
        checker.checkEntry(ctx, _entry(o, 1, 26050000), o.file, o.statement);
    }

    /// One chain id is written in agentRegistry, clientAddress and asset, so a file whose asset is on another chain is
    /// the canonical encoding of no statement.
    function test_entry_assetIsOnTheRegistrysChain() public {
        Writer.Output memory o = _s1();
        bytes memory other = bytes(vm.replace(string(o.file), "eip155:1/erc20:", "eip155:8453/erc20:"));
        Checker.Entry memory e = _entry(o, 1, 26050000);
        e.feedbackURI = string(Codec.dataURI(other));
        e.feedbackHash = keccak256(other);
        vm.expectRevert(Checker.NotCanonical.selector);
        checker.checkEntry(_ctx(), e, other, o.statement);
    }

    function test_entry_fieldsMatchTheEntry() public {
        Writer.Output memory o = _s1();
        Checker.Entry[6] memory bad;
        for (uint256 i; i < bad.length; ++i) {
            bad[i] = _entry(o, 1, 26050000);
        }
        bad[0].agentId = AGENT + 1;
        bad[1].client = OTHER;
        bad[2].value = bad[2].value + 1;
        bad[3].valueDecimals = 18;
        bad[4].tag1 = "starred";
        bad[5].tag2 = "x402";
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(Checker.EntryMismatch.selector);
            checker.checkEntry(_ctx(), bad[i], o.file, o.statement);
        }
    }

    function test_entry_revokedFails() public {
        Writer.Output memory o = _s1();
        Checker.Entry memory e = _entry(o, 1, 26050000);
        e.revoked = true;
        vm.expectRevert(Checker.Revoked.selector);
        checker.checkEntry(_ctx(), e, o.file, o.statement);
    }

    function test_entry_assetDecimalsAreChecked() public {
        Writer.Output memory o = _s1();
        deployCodeTo("Mocks.sol:MockDecimals", abi.encode(uint8(18)), ASSET);
        vm.expectRevert(Checker.WrongDecimals.selector);
        checker.checkEntry(_ctx(), _entry(o, 1, 26050000), o.file, o.statement);
        deployCodeTo("Mocks.sol:NoDecimals", ASSET);
        vm.expectRevert(Checker.WrongDecimals.selector);
        checker.checkEntry(_ctx(), _entry(o, 1, 26050000), o.file, o.statement);
    }

    // ------------------------------------------------------------- reading: the window

    function test_window_valid_atEveryTransition() public {
        _transitions();
        Writer.Output[] memory o = _outputs(6);
        for (uint256 i; i < o.length; ++i) {
            checker.checkWindow(_ctx(), o[i].statement, LAST + 1);
        }
    }

    function test_window_endsBeforeThePostingBlock() public {
        Statement memory s = _s1().statement;
        vm.expectRevert(Checker.PostedTooEarly.selector);
        checker.checkWindow(_ctx(), s, 26049999); // posted in the window's last block
        checker.checkWindow(_ctx(), s, 26050000);
    }

    function test_window_toTimeIsTheLastBlocksTime() public {
        Statement memory s = _s1().statement;
        s.window.toTime += 1;
        vm.expectRevert(Checker.WrongToTime.selector);
        checker.checkWindow(_ctx(), s, 26050000);
    }

    function test_window_startsAtLog0OrAtTheBlocksLastChangeLog() public {
        _transitions();
        Writer.Output[] memory o = _outputs(6);
        Statement memory s5 = o[4].statement;
        s5.window.fromLog = 6; // the block's first change log, not its last
        vm.expectRevert(Checker.BadWindowStart.selector);
        checker.checkWindow(_ctx(), s5, LAST + 1);
        Statement memory s3 = _outputs(6)[2].statement;
        s3.window.fromLog = 2; // inside a block, at no change log
        vm.expectRevert(Checker.BadWindowStart.selector);
        checker.checkWindow(_ctx(), s3, LAST + 1);
    }

    function test_window_endsAtTheBlocksEndOrJustBeforeAChangeLog() public {
        _transitions();
        Statement memory s3 = _outputs(6)[2].statement;
        s3.window.toLog = 1; // the next log, 2, is no change log
        vm.expectRevert(Checker.BadWindowEnd.selector);
        checker.checkWindow(_ctx(), s3, LAST + 1);
        Statement memory s1 = _s1().statement;
        s1.window.toBlock = FIRST_BLOCK - 1; // before its start
        s1.window.toTime = h.blockTime(FIRST_BLOCK - 1);
        vm.expectRevert(Checker.BadWindowEnd.selector);
        checker.checkWindow(_ctx(), s1, 26050000);
    }

    function test_window_noChangeLogInside() public {
        _transitions();
        Statement memory s3 = _outputs(6)[2].statement;
        s3.window.toLog = END_OF_BLOCK; // through the wallet change at (26100005, 3)
        vm.expectRevert(Checker.ChangeInsideWindow.selector);
        checker.checkWindow(_ctx(), s3, LAST + 1);
    }

    /// The finding a block-granular boundary would leave open: 7000 reached NEW_WALLET at log 2 of the block whose
    /// log 3 made it the agentWallet. No window may count it under NEW_WALLET.
    function test_window_transferBeforeTheWalletChange_neverCountedUnderTheNewWallet() public {
        _transitions();
        Writer.Output[] memory o = _outputs(6);
        for (uint256 i; i < o.length; ++i) {
            for (uint256 j; j < o[i].statement.anchors.length; ++j) {
                assertTrue(o[i].statement.anchors[j].txHash != bytes32(uint256(0xb2)));
            }
        }
        // the new wallet's window started at the start of that block instead: rejected
        Statement memory s4 = o[3].statement;
        s4.window.fromLog = 0;
        vm.expectRevert(Checker.ChangeInsideWindow.selector);
        checker.checkWindow(_ctx(), s4, LAST + 1);
    }

    function test_window_agentMustExist() public {
        Statement memory s = _s1().statement;
        s.window.fromBlock = 25980000;
        s.window.toBlock = 25980010;
        s.window.toTime = h.blockTime(25980010);
        vm.expectRevert(Checker.NoOwner.selector);
        checker.checkWindow(_ctx(), s, 26050000);
    }

    function test_window_ownerAndPayToAreTheRegistrys() public {
        Statement memory s = _s1().statement;
        s.owner = OTHER;
        vm.expectRevert(Checker.OwnerMismatch.selector);
        checker.checkWindow(_ctx(), s, 26050000);
        s = _s1().statement;
        s.payTo = OTHER;
        vm.expectRevert(Checker.PayToMismatch.selector);
        checker.checkWindow(_ctx(), s, 26050000);
    }

    function test_window_ownerAndPayToAtTheChangeLogThatStartsIt() public {
        _transitions();
        Writer.Output[] memory o = _outputs(6);
        Statement memory s4 = o[3].statement; // starts at the wallet change: the state at the end of that block
        s4.payTo = PAY_TO;
        vm.expectRevert(Checker.PayToMismatch.selector);
        checker.checkWindow(_ctx(), s4, LAST + 1);
        Statement memory s3 = _outputs(6)[2].statement; // starts at log 0: the state at the end of the block before
        s3.payTo = NEW_WALLET;
        vm.expectRevert(Checker.PayToMismatch.selector);
        checker.checkWindow(_ctx(), s3, LAST + 1);
    }

    /// A window that starts at log 0 of a block whose later log changes the wallet ends before that change, and takes
    /// the wallet in force at its start: the registry's state at the end of the block before, not of its own block.
    function test_window_startingAtLog0OfABlockWithALaterChange_usesTheBlockBefore() public {
        _transitions();
        Writer.Input memory input = _input(26100005, 5);
        Writer.Output memory o = writer.first(input, 26100005, h);
        Statement memory s = o.statement;
        assertEq(s.window.fromLog, 0);
        assertEq(s.window.toBlock, 26100005);
        assertEq(s.window.toLog, 2);
        assertEq(s.payTo, PAY_TO);
        assertEq(s.amount, 9000); // P3's 9000 at log 1; not P1's 7000 to NEW_WALLET at log 2
        checker.checkWindow(_ctx(), s, 26100006);
        s.payTo = NEW_WALLET;
        vm.expectRevert(Checker.PayToMismatch.selector);
        checker.checkWindow(_ctx(), s, 26100006);
    }

    /// A registry outside this profile unsets the wallet at (26030000, 5) without MetadataSet: no change log cuts the
    /// window, but the wallet at its end differs from the one at its start.
    function test_window_walletChangedWithoutLog_failsTheWindow() public {
        Statement memory s = _s1().statement; // written before the change
        h.setWalletWithoutLog(26030000, 5, address(0));
        vm.expectRevert(Checker.StateChangedInWindow.selector);
        checker.checkWindow(_ctx(), s, 26050000);
    }

    function test_writer_refusesAWalletChangedWithoutLog() public {
        h.setWalletWithoutLog(26030000, 5, address(0));
        Writer.Input memory input = _input(26049999, 5);
        vm.expectRevert(Writer.ChangeWithoutLog.selector);
        writer.first(input, FIRST_BLOCK, h);
    }

    /// What remains: a change made and undone inside one window, both without logs, is not seen (the profile applies
    /// only to registries that emit MetadataSet for every wallet change).
    function test_window_changeUndoneInsideTheWindowWithoutLogs_isNotSeen() public {
        Statement memory s = _s1().statement;
        h.setWalletWithoutLog(26030000, 5, address(0));
        h.setWalletWithoutLog(26040000, 0, PAY_TO);
        checker.checkWindow(_ctx(), s, 26050000);
    }

    function test_window_noPayToNoPayment() public {
        _transitions();
        Statement memory s5 = _outputs(6)[4].statement;
        s5.count = 1;
        vm.expectRevert(Checker.PaymentsWithoutPayTo.selector);
        checker.checkWindow(_ctx(), s5, LAST + 1);
    }

    function test_window_rootIsZeroExactlyWithNoPayment() public {
        Statement memory s1 = _s1().statement;
        s1.root = bytes32(0);
        vm.expectRevert(Checker.RootCountMismatch.selector);
        checker.checkWindow(_ctx(), s1, 26050000);
        Statement memory s2 = _s2().statement;
        s2.root = ROOT;
        vm.expectRevert(Checker.RootCountMismatch.selector);
        checker.checkWindow(_ctx(), s2, 26100000);
    }

    // ------------------------------------------------------------- reading: anchors (light) and rebuild (full)

    function test_anchors_valid() public view {
        checker.checkAnchors(_ctx(), _s1().statement);
    }

    function test_anchors_eachIsAPaymentInTheLogs() public {
        Statement[7] memory bad;
        for (uint256 i; i < bad.length; ++i) {
            bad[i] = _s1().statement;
        }
        bad[0].anchors[2].amount += 1; // an inflated amount
        bad[1].anchors[2].payer = P3; // another payer
        bad[2].anchors[2].txHash = bytes32(uint256(0xa9)); // another transaction
        bad[3].anchors[2].paidAt += 1; // another time
        (bad[4].anchors[0], bad[4].anchors[1]) = (bad[4].anchors[1], bad[4].anchors[0]); // out of leaf order
        bad[5].count = 4; // more anchors than payments
        bad[6].window.toBlock = 26049998; // the last anchor outside the window
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(Checker.BadAnchor.selector);
            checker.checkAnchors(_ctx(), bad[i]);
        }
        // the owner's own transfer, or a log that does not exist, is not a payment
        Statement memory s = _s1().statement;
        s.anchors = new Anchor[](1);
        s.anchors[0] = Anchor(OWNER, 500000, h.blockTime(26000500), 26000500, bytes32(uint256(0xa6)), 2);
        vm.expectRevert(Checker.BadAnchor.selector);
        checker.checkAnchors(_ctx(), s);
        s.anchors[0] = Anchor(P1, 10000, h.blockTime(26000011), 26000011, bytes32(uint256(0xa1)), 3);
        vm.expectRevert(Checker.BadAnchor.selector);
        checker.checkAnchors(_ctx(), s);
    }

    function test_rebuild_valid() public view {
        checker.rebuild(_ctx(), _s1().statement);
        checker.rebuild(_ctx(), _s2().statement);
    }

    /// A statement that leaves out one payment passes every light check and fails the rebuild.
    function test_rebuild_droppedPayment_passesLight_failsFull() public {
        uint256[] memory keep = new uint256[](4);
        (keep[0], keep[1], keep[2], keep[3]) = (0, 2, 3, 4); // P2's 2500 left out
        Statement memory s = _s1With(keep);
        s.payers = 3;
        (Checker.Entry memory e, bytes memory file) = _signed(s);
        checker.checkEntry(_ctx(), e, file, s);
        checker.checkWindow(_ctx(), s, 26050000);
        checker.checkAnchors(_ctx(), s);
        checker.checkFirst(_ctx(), s);
        vm.expectRevert(Checker.RebuildMismatch.selector);
        checker.rebuild(_ctx(), s);
    }

    /// A writer that counted the owner's 500000 top-up: six leaves and a root over them, with anchors that pass every
    /// light check. The verifier will not prove the top-up against that root, though it proves the five payments, and
    /// a full read rejects the statement.
    function test_rebuild_ownerTopUpInTheRoot_refusedByTheVerifierAndTheFullCheck() public {
        Statement memory s = _s1().statement;
        Anchor memory topUp = Anchor(OWNER, 500000, h.blockTime(26000500), 26000500, bytes32(uint256(0xa6)), 2);
        Anchor[] memory leaves = new Anchor[](6);
        (leaves[0], leaves[1], leaves[2]) = (s.anchors[0], s.anchors[1], topUp);
        (leaves[3], leaves[4], leaves[5]) = (s.anchors[2], s.anchors[3], s.anchors[4]);
        bytes32[] memory hashes = new bytes32[](leaves.length);
        for (uint256 i; i < leaves.length; ++i) {
            hashes[i] = _leaf(s, leaves[i]);
        }
        s.root = _root(hashes);
        s.count = 6;
        s.amount += 500000;
        s.value = s.amount;
        s.payers = 5; // the owner among them
        Anchor[] memory latest = new Anchor[](2);
        (latest[0], latest[1]) = (leaves[4], leaves[5]);
        s.anchors = latest;

        IncomeStatementVerifier v = new IncomeStatementVerifier();
        assertFalse(v.verifyPayment(s.root, _proofOf(hashes, 2), _paymentFrom(s, topUp)));
        for (uint256 i; i < leaves.length; ++i) {
            if (i != 2) assertTrue(v.verifyPayment(s.root, _proofOf(hashes, i), _paymentFrom(s, leaves[i])));
        }

        Writer.Output[] memory o = new Writer.Output[](1);
        o[0].statement = s;
        o[0].file = Codec.encode(s);
        o[0].feedbackURI = string(Codec.dataURI(o[0].file));
        o[0].feedbackHash = keccak256(o[0].file);
        Checker.Chain memory c = _chain(o);
        assertEq(uint256(checker.readChain(_ctx(), c, false).status), uint256(Checker.Status.Sampled));
        vm.expectRevert(Checker.RebuildMismatch.selector);
        checker.readChain(_ctx(), c, true);
    }

    function test_rebuild_totalsRootAndAnchorsAreRecomputed() public {
        Statement[4] memory bad;
        for (uint256 i; i < bad.length; ++i) {
            bad[i] = _s1().statement;
        }
        bad[0].payers = 5;
        bad[1].amount += 1;
        bad[2].root = keccak256("another tree");
        bad[3].count = 6;
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(Checker.RebuildMismatch.selector);
            checker.rebuild(_ctx(), bad[i]);
        }
        // anchors that are real payments but not the latest leaves
        Statement memory s = _s1().statement;
        Anchor[] memory older = new Anchor[](4);
        for (uint256 i; i < older.length; ++i) {
            older[i] = s.anchors[i];
        }
        s.anchors = older;
        checker.checkAnchors(_ctx(), s);
        vm.expectRevert(Checker.RebuildMismatch.selector);
        checker.rebuild(_ctx(), s);
    }

    // ------------------------------------------------------------- reading: the chain

    function test_entries_everyIndexFrom1ToLastIndex_onceEach() public {
        Checker.Chain memory c = _chain(_outputs(2));
        checker.checkEntries(_ctx(), c);
        h.setLastIndex(WRITER, 3); // the registry has a third entry the chain leaves out
        vm.expectRevert(Checker.IndexGap.selector);
        checker.checkEntries(_ctx(), c);
        h.setLastIndex(WRITER, 2);
        c.entries[1].feedbackIndex = 3; // index 2 left out, 3 put in its place
        vm.expectRevert(Checker.IndexGap.selector);
        checker.checkEntries(_ctx(), c);
        c.entries[1].feedbackIndex = 1; // index 1 twice
        vm.expectRevert(Checker.IndexGap.selector);
        checker.checkEntries(_ctx(), c);
        c.entries[1].feedbackIndex = 2;
        c.entries[1].client = OTHER; // another writer's entry in this writer's chain
        vm.expectRevert(Checker.EntryMismatch.selector);
        checker.checkEntries(_ctx(), c);
    }

    /// A second seq 1 posted at index 2: the chain must carry every index, so it is either left out (a gap) or read
    /// (a repeated seq). Either way the writer fails.
    function test_read_duplicateSeq1HiddenAtIndex2_fails() public {
        Writer.Output[] memory o = _outputs(2);
        Writer.Output memory again = _s1(); // the same seq 1 posted twice
        Checker.Chain memory withIt = _insert(_chain(o), 1, _entry(again, 2, LAST + 1), again.file, again.statement);
        vm.expectRevert(Checker.SeqGap.selector);
        checker.readChain(_ctx(), withIt, true);
        Checker.Chain memory without = _chain(o); // indexes 1 and 3 only, against a last index of 3
        without.entries[1].feedbackIndex = 3;
        h.setLastIndex(WRITER, 3);
        vm.expectRevert(Checker.IndexGap.selector);
        checker.readChain(_ctx(), without, true);
    }

    function test_read_nonStatementEntryInBetween_isAccepted() public {
        Writer.Output[] memory o = _outputs(2);
        Statement memory none;
        Checker.Chain memory c = _insert(_chain(o), 1, _rating(2), "", none);
        assertEq(c.entries[2].feedbackIndex, 3);
        Checker.Result memory r = checker.readChain(_ctx(), c, true);
        assertEq(uint256(r.status), uint256(Checker.Status.Rebuilt));
        assertEq(r.value, 1072500);
    }

    function test_read_malformedStatementAnywhere_fails() public {
        Writer.Output[] memory o = _outputs(2);
        Writer.Output memory bad = _s2();
        Checker.Entry memory e = _entry(bad, 2, LAST + 1);
        e.feedbackURI = "data:application/json;base64,e30="; // "{}": not this statement
        Checker.Chain memory c = _insert(_chain(o), 1, e, bad.file, bad.statement);
        vm.expectRevert(Checker.NotDataURI.selector);
        checker.readChain(_ctx(), c, false);
    }

    function test_first_valid() public view {
        checker.checkFirst(_ctx(), _s1().statement);
    }

    function test_first_seqPrevStartAndValue() public {
        Statement[5] memory bad;
        for (uint256 i; i < bad.length; ++i) {
            bad[i] = _s1().statement;
        }
        bad[0].seq = 2;
        bad[1].prev = FILE2_HASH;
        bad[2].since = FIRST_BLOCK - 1;
        bad[3].window.fromLog = 3;
        bad[4].value += 1;
        bytes4[5] memory errs = [
            Checker.SeqGap.selector,
            Checker.PrevMismatch.selector,
            Checker.NotBackToBack.selector,
            Checker.NotBackToBack.selector,
            Checker.ValueNotCumulative.selector
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(errs[i]);
            checker.checkFirst(_ctx(), bad[i]);
        }
    }

    function test_link_valid() public view {
        Writer.Output memory o1 = _s1();
        checker.checkLink(_ctx(), o1.statement, o1.feedbackHash, _s2().statement);
    }

    function test_link_seqPrevAndValue() public {
        Writer.Output memory o1 = _s1();
        Statement[4] memory bad;
        for (uint256 i; i < bad.length; ++i) {
            bad[i] = _s2().statement;
        }
        bad[0].seq = 3; // a gap
        bad[1].seq = 1; // a second statement with the same seq
        bad[2].prev = keccak256("another statement");
        bad[3].value += 1;
        bytes4[4] memory errs = [
            Checker.SeqGap.selector,
            Checker.SeqGap.selector,
            Checker.PrevMismatch.selector,
            Checker.ValueNotCumulative.selector
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(errs[i]);
            checker.checkLink(_ctx(), o1.statement, o1.feedbackHash, bad[i]);
        }
    }

    function test_link_assetDecimalsSinceAndWriterDoNotChange() public {
        Writer.Output memory o1 = _s1();
        Statement[5] memory bad;
        for (uint256 i; i < bad.length; ++i) {
            bad[i] = _s2().statement;
        }
        bad[0].asset = OTHER;
        bad[1].decimals = 18;
        bad[2].since = FIRST_BLOCK + 1;
        bad[3].writer = OTHER;
        bad[4].agentId = AGENT + 1;
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(Checker.ConstantChanged.selector);
            checker.checkLink(_ctx(), o1.statement, o1.feedbackHash, bad[i]);
        }
    }

    function test_link_windowsBackToBack() public {
        Writer.Output memory o1 = _s1();
        Statement memory gap = _s2().statement;
        gap.window.fromBlock += 1;
        vm.expectRevert(Checker.NotBackToBack.selector);
        checker.checkLink(_ctx(), o1.statement, o1.feedbackHash, gap);
        Statement memory overlap = _s2().statement;
        overlap.window.fromBlock -= 1;
        vm.expectRevert(Checker.NotBackToBack.selector);
        checker.checkLink(_ctx(), o1.statement, o1.feedbackHash, overlap);
        // after a window cut before a block's first change log, the next starts at that block's last one
        _transitions();
        Writer.Output[] memory o = _outputs(6);
        Statement memory s5 = _outputs(6)[4].statement; // a fresh copy: memory structs alias
        s5.window.fromLog = 6;
        vm.expectRevert(Checker.NotBackToBack.selector);
        checker.checkLink(_ctx(), o[3].statement, o[3].feedbackHash, s5);
        checker.checkLink(_ctx(), o[3].statement, o[3].feedbackHash, o[4].statement);
    }

    // ------------------------------------------------------------- reading: income

    function _result(Checker.Status status, address writer_, address asset, uint256 value, uint64 through)
        internal
        pure
        returns (Checker.Result memory)
    {
        return Checker.Result(status, writer_, asset, value, through, END_OF_BLOCK, 0);
    }

    function _counted(address a) internal pure returns (address[] memory l) {
        l = new address[](1);
        l[0] = a;
    }

    function test_income_neverAddedAcrossWriters() public view {
        Checker.Result[] memory r = new Checker.Result[](2);
        r[0] = _result(Checker.Status.Rebuilt, WRITER, ASSET, 1072500, 26099999);
        r[1] = _result(Checker.Status.Rebuilt, OTHER, ASSET, 1072500, 26099999);
        Checker.Result memory i = checker.income(r, ASSET, _counted(ASSET));
        assertEq(i.value, 1072500); // the same transfers: one chain's value, not 2145000
    }

    function test_income_oneChainNeverAnAverage_rebuiltBeforeSampled_thenFurthest() public view {
        Checker.Result[] memory r = new Checker.Result[](3);
        r[0] = _result(Checker.Status.Sampled, OTHER, ASSET, 9000000, 26300000);
        r[1] = _result(Checker.Status.Rebuilt, WRITER, ASSET, 1072500, 26099999);
        r[2] = _result(Checker.Status.Rebuilt, P1, ASSET, 1081500, 26100005);
        Checker.Result memory i = checker.income(r, ASSET, _counted(ASSET));
        assertEq(uint256(i.status), uint256(Checker.Status.Rebuilt));
        assertEq(i.writer, P1);
        assertEq(i.value, 1081500);
        assertEq(i.throughBlock, 26100005); // where the figure stops
    }

    function test_income_unrebuiltIsNotReportedAsChecked() public view {
        Checker.Result[] memory r = new Checker.Result[](1);
        r[0] = _result(Checker.Status.Sampled, WRITER, ASSET, 1072500, 26099999);
        Checker.Result memory i = checker.income(r, ASSET, _counted(ASSET));
        assertEq(uint256(i.status), uint256(Checker.Status.Sampled));
    }

    function test_income_neverAcrossAssets_andOnlyCountedAssets() public view {
        Checker.Result[] memory r = new Checker.Result[](2);
        r[0] = _result(Checker.Status.Rebuilt, WRITER, ASSET, 1072500, 26099999);
        r[1] = _result(Checker.Status.Rebuilt, WRITER, OTHER, 5e18, 26099999);
        address[] memory both = new address[](2);
        (both[0], both[1]) = (ASSET, OTHER);
        assertEq(checker.income(r, ASSET, both).value, 1072500);
        Checker.Result memory notCounted = checker.income(r, OTHER, _counted(ASSET));
        assertEq(uint256(notCounted.status), uint256(Checker.Status.AssetNotCounted));
        assertEq(notCounted.value, 0);
    }

    function test_income_noStatementIsNoData_notZeroIncome() public view {
        Checker.Result[] memory r = new Checker.Result[](1);
        r[0] = _result(Checker.Status.Failed, WRITER, ASSET, 999, 26099999); // a failed writer counts for nothing
        Checker.Result memory i = checker.income(r, ASSET, _counted(ASSET));
        assertEq(uint256(i.status), uint256(Checker.Status.NoData));
        i = checker.income(new Checker.Result[](0), ASSET, _counted(ASSET));
        assertEq(uint256(i.status), uint256(Checker.Status.NoData));
    }

    // ------------------------------------------------------------- reading: the writer the agent names

    function _name(uint64 b, bytes memory value) internal {
        h.setMetadata(b, "incomeWriter", value);
    }

    function test_namedWriter_isTheKeysAddress_fromTheBlockItIsSet() public {
        assertEq(checker.namedWriter(_ctx(), AGENT, LAST), address(0)); // unset
        _name(26000001, abi.encode(WRITER));
        assertEq(checker.namedWriter(_ctx(), AGENT, 26000000), address(0));
        assertEq(checker.namedWriter(_ctx(), AGENT, 26000001), WRITER);
        _name(26150001, abi.encode(P1)); // changed mid-way
        assertEq(checker.namedWriter(_ctx(), AGENT, 26150000), WRITER);
        assertEq(checker.namedWriter(_ctx(), AGENT, LAST), P1);
        assertEq(checker.namedWriter(_ctx(), AGENT + 1, LAST), address(0)); // another agent's key
    }

    function test_namedWriter_unsetWhenNotAnAddressOrTheOwner() public {
        bytes[5] memory bad = [
            bytes(""),
            abi.encodePacked(WRITER), // 20 bytes, not abi.encode
            abi.encode((uint256(1) << 160) | uint160(WRITER)), // past 160 bits
            abi.encode(address(0)),
            abi.encode(OWNER) // the registry refuses the owner as a client: it has no chain
        ];
        for (uint64 i; i < bad.length; ++i) {
            _name(26000001 + i, bad[i]);
            assertEq(checker.namedWriter(_ctx(), AGENT, 26000001 + i), address(0));
        }
        // an address that later becomes the owner names no chain from then on
        _transitions();
        _name(26100000, abi.encode(NEW_OWNER));
        assertEq(checker.namedWriter(_ctx(), AGENT, 26100000), NEW_OWNER);
        assertEq(checker.namedWriter(_ctx(), AGENT, LAST), address(0));
    }

    /// With the key set, the agent's income is the named writer's chain's value: a planted chain, rebuilt and reaching
    /// further, is skipped. Unset, the reader picks among the chains it read. Changed, it is the new writer's chain.
    function test_income_followsTheNamedWriter() public {
        Checker.Result[] memory r = new Checker.Result[](3);
        r[0] = _result(Checker.Status.Rebuilt, WRITER, ASSET, 1072500, 26099999);
        r[1] = _result(Checker.Status.Sampled, P1, ASSET, 1081500, 26100005);
        r[2] = _result(Checker.Status.Rebuilt, OTHER, ASSET, 9000000, 26300000); // planted, and further
        address[] memory counted = _counted(ASSET);

        Checker.Result memory i = checker.income(r, ASSET, counted, checker.namedWriter(_ctx(), AGENT, LAST));
        assertEq(i.writer, OTHER); // unset: the reader's own pick among what it read

        _name(26000001, abi.encode(WRITER));
        i = checker.income(r, ASSET, counted, checker.namedWriter(_ctx(), AGENT, LAST));
        assertEq(i.writer, WRITER);
        assertEq(i.value, 1072500);

        _name(26150001, abi.encode(P1)); // the owner names another writer
        i = checker.income(r, ASSET, counted, checker.namedWriter(_ctx(), AGENT, LAST));
        assertEq(i.writer, P1);
        assertEq(uint256(i.status), uint256(Checker.Status.Sampled)); // not checked, though named

        _name(26160001, abi.encode(address(0x5e7))); // a writer with no chain among these
        i = checker.income(r, ASSET, counted, checker.namedWriter(_ctx(), AGENT, LAST));
        assertEq(uint256(i.status), uint256(Checker.Status.NoData)); // the planted chain is still skipped
    }

    // ------------------------------------------------------------- the codec, against independent encoders

    function testFuzz_codec_base64(bytes memory data) public pure {
        assertEq(string(Codec.base64(data)), vm.toBase64(data));
    }

    function testFuzz_codec_checksum(address a) public pure {
        assertEq(string(Codec.checksum(a)), vm.toString(a));
    }

    function testFuzz_codec_decimal(uint256 v) public pure {
        assertEq(string(Codec.decimal(v)), vm.toString(v));
    }

    function test_codec_isoTime() public pure {
        assertEq(string(Codec.isoTime(0)), "1970-01-01T00:00:00Z");
        assertEq(string(Codec.isoTime(68169599)), "1972-02-28T23:59:59Z");
        assertEq(string(Codec.isoTime(951782400)), "2000-02-29T00:00:00Z");
        assertEq(string(Codec.isoTime(1709208000)), "2024-02-29T12:00:00Z");
        assertEq(string(Codec.isoTime(1790603588)), "2026-09-28T13:53:08Z");
        assertEq(string(Codec.isoTime(4102444799)), "2099-12-31T23:59:59Z");
    }

    function testFuzz_codec_leafHashIsTheVerifiers(IIncomeStatementVerifier.Payment memory p) public {
        IncomeStatementVerifier v = new IncomeStatementVerifier();
        assertEq(
            Codec.leafHash(
                p.chainId, p.asset, p.agentId, p.owner, p.payer, p.payTo, p.amount, p.paidAt, p.txHash, p.logIndex
            ),
            v.leafHash(p)
        );
    }
}

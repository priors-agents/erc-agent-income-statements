// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IIncomeStatementVerifier} from "../src/IIncomeStatementVerifier.sol";
import {IncomeStatementVerifier} from "../src/IncomeStatementVerifier.sol";
import {IncomeStatementCodec as Codec} from "../src/IncomeStatementCodec.sol";
import {IncomeStatementWriter} from "../src/IncomeStatementWriter.sol";
import {END_OF_BLOCK} from "../src/IncomeStatementTypes.sol";
import {MockChainHistory, MockDecimals} from "./mocks/Mocks.sol";

/// The real-chain vector of the ERC text ("Test Cases", "A payment on chain"): an x402 payment to ERC-8004 agent 8811 on
/// Robinhood Chain, settled with ERC-3009's transferWithAuthorization, whose owner and agentWallet are one address.
/// Every value below was read from the chain (chain id 4663) and the leaf hash computed with `cast abi-encode` and
/// `cast keccak`, independently of the reference code.
contract RealChainVectorTest is Test {
    event PaymentProven(uint256 indexed agentId, bytes32 indexed root, bytes32 txHash, uint32 logIndex);

    uint256 constant CHAIN_ID = 4663;
    address constant REGISTRY = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
    uint256 constant AGENT = 8811;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant OWNER = 0xF5858D7Ea59b4fB176925Df77D332a43e786Bb65; // also its agentWallet, the statement's payTo
    address constant PAYER = 0x33d6112f2F3BCD2a476bD9C13208E4C632bE2d0a;
    bytes32 constant TX = 0x1921a861077692f32b64812f811c7afc3c400822d11fb7ae4883a1ade48ea601;
    uint64 constant BLOCK = 94630540;
    uint64 constant TIME = 1792621780; // block 94630540's timestamp
    uint32 constant LOG = 2; // AuthorizationUsed is log 1; log 0 belongs to another transaction of the block

    /// keccak256(bytes.concat(keccak256(abi.encode(4663, USDG, 8811, OWNER, PAYER, OWNER, 1000000, TIME, TX, 2)))) by cast
    bytes32 constant LEAF = 0xf87837f67578cc0593869d5409d2310e50e12de8c3da89b92a5e6cd45805b12f;

    IncomeStatementVerifier verifier;

    function setUp() public {
        verifier = new IncomeStatementVerifier();
    }

    function _payment() internal pure returns (IIncomeStatementVerifier.Payment memory) {
        return IIncomeStatementVerifier.Payment({
            chainId: CHAIN_ID,
            asset: USDG,
            agentId: AGENT,
            owner: OWNER,
            payer: PAYER,
            payTo: OWNER,
            amount: 1000000,
            paidAt: TIME,
            txHash: TX,
            logIndex: LOG
        });
    }

    /// Agent 8811's recorded chain: its mint at (89385625, 1) and its agentWallet set to its owner at (89385625, 4), no
    /// change log since, and every USDG Transfer into that address through block 95400812, as the chain returns them.
    function _chain() internal returns (MockChainHistory h) {
        h = new MockChainHistory(REGISTRY, AGENT, BLOCK, TIME);
        h.setOwner(89385625, 1, OWNER);
        h.setWallet(89385625, 4, OWNER);
        _in(
            h,
            89378384,
            2,
            0xe75c96886834149d0368178c2135cc987076b8c2d94638128c8c0fb7d7ffc386,
            0x0552337817d59C06637E3171C0eeCbf8a0822ce3,
            5000000
        );
        _in(
            h,
            89386907,
            11,
            0xc3fcc071fb377a33da84e670fa8368a5f5aebcbd79b3fded3d8ce39185a02ddb,
            0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca,
            50247
        );
        _in(
            h,
            89399022,
            42,
            0x3251e8ceaf6055f3e9c05f83e7554bef40b702601bcb2f4a82bea7d1c75993c2,
            0x281210097f0de7A8FB6F87310AF0f089c9C8DE21,
            5000000
        );
        _in(
            h,
            89450420,
            10,
            0x001c790dcbe417908954786c1b3992a588b0ee8e3702089d0c4e01febca9f54b,
            0x8366a39CC670B4001A1121B8F6A443A643e40951,
            4050413
        );
        _in(
            h,
            90146054,
            0,
            0xaf60c4ed197e00aee5c3e04201e951b3452c44f9415735f71c55c5b6b7d72351,
            0xf70da97812CB96acDF810712Aa562db8dfA3dbEF,
            15927041
        );
        _in(
            h,
            90567381,
            11,
            0x8cd3758d903640baef1e27ab63feae158bebe2a238463f68cd77f29dd48259b9,
            0x0AC94bc35c6CfBA9dEcde9451D354442F47b2e3A,
            10000
        );
        _in(
            h,
            90567666,
            4,
            0x275849d709a42c228143efede59461f07775d91c83dc442e914c9d20e6d8f782,
            0x0AC94bc35c6CfBA9dEcde9451D354442F47b2e3A,
            10000
        );
        _in(
            h,
            91062841,
            4,
            0x79bffb4f17e31759ea99823f480e42b584ac24069bf290e0b8ca10ed8815943a,
            0x0AC94bc35c6CfBA9dEcde9451D354442F47b2e3A,
            10000
        );
        _in(h, 91905615, 36, 0x40ccb26debacf2e71e295df2490986d10d984be27d6e8175c0db350825459c8b, PAYER, 2000000);
        _in(h, BLOCK, LOG, TX, PAYER, 1000000);
        _in(
            h,
            94883929,
            3,
            0x2cbec220f454d1cf030dc3584f49d075ea37bde11fcc82aac8f5ad6a83ad0fb4,
            0x8366a39CC670B4001A1121B8F6A443A643e40951,
            2272647
        );
        _in(
            h,
            95400812,
            5,
            0x6dfa2cc966161e19aacc9c5c22f8d926209b0d63cbb9905cbc064713762b4d93,
            0x281210097f0de7A8FB6F87310AF0f089c9C8DE21,
            5000000
        );
        vm.etch(USDG, address(new MockDecimals(6)).code); // USDG's decimals() is 6
    }

    function _in(MockChainHistory h, uint64 b, uint32 l, bytes32 txHash, address from, uint256 value) internal {
        h.addTransfer(USDG, b, l, txHash, from, OWNER, value);
    }

    function _input(uint64 lastBlock) internal pure returns (IncomeStatementWriter.Input memory) {
        return IncomeStatementWriter.Input({
            chainId: CHAIN_ID,
            identityRegistry: REGISTRY,
            agentId: AGENT,
            writer: 0x00000000000000000000000000000000000000C1,
            asset: USDG,
            decimals: 6,
            lastBlock: lastBlock,
            createdAt: TIME + 3600,
            anchors: 5
        });
    }

    function test_realChain_leafHash_isTheVector() public view {
        IIncomeStatementVerifier.Payment memory p = _payment();
        assertEq(verifier.leafHash(p), LEAF);
        assertEq(
            Codec.leafHash(p.chainId, p.asset, p.agentId, p.owner, p.payer, p.payTo, p.amount, p.paidAt, p.txHash, LOG),
            LEAF
        );
    }

    /// Owner and payTo are one address and the payer is neither: a payment. Alone in its window, its leaf hash is the
    /// root, and an empty proof verifies it.
    function test_realChain_verifyPayment_aloneInItsWindow() public {
        vm.expectEmit(true, true, false, true, address(verifier));
        emit PaymentProven(AGENT, LEAF, TX, LOG);
        assertTrue(verifier.verifyPayment(LEAF, new bytes32[](0), _payment()));
    }

    /// The same transfer claimed as the owner's, which here is also payTo's: refused, with no event.
    function test_realChain_verifyPayment_asTheOwners_fails() public {
        IIncomeStatementVerifier.Payment memory p = _payment();
        p.payer = OWNER;
        bytes32 root = verifier.leafHash(p);
        vm.recordLogs();
        assertFalse(verifier.verifyPayment(root, new bytes32[](0), p));
        assertEq(vm.getRecordedLogs().length, 0);
    }

    /// The reference writer, over block 94630540 of the recorded chain, writes a statement whose only leaf is this
    /// payment: the window starts at log 0 (no change log in the block), owner and payTo are the registration's.
    function test_realChain_writerRebuildsTheWindow() public {
        MockChainHistory h = _chain();
        IncomeStatementWriter writer = new IncomeStatementWriter();
        IncomeStatementWriter.Output memory out = writer.first(_input(BLOCK), BLOCK, h);

        assertEq(out.statement.window.fromBlock, BLOCK);
        assertEq(out.statement.window.fromLog, 0);
        assertEq(out.statement.window.toBlock, BLOCK);
        assertEq(out.statement.window.toLog, END_OF_BLOCK);
        assertEq(out.statement.window.toTime, TIME);
        assertEq(out.statement.owner, OWNER);
        assertEq(out.statement.payTo, OWNER);
        assertEq(out.statement.count, 1);
        assertEq(out.statement.amount, 1000000);
        assertEq(out.statement.payers, 1);
        assertEq(out.statement.value, 1000000);
        assertEq(out.statement.root, LEAF);
        assertEq(out.statement.anchors.length, 1);
        assertEq(out.statement.anchors[0].payer, PAYER);
        assertEq(out.statement.anchors[0].txHash, TX);
        assertEq(out.statement.anchors[0].logIndex, LOG);
        assertEq(out.statement.anchors[0].paidAt, TIME);
        assertTrue(verifier.verifyPayment(out.statement.root, new bytes32[](0), _payment()));
    }

    /// The 5.00 USDG sent in block 89378384, before the agent was minted in block 89385625, is in no statement: a
    /// window there has no owner.
    function test_realChain_transferBeforeRegistration_isInNoWindow() public {
        MockChainHistory h = _chain();
        IncomeStatementWriter writer = new IncomeStatementWriter();
        vm.expectRevert(IncomeStatementWriter.NoOwner.selector);
        writer.first(_input(89378384), 89378384, h);
    }
}

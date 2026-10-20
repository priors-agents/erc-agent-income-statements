// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Test.sol";
import {Vectors} from "./Vectors.sol";
import {IIncomeStatementVerifier} from "../src/IIncomeStatementVerifier.sol";
import {IncomeStatementVerifier} from "../src/IncomeStatementVerifier.sol";

/// The verifier against the test vectors of the ERC text.
contract IncomeStatementVerifierTest is Vectors {
    event PaymentProven(uint256 indexed agentId, bytes32 indexed root, bytes32 txHash, uint32 logIndex);

    IncomeStatementVerifier verifier;

    function setUp() public {
        verifier = new IncomeStatementVerifier();
    }

    function _verify(bytes32 root, bytes32[] memory proof, IIncomeStatementVerifier.Payment memory p)
        internal
        returns (bool)
    {
        return verifier.verifyPayment(root, proof, p);
    }

    // ------------------------------------------------------------- interface

    function test_supportsInterface() public view {
        assertTrue(verifier.supportsInterface(type(IIncomeStatementVerifier).interfaceId));
        assertEq(type(IIncomeStatementVerifier).interfaceId, bytes4(0xfc162870)); // as the ERC text states it
        assertTrue(verifier.supportsInterface(0x01ffc9a7));
        assertFalse(verifier.supportsInterface(0xffffffff));
        assertEq(
            type(IIncomeStatementVerifier).interfaceId,
            bytes4(IIncomeStatementVerifier.leafHash.selector ^ IIncomeStatementVerifier.verifyPayment.selector)
        );
    }

    // ------------------------------------------------------------- leaves and root

    function test_leafHash_matchesTheVectors() public view {
        IIncomeStatementVerifier.Payment[] memory p = _payments();
        bytes32[] memory h = _leafHashes();
        assertEq(p.length, h.length);
        for (uint256 i; i < p.length; ++i) {
            assertEq(verifier.leafHash(p[i]), h[i]);
        }
    }

    function test_leafHash_isTheDoubleHashOfTheNineFields() public view {
        IIncomeStatementVerifier.Payment memory p = _payments()[2];
        bytes32 expected = keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(
                        uint256(1),
                        ASSET,
                        uint256(9007199254740993),
                        address(0x00000000000000000000000000000000000000B1),
                        PAY_TO,
                        uint256(1000000),
                        uint64(1790036012),
                        bytes32(uint256(0xa3)),
                        uint32(0)
                    )
                )
            )
        );
        assertEq(verifier.leafHash(p), expected);
    }

    function test_rebuild_theWindowsPaymentsGiveTheRoot() public view {
        IIncomeStatementVerifier.Payment[] memory p = _payments();
        assertEq(p.length, 5); // nine logs: the owner's, the zero, the mint and the self-transfer are not payments
        bytes32[] memory h = new bytes32[](p.length);
        uint256 total;
        for (uint256 i; i < p.length; ++i) {
            h[i] = verifier.leafHash(p[i]);
            total += p[i].amount;
        }
        assertEq(_root(h), ROOT);
        assertEq(total, 1072500);
        assertEq(_root(new bytes32[](0)), bytes32(0));
    }

    // ------------------------------------------------------------- verifyPayment

    function test_verifyPayment_everyVectorProof_emitsPaymentProven() public {
        IIncomeStatementVerifier.Payment[] memory p = _payments();
        for (uint256 i; i < p.length; ++i) {
            vm.expectEmit(true, true, false, true, address(verifier));
            emit PaymentProven(AGENT, ROOT, p[i].txHash, p[i].logIndex);
            assertTrue(_verify(ROOT, _vectorProof(i), p[i]));
        }
    }

    function test_verifyPayment_forgedLeaf_fails() public {
        bytes32[] memory proof = _vectorProof(2);
        IIncomeStatementVerifier.Payment memory f = _payments()[2]; // a fresh copy each time: memory structs alias

        f.amount = 10000000; // the vector's forged leaf: the same log claimed as ten times the amount
        assertFalse(_verify(ROOT, proof, f));

        // every committed field is bound by the leaf
        f = _payments()[2];
        f.chainId = 8453;
        assertFalse(_verify(ROOT, proof, f));
        f = _payments()[2];
        f.asset = address(0xa55e8);
        assertFalse(_verify(ROOT, proof, f));
        f = _payments()[2];
        f.payer = address(0xb9);
        assertFalse(_verify(ROOT, proof, f));
        f = _payments()[2];
        f.payTo = address(0x403);
        assertFalse(_verify(ROOT, proof, f));
        f = _payments()[2];
        f.paidAt += 1;
        assertFalse(_verify(ROOT, proof, f));
        f = _payments()[2];
        f.txHash = bytes32(uint256(0xa4));
        assertFalse(_verify(ROOT, proof, f));
        f = _payments()[2];
        f.logIndex = 1;
        assertFalse(_verify(ROOT, proof, f));

        assertTrue(_verify(ROOT, proof, _payments()[2]));
    }

    function test_verifyPayment_otherAgent_fails() public {
        IIncomeStatementVerifier.Payment memory p = _payments()[0];
        p.agentId = AGENT + 1;
        assertFalse(_verify(ROOT, _vectorProof(0), p));
        p.agentId = 9007199254740992; // what a reader that parsed "9007199254740993" as a float would use
        assertFalse(_verify(ROOT, _vectorProof(0), p));
    }

    function test_verifyPayment_wrongProof_fails() public {
        IIncomeStatementVerifier.Payment memory p = _payments()[0];
        bytes32[] memory proof = _vectorProof(0);

        proof[1] ^= bytes32(uint256(1)); // one sibling altered
        assertFalse(_verify(ROOT, proof, p));

        assertFalse(_verify(ROOT, _vectorProof(2), p)); // another leaf's proof

        bytes32[] memory short = new bytes32[](2); // the last sibling dropped
        short[0] = _vectorProof(0)[0];
        short[1] = _vectorProof(0)[1];
        assertFalse(_verify(ROOT, short, p));

        assertFalse(_verify(ROOT, new bytes32[](0), p)); // no proof
    }

    function test_verifyPayment_wrongRoot_fails() public {
        IIncomeStatementVerifier.Payment memory p = _payments()[0];
        assertFalse(_verify(ROOT ^ bytes32(uint256(1)), _vectorProof(0), p));
        assertFalse(_verify(bytes32(0), _vectorProof(0), p)); // the root of a statement with no payment
        assertFalse(_verify(FILE1_HASH, _vectorProof(0), p)); // a statement's feedbackHash is not its root
    }

    function test_verifyPayment_failure_emitsNothingAndDoesNotRevert() public {
        IIncomeStatementVerifier.Payment memory p = _payments()[0];
        vm.recordLogs();
        bool ok = verifier.verifyPayment(bytes32(0), _vectorProof(0), p);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertFalse(ok);
        assertEq(logs.length, 0);
    }

    function test_verifyPayment_notAPayment_returnsFalseEvenWithAValidProof() public {
        IIncomeStatementVerifier.Payment memory real = _payments()[0];
        IIncomeStatementVerifier.Payment[] memory bad = new IIncomeStatementVerifier.Payment[](3);
        bad[0] = _paymentOf(_window()[4]); // a transfer of zero
        bad[1] = _paymentOf(_window()[6]); // a mint, from the zero address
        bad[2] = _paymentOf(_window()[7]); // payTo to itself
        assertEq(bad[0].amount, 0);
        assertEq(bad[1].payer, address(0));
        assertEq(bad[2].payer, bad[2].payTo);

        for (uint256 i; i < bad.length; ++i) {
            // a root whose tree does hold the transfer's leaf hash, next to a real payment
            bytes32[] memory h = new bytes32[](2);
            h[0] = verifier.leafHash(real);
            h[1] = verifier.leafHash(bad[i]);
            bytes32 root = _root(h);

            vm.recordLogs();
            assertFalse(_verify(root, _proofOf(h, 1), bad[i]));
            assertEq(vm.getRecordedLogs().length, 0);
            assertTrue(_verify(root, _proofOf(h, 0), real)); // the same tree proves the real payment
        }
    }

    function test_verifyPayment_anyCaller() public {
        IIncomeStatementVerifier.Payment[] memory p = _payments();
        address[3] memory callers = [makeAddr("lender"), makeAddr("stranger"), p[0].payer];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            assertTrue(verifier.verifyPayment(ROOT, _vectorProof(i), p[i]));
        }
    }

    function test_verifyPayment_singleLeaf_emptyProof() public {
        IIncomeStatementVerifier.Payment memory p = _payments()[1];
        bytes32 root = verifier.leafHash(p);
        vm.expectEmit(true, true, false, true, address(verifier));
        emit PaymentProven(AGENT, root, p.txHash, p.logIndex);
        assertTrue(_verify(root, new bytes32[](0), p));
    }

    function testFuzz_verifyPayment_everyLeafOfAnyTree(uint8 size, uint8 pick, uint256 seed) public {
        uint256 n = uint256(size) % 40 + 1;
        uint256 k = uint256(pick) % n;
        IIncomeStatementVerifier.Payment[] memory p = new IIncomeStatementVerifier.Payment[](n);
        bytes32[] memory h = new bytes32[](n);
        for (uint32 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            p[i] = IIncomeStatementVerifier.Payment({
                chainId: CHAIN_ID,
                asset: ASSET,
                agentId: AGENT,
                payer: vm.addr(r % 1e18 + 1),
                payTo: PAY_TO,
                amount: r % 1e12 + 1,
                paidAt: FIRST_TIME + uint64(i) * 12,
                txHash: keccak256(abi.encode(r)),
                logIndex: i
            });
            h[i] = verifier.leafHash(p[i]);
        }
        bytes32 root = _root(h);
        bytes32[] memory proof = _proofOf(h, k);
        assertTrue(_verify(root, proof, p[k]));
        p[k].amount += 1;
        assertFalse(_verify(root, proof, p[k]));
    }

    // ------------------------------------------------------------- statement files

    function test_statementFiles_bytesHashesAndFields() public pure {
        assertEq(keccak256(bytes(FILE1)), FILE1_HASH);
        assertEq(keccak256(bytes(FILE2)), FILE2_HASH);
        assertLe(bytes(FILE1).length, 8192);
        assertLe(bytes(FILE2).length, 8192);

        // seq 1 commits to the window's payments
        IIncomeStatementVerifier.Payment[] memory p = _payments();
        assertEq(vm.parseJsonString(FILE1, ".agentId"), vm.toString(AGENT));
        assertEq(vm.parseJsonString(FILE1, ".tag1"), "revenues");
        assertEq(vm.parseJsonString(FILE1, ".tag2"), "x402.statement");
        assertEq(vm.parseJsonUint(FILE1, ".valueDecimals"), 6);
        assertEq(vm.parseJsonUint(FILE1, ".income.decimals"), 6);
        assertEq(vm.parseJsonBytes32(FILE1, ".income.root"), ROOT);
        assertEq(vm.parseJsonUint(FILE1, ".income.received.count"), p.length);
        assertEq(vm.parseJsonString(FILE1, ".income.received.amount"), "1072500");
        assertEq(vm.parseJsonString(FILE1, ".value"), "1072500"); // seq 1: the window's income
        assertEq(vm.parseJsonUint(FILE1, ".income.payers"), 4);
        assertEq(vm.parseJsonAddress(FILE1, ".income.payTo"), PAY_TO);
        assertEq(vm.parseJsonAddress(FILE1, ".income.owner"), OWNER);
        assertEq(vm.parseJsonUint(FILE1, ".income.window.fromBlock"), vm.parseJsonUint(FILE1, ".income.since"));
        assertEq(vm.parseJsonUint(FILE1, ".income.window.fromLog"), 0);
        assertEq(vm.parseJsonUint(FILE1, ".income.window.toTime"), _time(26049999));
        // the anchors are the window's latest payments, in leaf order
        for (uint256 i; i < p.length; ++i) {
            string memory a = string.concat(".income.anchors[", vm.toString(i), "]");
            assertEq(vm.parseJsonAddress(FILE1, string.concat(a, ".payer")), p[i].payer);
            assertEq(vm.parseJsonString(FILE1, string.concat(a, ".amount")), vm.toString(p[i].amount));
            assertEq(vm.parseJsonUint(FILE1, string.concat(a, ".paidAt")), p[i].paidAt);
            assertEq(vm.parseJsonBytes32(FILE1, string.concat(a, ".tx")), p[i].txHash);
            assertEq(vm.parseJsonUint(FILE1, string.concat(a, ".log")), p[i].logIndex);
        }

        // seq 2 follows it: chained by hash, back to back, no payment, the same cumulative value
        assertEq(vm.parseJsonUint(FILE2, ".income.seq"), 2);
        assertEq(vm.parseJsonBytes32(FILE2, ".income.prev"), FILE1_HASH);
        assertEq(
            vm.parseJsonUint(FILE2, ".income.window.fromBlock"), vm.parseJsonUint(FILE1, ".income.window.toBlock") + 1
        );
        assertEq(vm.parseJsonUint(FILE2, ".income.since"), vm.parseJsonUint(FILE1, ".income.since"));
        assertEq(vm.parseJsonUint(FILE2, ".income.window.fromLog"), 0);
        assertEq(vm.parseJsonUint(FILE2, ".income.received.count"), 0);
        assertEq(vm.parseJsonBytes32(FILE2, ".income.root"), bytes32(0));
        assertEq(vm.parseJsonString(FILE2, ".value"), vm.parseJsonString(FILE1, ".value"));
    }
}

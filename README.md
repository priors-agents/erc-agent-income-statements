# Agent Income Statements (draft ERC)

Public, per-transfer income statements for ERC-8004 agents, carried as ordinary entries of the ERC-8004 Reputation
Registry. A statement commits, with a Merkle root, to the incoming transfers of one ERC-20 token to the agent's
`agentWallet` over a window of log positions, each transfer its own leaf. One writer's statements about one agent are
chained by hash over back-to-back windows, and anyone can rebuild every leaf and total from the token's own logs and the
identity registry's. Entries use ERC-8004's own `revenues` tag, with `x402.statement` as `tag2`, and their value is the
cumulative total, as ERC-8004 describes `revenues`. An optional verifier contract checks one transfer against a
statement's root on chain. No new core contract is required.

"Income" here means gross receipts at one address in one asset, as the token's logs show them: every transfer into the
`agentWallet` except mints, transfers of nothing and the agent's own. x402 payments, which settle as a token transfer to
the agent's `payTo`, are the motivating case; a log cannot show how a transfer was settled, so the totals are not called
x402 revenue.

This proposal follows the ERC-8004 credit history profile (`docs/ERC-8004-CREDIT.md` in github.com/priors-agents/priors)
and reuses its encoding: canonical JSON, `data:` URIs, chained windows, Merkle roots, light and full checks. It should
be read after that profile. The ERC text repeats what it needs, so that it stands alone.

**Status: draft, not submitted.** The text is in
[`ERCS/erc-draft_agent_income_statements.md`](ERCS/erc-draft_agent_income_statements.md). Its `eip: 99909` is a
placeholder: the ERC editors assign the real number when the pull request is opened on ethereum/ERCs. Discussion will
open on Ethereum Magicians first.

## Why

Agents paid over x402 receive their income as token transfers, so it is public in principle. Today an agent's income is
one `proofOfPayment` per feedback, a figure from someone's API, or an aggregate an issuer computed under its own
algorithm, and nobody else can see or recount the transfers behind a total without redoing the scan. A lender that sizes
credit on income needs a figure it can check cheaply, without trusting the agent or whoever reports it. These statements
give that figure per window, with every transfer behind it as a leaf a contract can prove. They count only transfers to
the address the agent declared, under the owner and wallet in force at each transfer's own log, so nobody can credit an
agent with another address's income.

## What is here

| Path | What |
|---|---|
| `ERCS/erc-draft_agent_income_statements.md` | The ERC text, in the ethereum/ERCs template |
| `src/IIncomeStatementVerifier.sol` | The optional verifier's interface |
| `src/IncomeStatementVerifier.sol` | A reference verifier (not audited) |
| `src/IncomeStatementCodec.sol` | The file's canonical encoding, its `data:` URI, the leaf hash and the root |
| `src/IncomeStatementWindows.sol` | Where windows start and end at the agent's change logs |
| `src/IncomeStatementWriter.sol` | A reference writer: the next statement, its file, URI and `feedbackHash`, from the chain |
| `src/IncomeStatementChecker.sol` | A reference reader: every reader rule as a check with its own error, light and full reads, and the income an agent's chains give |
| `src/IChainHistory.sol`, `src/IncomeStatementTypes.sol` | The chain reads the writer and reader make, and the decoded statement |
| `test/IncomeStatementVerifier.t.sol`, `test/Vectors.sol` | The ERC's test vectors (leaves, proofs, root, both files' exact bytes) and the verifier's tests |
| `test/IncomeStatementReader.t.sol`, `test/mocks/Mocks.sol` | The writer and the reader against a recorded chain with wallet and owner changes, one negative test per rule |
| `scripts/lint-erc.sh` | Lints the ERC text with eipw the way the ethereum/ERCs CI does |
| `eipw.toml` | The ethereum/ERCs repository's eipw configuration, copied as is |

None of the contracts has a dependency. The writer and reader are references for the rules: a contract cannot read
past blocks, so they take the chain through `IChainHistory`, which a reader implements over an RPC endpoint and runs
with `eth_call`.

## Checks

```bash
forge build
forge test
scripts/lint-erc.sh   # needs eipw: cargo install eipw --version 0.11.0 --locked
```

CI runs all three on every push (`.github/workflows/ci.yml`).

## Related drafts

- Credit history for ERC-8004 agents: a profile of the ERC-8004 Reputation Registry for loan outcomes
  (`docs/ERC-8004-CREDIT.md` in github.com/priors-agents/priors). This profile shares its encoding, its chained windows
  and its light and full checks, with a different tag and leaf.
- Agent Credit Lines: one interface to borrow, repay and default against any lender to agent identities (to be
  published as github.com/priors-agents/erc-agent-credit-lines). Income statements are what an income-sized line is
  sized on.

## Related work

- **ERC-8434 Agent Identity (AID)**, an open pull request (https://github.com/ethereum/ERCs/pull/2044, discussed at
  https://ethereum-magicians.org/t/29805).
  - **What it covers.** Its `aid:finance/observed/v1` facet gives windowed aggregate figures about one address's money
    (`txCount`, `inflowUsd`, `counterpartyCount` and others), which anyone can recompute under an algorithm pinned as an
    ERC-8419 scheme. Such a facet MAY be committed in the issuer's hash-chained log (an informative profile of
    ERC-8434), and is disclosed by default only through zero-knowledge predicates. AID recommends anchoring on the agent's `agentWallet`, the address these statements
    count, so both are about the same address.
  - **What differs.** These statements have one leaf per incoming transfer instead of aggregate metrics, one asset in
    base units instead of USD across assets, public instead of ZK by default, an ERC-8004 `revenues` entry instead of
    an AID facet resolved through an ERC-8419 assertion, and a one-transfer verifier.
  - **How the two coexist.** `aid:finance/observed/v1` itself cannot point at statements: its resolver kind is
    `erc8419-assertion` and its content schema is closed. Instead, a facet type in the writer's own namespace can point
    at the statements with resolver kind `erc8004-reputation` and `tag1` `revenues`. That resolver kind defines `tag1`
    only: `tag2` `x402.statement` is an extra member its open schema allows, and a generic resolver need not filter on
    it. Or the statements can be the input of an OBSERVED algorithm pinned as an ERC-8419 scheme, which then fills
    `inflowUsd`.
  - **Attribution.** AID attributes evidence keyed by `agentId` by the facet's `observedAt` (or `validFrom`) inside an
    authority interval, not by the period the facet is about. A facet issuer that points at a statement therefore sets
    `subjectWindow` to the statement's window and `observedAt` to the window's `toTime`. Every window lies within one
    owner and one wallet, and so within at most one AID authority interval: AID's own `Bound`, `Unbound` and `retire`
    also cut intervals, which statements do not observe, and only the cuts at ERC-8004's `Transfer` and
    `MetadataSet("agentWallet")` coincide.
  - **A per-tag mean is not income.** AID's `aid:review/erc8004/v1` facet reports a mean per `tag1` from `getSummary`,
    and a resolver that does not filter on `tag2` mixes these entries with any other `revenues` entry. For these
    cumulative entries, a mean has no meaning. The ERC's reader rules take one chain's latest value instead,
    and the AID thread is the place to ask that cumulative tags be reported by `tag2` as the latest value per writer.
- **ERC-8419 Know-Your-Agent (KYA)**, an open pull request (https://github.com/ethereum/ERCs/pull/2012). Its example
  lender rule ("net inflow over 180 days above a threshold") is proven privately with a zero-knowledge predicate. It is
  the alternative for agents that do not want their payers public.
- **Agentic Finance Graph's accounting specification**
  (https://github.com/AgenticFinanceGraph/agentic-finance-graph-spec) publishes an off-chain `agent.statement.v1`. It
  has one statement per agent per three-hour window, chained by hash, and one signed Merkle root per window over all
  agents, whose leaves are whole statements. Its roots are not yet committed on chain. It is built around an agent's
  spending, and it does not post to the ERC-8004 Reputation Registry.

## Licence

CC0 1.0 ([LICENSE.md](LICENSE.md)), as the ERC process requires.

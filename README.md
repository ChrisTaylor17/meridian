# Meridian v0.1

Meridian is an open research prototype of a governance and economic-coordination protocol for humans, organizations, and autonomous agents. It is a hypothesis about a few software objects and the transitions between them. It is not a claim that the hypothesis holds as a social system, and it is not a claim about any existing institution. Whether a design in this direction could be adequate is unknown.

Phase 1 is two arms of the same deterministic state machine.

**Arm A is the control, and it is the default.** It is an ordinary SQLite database of signed mandates. Tests use the Python standard-library `sqlite3` module. No database server is required.

**Arm B is the contract arm.** It is the Foundry prototype already in this repo: ordinary EVM bytecode, deployed only to local Anvil (chain id 31337). The deploy script reverts on every other chain id, including Sepolia (11155111). Arm B exists to see whether a chain adds a trust property the database lacks. That question is unanswered.

There is no new layer-1, no consensus client, and no validator set. There is no model inside the state machine. A model score is not a vote and is not a fact in either store.

## The rule

AI reasons. The protocol authorizes. Evidence verifies. Finality is an append-only commit of a transition that already passed the checks.

On Arm A the database commits that transition. On Arm B the local chain commits it. Probabilistic model output is refused on both. Arm B's `submitModelOutput` is `pure` and reverts with `ProbabilisticOutputRejected`. Arm A's `submit_model_output` raises, and the schema has no confidence, prompt, or probability column.

A claim hash can commit to a document that contains model prose. Finality then means an identity committed to that hash under a mandate and the challenge rule finished. It does not mean the model was right.

## Shared state machine

Both arms enforce the same bounds.

- **Identity.** A human, an organization, or an agent. An agent key cannot authorize itself. Kind is self-asserted.
- **Mandate.** Who, what action, which resource, and an expiry. A mandate may only narrow authority. A root grant is the resource controller cutting one of those tuples out of their control of that resource. A further grant may not exceed its parent's action, resource, or expiry. A different action, a different resource, or a later expiry fails. There is no wildcard.
- **Evidence.** A signed hash and a challenge window. The fail-closed boolean rule below is the same on both arms. A challenged claim does not become final because time passed.
- **Finality.** An append-only receipt, written only after the checks. Arm A rejects `UPDATE` and `DELETE` on receipts with a trigger. Arm B writes the receipt once and reverts on a second commit.
- **Physical authority.** Remote governance cannot set or loosen a local safety limit. `test_remoteGovernanceCannotSetOrLoosenTheLocalLimit` and `test_F07_remoteGovernanceCannotSetOrLoosenLocalSafetyLimit` show the Arm B call failing. `test_remote_governance_cannot_override_local_safety` shows the Arm A call failing. The local operator remains outside the protocol.
- **Value.** A mock stable unit, or a hash of an Arm A payment record. Arm A stores that hash on the receipt. Arm B stores the mock unit as `mockStableNote`, and the evidence `claimHash` can be the Arm A payment hash. Neither arm has a mint function.

Action ids, the same 32 bytes on both arms:

- `SET_STATE` = `keccak256("meridian.action.set_state.v0")` = `0x22b1ae1377ae291bc43a5a99180af1a0a80892d8c798278487a4baa51b790698`
- `NOTE_BALANCE` = `keccak256("meridian.action.note_balance.v0")` = `0x754a12bd633fe0208d8883f0a041fec253a3972584b98e27a5ed1b431ef9e87e`
- `CHALLENGE` = `keccak256("meridian.action.challenge.v0")` = `0x36db107a1cf94ba10a52926a5532c9b97d04405b27ad2325b0e731dc6a36d98b`

Passing these tests answers the narrow questions for this code. It does not show that the protocol coordinates real people, real organizations, or real machines. It does not show that Arm B is more trustworthy than Arm A.

## What is in v0.1

- **Identity.** Portable ids for a human, an organization, and an agent. On Arm B the id is `keccak256(abi.encode("MERIDIAN_ID_V0", kind, controller, sponsorId, salt))`. It is not an address. The same preimage computes the same id on any chain. v0.1 does not replicate the registry across chains. Arm A ids are `sha256` of a canonical encoding of the same fields, and the controlling key is Ed25519. Kind is chosen by the registering key on both arms.
- **Mandate.** Grantor, grantee, one action, one resource, expiry. The grantor must be a human or an organization. A root grant must come from the resource controller. `delegateMandate` may not exceed the parent. Grantee, action, and resource must match exactly at use. A mandate may be used more than once until it expires or is revoked. Revoking an ancestor blocks new uses of a child. Revocation does not delete an attestation already submitted.
- **Evidence.** An attestation stores a claim hash under a mandate. A challenge window follows. Reason codes are 1 (contradiction), 2 (out of mandate), and 3 (superseded).
- **Finality.** `commit` writes business state and a receipt only when the attestation is `Final`. The stored receipt and the `TransitionFinalized` event are what a later auditor reads. `test_auditorCanReadFinalReceipt` checks both.
- **Physical-authority stub.** `LocalSafetyLimit` holds a number and a local operator key. `applyRemoteDecision` always reverts and is `view`. `Meridian.attemptRemoteSafetyUpdate` only calls that function and is also `view`. The protocol contract does not store a safety limit.
- **Mock stable-asset note.** `mockStableNote` is a figure on a resource, written only by a finalized `NOTE_BALANCE` transition. It is a bookkeeping number in a receipt. Arm A can also store `payment_hash`, the hash of a signed payment row. Recording that row does not credit a supply.

## What is not in v0.1

These are marked in the repo as next steps. Nothing implements them.

- Voting. `src/interfaces/IVoting.sol` only. No tally and no execution.
- Reputation. `src/interfaces/IReputation.sol` only. No score.
- Treasury. `src/interfaces/ITreasury.sol` only. No asset custody.
- A token, a native coin, a mint function, or a sale. Arm B's deploy script does not mint. Arm A has no `mint` method.
- A deploy to Sepolia or any chain other than local Anvil. `test_refusesSepoliaAndEveryNonAnvilChain` locks the check.
- A consensus client or a validator set.
- A check that a key belongs to a human.
- A check that an unchallenged claim is true.
- Cross-chain registry sync.
- A connection to a physical device.
- Single-use mandates, upgradeability, privacy, or key recovery.

## There is no token

This repository does not create, mint, or sell a token. There is no native coin. `mockStableNote` cannot be transferred and has no supply. `test_noTokenSurfaceAndNoEther` calls `totalSupply`, `mint`, `transfer`, `approve`, `balanceOf`, `sell`, and `moduleId` on `Meridian` and expects each call to fail. Sending ether to `Meridian` also reverts.

## Deterministic challenge rule

The rule is fail-closed boolean resolution. It is the same on both arms: written above `EvidenceRegistry` and in `arm_a/engine.py`. No score is an input. The names below are the Arm B calls. Arm A uses the same steps under `submit_evidence`, `challenge`, `resolve`, `finalize`, and `commit`.

1. `submitAttestation` stores a claim hash, the mandate, the action, the resource, and optional mock units. Status becomes `Pending`. The preimage is not stored. The challenge window must be from 1 hour through 30 days. The resolution window has the same bounds. Zero is rejected.
2. Before `challengeDeadline`, the resource controller, or a holder of an exact `CHALLENGE` mandate on that resource, may challenge with reason code 1, 2, or 3.
3. A challenged attestation does not become `Final` because time passed.
4. The resolver is fixed when the resource is registered. The resolver must be a human or an organization, must not be the attester, and rules with a boolean: uphold or reject.
5. If the resolution deadline passes with no verdict, `finalize` sets `Rejected`.
6. If the challenge deadline passes with no challenge, `finalize` sets `Final`. The contract does not inspect the preimage.
7. `commit` updates the resource and writes a receipt only for `Final` evidence.

At the deadline timestamp the window is closed. A challenge at `challengeDeadline` fails. `finalize` can move an unchallenged attestation to `Final` at that same timestamp.

## What a later auditor reads

`Meridian.readReceipt` returns:

- `evidenceId`, `mandateId`, `actorId`, `actionId`, `resourceId`, `claimHash`
- `priorStateHash`, `newStateHash`
- `mockStableNote`
- `finalizedAt`, `blockNumber`, `committer`

The same facts are in `TransitionFinalized`. The new state hash is `previewStateHash(prior, evidenceId, claimHash, actionId, mockStableNote)`, which is `keccak256(abi.encode("MERIDIAN_STATE_V0", prior, evidenceId, claimHash, actionId, mockStableNote))`. A second commit must name the previous hash as its prior. `commit` is permissionless: the authority check happened at submit time, and the function accepts no new claim contents, scores, or amounts.

`receiptByEvidence` maps an evidence id to its receipt id. `computeReceiptId` is `keccak256(abi.encode("MERIDIAN_RECEIPT_V0", evidenceId))`.

Arm A writes the same facts into the `receipts` table: evidence, mandate, actor, action, resource, claim hash, payment hash, prior and new state hashes, mock units, and the time of the commit. The state hash is `sha256` of a canonical `MERIDIAN_STATE_V0.1` encoding. Triggers abort `UPDATE` and `DELETE` on that table. A later auditor reads the row. The hash function differs from Arm B. The checks that must pass before the row is written do not.

## What would falsify this design

A failure of any test in `test/Falsification.t.sol` falsifies the v0.1 implementation of the rule on Arm B. The Arm A file repeats the physical-safety and challenge-period cases. The ten questions, the code they tie to, and what a failure means are in `docs/FALSIFICATION.md`.

These tests do not establish the hypothesis. The design would be in trouble as a coordination system if operators had to put model scores on-chain for it to be useful, if unchallenged hashes were treated as facts about the world, or if this safety stub were mistaken for control of a real machine. Those questions are open.

Known gaps, locked by tests so they stay visible:

- `test_gap_agentKeyCanRegisterASeparateHumanIdentity`
- `test_gap_unchallengedHashFinalizesWithoutAPreimage`
- `test_gap_revocationIsNotRetroactive`

Threats those gaps sit inside: `docs/THREAT.md`.

## How to run the tests

Arm A, from this directory. Python 3.12 and `cryptography` (see `requirements.txt`). SQLite is in the standard library. This run used Python 3.12.3, SQLite 3.45.1, and cryptography 41.0.7.

```
python3 -m unittest arm_a.tests.test_arm_a
```

Arm B. Install [Foundry](https://book.getfoundry.sh/getting-started/installation). `lib/forge-std` is vendored, so `forge test` does not need a network.

```
forge test
```

The ten falsification tests alone:

```
forge test --match-contract FalsificationTest
```

The physical-safety and challenge-period tests are in that Foundry run (`SafetyTest`, `FalsificationTest` F05–F07, `EvidenceTest`) and in the Arm A file named above.

### Result observed

Command: `python3 -m unittest arm_a.tests.test_arm_a`

```
.........
----------------------------------------------------------------------
Ran 9 tests in 0.036s

OK
```

Command: `forge test`

Toolchain: forge 1.8.4 (`50af4efe189dc64bad2b75ed6990b835de66c4ae`), solc 0.8.28.

```
Compiling 40 files with Solc 0.8.28
Solc 0.8.28 finished in 2.76s
Compiler run successful!

Ran 8 tests for test/Identity.t.sol:IdentityTest
[PASS] test_agentCannotSponsorAnotherAgent() (gas: 39764)
[PASS] test_duplicateSaltReverts() (gas: 37451)
[PASS] test_gap_agentKeyCanRegisterASeparateHumanIdentity() (gas: 208044)
[PASS] test_idsArePortablePreimagesNotAddresses() (gas: 33867)
[PASS] test_organizationCanGrantAMandateToAHuman() (gas: 574023)
[PASS] test_registersHumanOrganizationAndAgent() (gas: 46273)
[PASS] test_strangerCannotRegisterAnAgentForAlice() (gas: 38281)
[PASS] test_zeroAgentControllerReverts() (gas: 37525)
Suite result: ok. 8 passed; 0 failed; 0 skipped; finished in 1.37ms (413.80µs CPU time)

Ran 1 test for test/LocalChain.t.sol:LocalChainTest
[PASS] test_refusesSepoliaAndEveryNonAnvilChain() (gas: 2975664)
Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 293.04µs (134.67µs CPU time)

Ran 10 tests for test/Mandate.t.sol:MandateTest
[PASS] test_actionOutsideMandateFails() (gas: 427246)
[PASS] test_agentCannotRevoke() (gas: 219066)
[PASS] test_agentInsideMandateCanSubmit() (gas: 446615)
[PASS] test_delegationCanOnlyNarrow() (gas: 1244487)
[PASS] test_emptyActionReverts() (gas: 43195)
[PASS] test_expiryMustBeInTheFuture() (gas: 43555)
[PASS] test_gap_revocationIsNotRetroactive() (gas: 616244)
[PASS] test_mandateIsReusableUntilExpiry() (gas: 651801)
[PASS] test_onlyResourceControllerCanGrant() (gas: 48585)
[PASS] test_unknownGranteeReverts() (gas: 48263)
Suite result: ok. 10 passed; 0 failed; 0 skipped; finished in 1.87ms (964.35µs CPU time)

Ran 2 tests for test/Safety.t.sol:SafetyTest
[PASS] test_localOperatorCanSetAndLoosenBecauseTheyAreOutOfBand() (gas: 117406)
[PASS] test_remoteGovernanceCannotSetOrLoosenTheLocalLimit() (gas: 109823)
Suite result: ok. 2 passed; 0 failed; 0 skipped; finished in 785.84µs (160.29µs CPU time)

Ran 10 tests for test/Falsification.t.sol:FalsificationTest
[PASS] test_F01_agentCannotGrantItselfAMandate() (gas: 104949)
[PASS] test_F02_expiredMandateCannotAct() (gas: 493990)
[PASS] test_F03_mandateDoesNotCoverADifferentResource() (gas: 358074)
[PASS] test_F04_modelConfidenceCannotBeStored() (gas: 140473)
[PASS] test_F05_challengedClaimDoesNotFinalizeBeforeResolution() (gas: 619454)
[PASS] test_F06_unresolvedChallengeIsRejectedNotFinal() (gas: 610208)
[PASS] test_F07_remoteGovernanceCannotSetOrLoosenLocalSafetyLimit() (gas: 64676)
[PASS] test_F08_controllerKeyRequiredToAttestAsIdentity() (gas: 290329)
[PASS] test_F09_revokedMandateCannotBeReused() (gas: 272396)
[PASS] test_F10_stateDoesNotChangeWithoutAFinalReceipt() (gas: 1490113)
Suite result: ok. 10 passed; 0 failed; 0 skipped; finished in 1.70ms (1.30ms CPU time)

Ran 6 tests for test/Finality.t.sol:FinalityTest
[PASS] test_auditorCanReadFinalReceipt() (gas: 914223)
[PASS] test_commitRejectsPendingChallengedAndRejectedEvidence() (gas: 830724)
[PASS] test_doubleCommitReverts() (gas: 843103)
[PASS] test_mockStableNoteUpdatesOnlyWhenANoteBalanceCommits() (gas: 1736390)
[PASS] test_noTokenSurfaceAndNoEther() (gas: 217399)
[PASS] test_secondReceiptChainsThePriorStateHash() (gas: 1459976)
Suite result: ok. 6 passed; 0 failed; 0 skipped; finished in 1.15ms (1.33ms CPU time)

Ran 14 tests for test/Evidence.t.sol:EvidenceTest
[PASS] test_agentCannotBeNamedResolver() (gas: 42913)
[PASS] test_challengeClosesAtTheDeadline() (gas: 628816)
[PASS] test_controllerCanChallengeAndResolverCanUpholdOrReject() (gas: 727535)
[PASS] test_defaultRejectWhenChallengeIsUnresolved() (gas: 435634)
[PASS] test_emptyClaimAndUnitsOnSetStateRevert() (gas: 81825)
[PASS] test_gap_unchallengedHashFinalizesWithoutAPreimage() (gas: 330881)
[PASS] test_invalidReasonAndDoubleChallengeRevert() (gas: 343778)
[PASS] test_mandatedChallengerCanChallenge() (gas: 489063)
[PASS] test_modelOutputCallRevertsAndWritesNothing() (gas: 105868)
[PASS] test_pendingAttestationIsNotFinal() (gas: 301303)
[PASS] test_resolverIsFixed() (gas: 47707)
[PASS] test_strangerCannotChallenge() (gas: 322324)
[PASS] test_strangerCannotResolveAndAttesterCannotResolveSelf() (gas: 918924)
[PASS] test_windowsMustSitInsideTheBounds() (gas: 368055)
Suite result: ok. 14 passed; 0 failed; 0 skipped; finished in 3.70ms (1.92ms CPU time)

Ran 7 test suites in 8.39ms (10.87ms CPU time): 51 tests passed, 0 failed, 0 skipped (51 total tests)
```

The falsification contract is included above: 10 passed, 0 failed.

### Local chain

Anvil only. Do not point the script at Sepolia or any other public network. The key below is Anvil's published default account. It is for a local node. The estimated ether in the script output is Anvil's local accounting. Nothing was spent.

```
anvil --port 18545 --chain-id 31337
forge script script/LocalDeploy.s.sol --rpc-url http://127.0.0.1:18545 --broadcast --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

Observed on local chain id 31337. The gas figure is Anvil's accounting in its own ether, on a process that mines blocks locally. No public network was used.

```
Script ran successfully.

== Logs ==
  Meridian 0x5FbDB2315678afecb367f032d93F642f64180aa3
  LocalSafetyLimit 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
  chainId 31337

ONCHAIN EXECUTION COMPLETE & SUCCESSFUL.
```

The same script against a local node whose chain id is Sepolia's (11155111), without `--broadcast`:

```
Error: script failed: RefusingNonLocalChain(11155111 [1.115e7])
```

## Layout

- `src/IdentityRegistry.sol` — human, organization, agent
- `src/ResourceRegistry.sol` — resource, resolver, state hash, mock note
- `arm_a/engine.py` — Arm A, the SQLite control
- `arm_a/schema.sql` — tables, the no-widen trigger, append-only receipts
- `arm_a/tests/test_arm_a.py` — Arm A tests, including safety and challenge
- `src/MandateRegistry.sol` — bounded authority, including narrow-only delegation
- `src/EvidenceRegistry.sol` — attestations and the challenge rule
- `src/Meridian.sol` — Arm B commit, receipt, remote safety attempt
- `src/LocalSafetyLimit.sol` — physical-authority stub
- `src/interfaces/` — voting, reputation, treasury, unimplemented
- `src/Actions.sol`, `src/Types.sol` — action ids, kinds, statuses
- `test/Falsification.t.sol` — the ten Arm B attack questions
- `test/Safety.t.sol`, `test/LocalChain.t.sol` — remote safety, and the Sepolia refusal
- `script/LocalDeploy.s.sol` — local Anvil deploy only
- `docs/THREAT.md`, `docs/FALSIFICATION.md`

## License

The contracts and docs in this repository are MIT. `lib/forge-std` is vendored Foundry standard library under its own MIT or Apache-2.0 license.

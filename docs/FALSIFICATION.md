# Falsification tests

These ten questions are implemented on Arm B in `test/Falsification.t.sol`. A failing test means the v0.1 rule, as implemented, is false. A passing test does not show that the research hypothesis is true, and it does not show that Arm B adds a trust property Arm A lacks. That comparison is unanswered. See `docs/THREAT.md` for gaps these tests leave open.

Arm A repeats the physical-safety and challenge-period questions in `arm_a/tests/test_arm_a.py`:

- `test_remote_governance_cannot_override_local_safety`
- `test_challenged_claim_does_not_finalize_before_resolution`
- `test_unresolved_challenge_is_rejected_not_final`

Arm A also locks narrowing (`test_mandate_cannot_widen_action_resource_or_expiry`) and append-only receipts (`test_finality_is_an_append_only_receipt`). Arm B locks narrowing in `test_delegationCanOnlyNarrow`.

Run them with:

```
forge test --match-contract FalsificationTest
```

## 1. Can an agent identity grant itself a mandate?

`test_F01_agentCannotGrantItselfAMandate`

The agent key calls `grantMandate` with its own id as grantor, and `registerResource` with its own id as controller. Both must revert with `AgentCannotAuthorize`. The same key calling `grantMandate` with a human id it does not control must revert with `NotController`.

Code: `IdentityRegistry._requireAuthorizer`, `MandateRegistry.grantMandate`, `ResourceRegistry.registerResource`.

Falsified if any of those calls succeed.

## 2. Can a grantee act in the block the mandate expires?

`test_F02_expiredMandateCannotAct`

One second before `expiry`, `submitAttestation` succeeds. At `expiry`, the same mandate reverts with `MandateExpired`. The check is `block.timestamp >= expiry` in `MandateRegistry._useMandate`.

Falsified if the submit at `expiry` succeeds.

## 3. Can a mandate for resource A authorize an action on resource B?

`test_F03_mandateDoesNotCoverADifferentResource`

The mandate names resource A. Submitting against resource B reverts with `MandateMismatch`. Resource B's state hash stays zero. The fields that must match are grantee, action, and resource, in `MandateRegistry._useMandate`. There is no wildcard.

Falsified if the submit succeeds or resource B changes.

## 4. Can a confidence score or a model blob be written into protocol state?

`test_F04_modelConfidenceCannotBeStored`

`submitModelOutput` reverts with `ProbabilisticOutputRejected`. The function is `pure` (`EvidenceRegistry.submitModelOutput`), so the compiler forbids storage writes. The test also checks that attestation count, receipt count, the state hash, and the mock note are unchanged, and that `confidence` and `modelScore` selectors are absent. Arm A raises from `submit_model_output` and has no confidence, prompt, or probability column (`test_model_output_is_not_stored`).

Falsified if the call succeeds or any of those values change.

## 5. Can a challenged attestation become final before the resolver rules?

`test_F05_challengedClaimDoesNotFinalizeBeforeResolution`

After a challenge, `finalize` reverts with `EvidenceNotReady` at the challenge deadline and again one second before the resolution deadline. `commit` reverts with `EvidenceNotFinal`. Status stays `Challenged`. The state hash stays zero.

Code: `EvidenceRegistry.finalize`, `EvidenceRegistry.resolveChallenge`, `Meridian.commit`.

Falsified if status becomes `Final`, or if `commit` writes a receipt, before a boolean verdict.

## 6. If nobody resolves a challenge, does the claim become final when the clock runs out?

`test_F06_unresolvedChallengeIsRejectedNotFinal`

At the resolution deadline, `finalize` sets `Rejected` and emits the default-reject path. `commit` reverts. Receipt count stays zero. This is the fail-closed rule in `EvidenceRegistry.finalize`. The verdict is not a score. There is no score input.

Falsified if the unresolved challenge becomes `Final`.

## 7. Can a remote governance call set or loosen a local safety limit?

`test_F07_remoteGovernanceCannotSetOrLoosenLocalSafetyLimit`

`Meridian.attemptRemoteSafetyUpdate` calls `LocalSafetyLimit.applyRemoteDecision` with a higher limit and reverts with `RemoteGovernanceRejected`. A call from the Meridian address to `setLocalLimit` with a lower limit reverts with `NotLocalAuthority`. A remote account calling `applyRemoteDecision` with a higher limit reverts. The stored limit is unchanged.

`applyRemoteDecision` is `view` and always reverts, so it cannot write. `attemptRemoteSafetyUpdate` is also `view`.

Falsified if `limit` changes.

## 8. Can a stranger submit an attestation as someone else's identity?

`test_F08_controllerKeyRequiredToAttestAsIdentity`

A stranger submitting with the agent's id and the agent's mandate reverts with `NotController`. The agent key submitting with the human's id on a mandate granted to the agent reverts with `MandateMismatch`. Attestation count stays zero.

Code: `MandateRegistry._useMandate`.

Falsified if an attestation is stored.

## 9. Can a revoked mandate still authorize a new submission?

`test_F09_revokedMandateCannotBeReused`

After `revokeMandate`, `submitAttestation` reverts with `MandateRevoked`. Attestation count stays zero.

Code: `MandateRegistry.revokeMandate`, `MandateRegistry._useMandate`.

Falsified if the submit succeeds. This test does not claim revocation undoes an attestation already submitted. That gap is `test_gap_revocationIsNotRetroactive`.

## 10. Can business state change without a final audit receipt?

`test_F10_stateDoesNotChangeWithoutAFinalReceipt`

A challenged note is rejected by timeout. `commit` reverts, `readReceipt` reverts, the mock note stays 0, and the state hash stays zero. A second attestation is finalized and, only then, `commit` writes a receipt. The resource's note and state hash match that receipt.

Code: `Meridian.commit`, `Meridian.readReceipt`, `TransitionFinalized`.

Falsified if the note or the state hash changes while receipt count is still zero, or if the committed note disagrees with the receipt.

## What these ten do not close

Passing them leaves the questions in `docs/THREAT.md` open. Three of those are locked as known behavior, not as successes:

- `test_gap_agentKeyCanRegisterASeparateHumanIdentity`
- `test_gap_unchallengedHashFinalizesWithoutAPreimage`
- `test_gap_revocationIsNotRetroactive`

A stronger claim — that an agent operator cannot obtain authority, that finality means the claim is true, or that revocation erases in-flight claims — is already false under these tests.

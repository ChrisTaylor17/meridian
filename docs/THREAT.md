# Threat note

Meridian v0.1 is a research prototype with two arms of one state machine. Arm A is a SQLite database of signed mandates. Arm B is the local contract arm. This note says what both arms actually trust. It is short on purpose.

## Who can forge an attestation

Anyone who holds the controller key of a registered identity can submit an attestation as that identity, if a live mandate names them. Arm A checks an Ed25519 signature. Arm B checks the transaction sender. Neither checks who the person is, and neither reads the claim.

Registration is self-asserted. A key chooses Human, Organization, or Agent. `test_gap_agentKeyCanRegisterASeparateHumanIdentity` shows the consequence: the same key that controls an Agent identity can register a second identity as Human and authorize from that second id. The Agent id still cannot grant a mandate. A fresh key can register as Human with no Agent id at all. Nothing in v0.1 binds a key to a human body or to an organization that exists off-chain.

A forged attestation, in this design, is a pending record of a hash. It becomes auditable business state only through the same challenge rule on both arms: `src/EvidenceRegistry.sol` on Arm B, and `arm_a/engine.py` on Arm A. If nobody challenges it, `finalize` marks it Final when the window ends. The preimage is never stored. `test_gap_unchallengedHashFinalizesWithoutAPreimage` locks that behavior on Arm B.

Arm B's `submitModelOutput` reverts and is `pure`, so a score or a model blob is not written. Arm A's `submit_model_output` raises the same way, and `arm_a/schema.sql` has no confidence, prompt, or probability column. A failed Arm B transaction can still leave calldata visible to node operators. That calldata is not protocol state and it is not a finalized claim. Do not put secrets in the call.

## What the challenge period does not catch

The challenge period is a deadline, not an investigation.

- If no eligible challenger acts, the hash finalizes. Silence is treated as no objection. It is not treated as truth, except by a reader who ignores that distinction.
- The eligible challengers are the resource controller and holders of an exact challenge mandate. Everyone else is ignored. A lie that those parties want, or never see, is not caught.
- The resolver is one designated human or organization, fixed at resource registration. They rule with a boolean. They can collude with the attester. They can be careless. The contract cannot tell.
- The attester cannot resolve their own attestation. A second identity under the same key can still be the resolver. v0.1 does not link identities to people.
- The contract stores a hash. It does not store the document. A missing, swapped, or model-written preimage is invisible on-chain. Finality means "this identity committed to this hash under this mandate and the challenge rule finished," not "the sentence in the preimage is true." If the preimage is model prose, finalizing the attestation does not make the model right.
- Revocation is not retroactive. `test_gap_revocationIsNotRetroactive` shows an attestation submitted before `revokeMandate` can still finalize. A stolen grantor key can grant new mandates until someone else holds a key that can revoke them. If the only revocation key is the stolen one, revocation is unavailable.
- An open challenge plus fail-closed resolution is a denial-of-service tool. A controller, or a challenge-mandate holder, can push an attestation into `Challenged`. If the resolver never rules, `finalize` rejects it. That blocks a true claim as easily as a false one.
- Reason codes are labels chosen by the challenger. The code is not evidence.

## Local physical safety is out of band

`src/LocalSafetyLimit.sol` and Arm A's `safety_limits` table are stubs. Neither is wired to a sensor, a robot, a lock, or a plant. A passing test means a remote call failed inside this process. It does not mean a device obeyed.

On Arm B, `applyRemoteDecision` always reverts, for a tighter value or a looser one, and `Meridian.attemptRemoteSafetyUpdate` is `view`, so the protocol contract cannot write the limit. On Arm A, `apply_remote_safety` raises and does not update the row. The local operator key can change the stored number on either arm. `test_localOperatorCanSetAndLoosenBecauseTheyAreOutOfBand` and `test_remote_governance_cannot_override_local_safety` show the split. The person at the machine, a mis-wired controller, or a bug in real firmware is outside this repository. Neither the database nor the chain is a safety system.

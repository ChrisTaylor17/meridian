"""Arm A tests. The database is the control arm of the v0.1 state machine."""

from __future__ import annotations

import sqlite3
import unittest

from arm_a.engine import (
    NOTE_BALANCE,
    REASON_CONTRADICTION,
    SET_STATE,
    AgentCannotAuthorize,
    BadSignature,
    Clock,
    Engine,
    EvidenceNotFinal,
    EvidenceNotReady,
    Key,
    MandateWidened,
    ProbabilisticOutputRejected,
    RemoteGovernanceRejected,
    RuleError,
)


class ArmATest(unittest.TestCase):
    def setUp(self) -> None:
        self.clock = Clock()
        self.engine = Engine(clock=self.clock)
        self.alice = Key()
        self.bob = Key()
        self.carol = Key()
        self.agent = Key()
        self.local = Key()
        self.alice_id = self.engine.register_human(self.alice, b"alice")
        self.bob_id = self.engine.register_human(self.bob, b"bob")
        self.carol_id = self.engine.register_human(self.carol, b"carol")
        self.agent_id = self.engine.register_agent(self.alice, self.alice_id, self.agent.public, b"agent")
        self.resource_id = self.engine.register_resource(self.alice, self.alice_id, b"resource", self.bob_id)
        self.expiry = self.clock.now + 7 * 24 * 60 * 60
        self.window = 60 * 60

    def test_agent_cannot_authorize_itself(self) -> None:
        with self.assertRaises(AgentCannotAuthorize):
            self.engine.grant_mandate(
                self.agent, self.agent_id, self.agent_id, SET_STATE, self.resource_id, self.expiry
            )
        with self.assertRaises(AgentCannotAuthorize):
            self.engine.register_agent(self.agent, self.agent_id, Key().public, b"child")
        with self.assertRaises(BadSignature):
            self.engine.grant_mandate(
                self.agent, self.alice_id, self.agent_id, SET_STATE, self.resource_id, self.expiry
            )

    def test_mandate_cannot_widen_action_resource_or_expiry(self) -> None:
        parent = self.engine.grant_mandate(
            self.alice, self.alice_id, self.carol_id, SET_STATE, self.resource_id, self.expiry
        )
        with self.assertRaises(MandateWidened):
            self.engine.delegate_mandate(
                self.carol,
                self.carol_id,
                parent,
                self.agent_id,
                SET_STATE,
                self.resource_id,
                self.expiry + 1,
            )
        with self.assertRaises(MandateWidened):
            self.engine.delegate_mandate(
                self.carol,
                self.carol_id,
                parent,
                self.agent_id,
                NOTE_BALANCE,
                self.resource_id,
                self.expiry,
            )
        other = self.engine.register_resource(self.alice, self.alice_id, b"other", self.bob_id)
        with self.assertRaises(MandateWidened):
            self.engine.delegate_mandate(
                self.carol, self.carol_id, parent, self.agent_id, SET_STATE, other, self.expiry
            )
        with self.assertRaises(AgentCannotAuthorize):
            agent_parent = self.engine.grant_mandate(
                self.alice, self.alice_id, self.agent_id, SET_STATE, self.resource_id, self.expiry
            )
            self.engine.delegate_mandate(
                self.agent, self.agent_id, agent_parent, self.carol_id, SET_STATE, self.resource_id, self.expiry
            )

        child = self.engine.delegate_mandate(
            self.carol,
            self.carol_id,
            parent,
            self.agent_id,
            SET_STATE,
            self.resource_id,
            self.expiry - 1,
        )
        stored = self.engine.mandate(child)
        self.assertEqual(stored["parent_id"], parent)
        self.assertEqual(stored["expiry"], self.expiry - 1)
        self.assertEqual(stored["action_id"], SET_STATE)
        self.assertTrue(stored["signature"])

        self.engine.revoke_mandate(self.alice, self.alice_id, parent)
        with self.assertRaises(RuleError):
            self._submit(child, self.agent, self.agent_id)

    def test_remote_governance_cannot_override_local_safety(self) -> None:
        safety_id = self.engine.open_safety_limit(self.local, 100)
        before = self.engine.safety(safety_id)["limit_value"]
        with self.assertRaises(RemoteGovernanceRejected):
            self.engine.apply_remote_safety(safety_id, before + 500)
        with self.assertRaises(RemoteGovernanceRejected):
            self.engine.apply_remote_safety(safety_id, before - 1)
        self.assertEqual(self.engine.safety(safety_id)["limit_value"], before)

        self.engine.set_local_safety(safety_id, self.local, 40)
        self.assertEqual(self.engine.safety(safety_id)["limit_value"], 40)
        self.engine.set_local_safety(safety_id, self.local, 90)
        self.assertEqual(self.engine.safety(safety_id)["limit_value"], 90)

    def test_challenged_claim_does_not_finalize_before_resolution(self) -> None:
        mandate_id = self._grant(self.agent_id)
        evidence_id = self._submit(mandate_id, self.agent, self.agent_id)
        self.engine.challenge(self.alice, self.alice_id, evidence_id, REASON_CONTRADICTION)

        evidence = self.engine.evidence(evidence_id)
        self.clock.now = evidence["challenge_deadline"]
        with self.assertRaises(EvidenceNotReady):
            self.engine.finalize(evidence_id)
        self.clock.now = evidence["resolution_deadline"] - 1
        with self.assertRaises(EvidenceNotReady):
            self.engine.finalize(evidence_id)
        with self.assertRaises(EvidenceNotFinal):
            self.engine.commit(evidence_id, self.alice.public)
        self.assertEqual(self.engine.evidence(evidence_id)["status"], "challenged")
        self.assertEqual(self.engine.resource(self.resource_id)["state_hash"], bytes(32))

    def test_unresolved_challenge_is_rejected_not_final(self) -> None:
        mandate_id = self._grant(self.agent_id)
        evidence_id = self._submit(mandate_id, self.agent, self.agent_id)
        self.engine.challenge(self.alice, self.alice_id, evidence_id, REASON_CONTRADICTION)
        self.clock.now = self.engine.evidence(evidence_id)["resolution_deadline"]
        self.engine.finalize(evidence_id)
        self.assertEqual(self.engine.evidence(evidence_id)["status"], "rejected")
        with self.assertRaises(EvidenceNotFinal):
            self.engine.commit(evidence_id, self.bob.public)
        self.assertEqual(self._receipt_count(), 0)

    def test_finality_is_an_append_only_receipt(self) -> None:
        mandate_id = self._grant(self.agent_id)
        claim = hashlib_bytes(b"delivery")
        evidence_id = self._submit(mandate_id, self.agent, self.agent_id, claim=claim)
        self.assertEqual(self.engine.resource(self.resource_id)["state_hash"], bytes(32))
        self.clock.now = self.engine.evidence(evidence_id)["challenge_deadline"]
        self.engine.finalize(evidence_id)
        self.assertEqual(self.engine.resource(self.resource_id)["state_hash"], bytes(32))

        receipt_id = self.engine.commit(evidence_id, self.bob.public)
        receipt = self.engine.receipt(receipt_id)
        self.assertEqual(receipt["evidence_id"], evidence_id)
        self.assertEqual(receipt["actor_id"], self.agent_id)
        self.assertEqual(receipt["claim_hash"], claim)
        self.assertEqual(receipt["action_id"], SET_STATE)
        self.assertEqual(self.engine.resource(self.resource_id)["state_hash"], receipt["new_state_hash"])
        self.assertNotEqual(receipt["prior_state_hash"], receipt["new_state_hash"])

        with self.assertRaises(sqlite3.IntegrityError):
            self.engine.db.execute(
                "UPDATE receipts SET claim_hash = ? WHERE id = ?", (b"\x11" * 32, receipt_id)
            )
        with self.assertRaises(sqlite3.IntegrityError):
            self.engine.db.execute("DELETE FROM receipts WHERE id = ?", (receipt_id,))
        self.assertEqual(self.engine.receipt(receipt_id)["claim_hash"], claim)

    def test_model_output_is_not_stored(self) -> None:
        before = self._evidence_count()
        with self.assertRaises(ProbabilisticOutputRejected):
            self.engine.submit_model_output(b"prompt text", 0.97, b"model-id")
        self.assertEqual(self._evidence_count(), before)
        names = {
            row["name"].lower()
            for table in self.engine.db.execute(
                "SELECT name FROM sqlite_master WHERE type = 'table'"
            ).fetchall()
            for row in self.engine.db.execute(f"PRAGMA table_info({table['name']})").fetchall()
        }
        self.assertTrue({"confidence", "prompt", "probability", "score"}.isdisjoint(names))

    def test_payment_hash_is_not_a_mint(self) -> None:
        self.assertFalse(hasattr(self.engine, "mint"))
        payment_hash = self.engine.record_payment(self.alice, self.alice_id, self.resource_id, 19)
        self.assertEqual(self.engine.resource(self.resource_id)["mock_stable_note"], 0)
        mandate_id = self.engine.grant_mandate(
            self.alice, self.alice_id, self.agent_id, NOTE_BALANCE, self.resource_id, self.expiry
        )
        evidence_id = self.engine.submit_evidence(
            self.agent,
            self.agent_id,
            mandate_id,
            hashlib_bytes(b"note"),
            19,
            self.window,
            self.window,
            payment_hash=payment_hash,
        )
        self.clock.now = self.engine.evidence(evidence_id)["challenge_deadline"]
        self.engine.finalize(evidence_id)
        receipt_id = self.engine.commit(evidence_id, self.alice.public)
        receipt = self.engine.receipt(receipt_id)
        self.assertEqual(receipt["payment_hash"], payment_hash)
        self.assertEqual(receipt["mock_stable_note"], 19)
        self.assertEqual(self.engine.resource(self.resource_id)["mock_stable_note"], 19)
        self.assertIsNone(
            self.engine.db.execute(
                "SELECT name FROM sqlite_master WHERE name IN ('supply', 'mints', 'token')"
            ).fetchone()
        )

    def test_bad_signature_is_rejected(self) -> None:
        with self.assertRaises(BadSignature):
            self.engine.grant_mandate(
                self.bob, self.alice_id, self.agent_id, SET_STATE, self.resource_id, self.expiry
            )
        mandate_id = self._grant(self.agent_id)
        with self.assertRaises(RuleError):
            self._submit(mandate_id, self.carol, self.agent_id)

    def _grant(self, grantee_id: str) -> str:
        return self.engine.grant_mandate(
            self.alice, self.alice_id, grantee_id, SET_STATE, self.resource_id, self.expiry
        )

    def _submit(self, mandate_id: str, key: Key, actor_id: str, claim: bytes | None = None) -> str:
        return self.engine.submit_evidence(
            key,
            actor_id,
            mandate_id,
            claim or hashlib_bytes(b"claim"),
            0,
            self.window,
            self.window,
        )

    def _receipt_count(self) -> int:
        return self.engine.db.execute("SELECT COUNT(*) AS n FROM receipts").fetchone()["n"]

    def _evidence_count(self) -> int:
        return self.engine.db.execute("SELECT COUNT(*) AS n FROM evidence").fetchone()["n"]


def hashlib_bytes(label: bytes) -> bytes:
    import hashlib

    return hashlib.sha256(label).digest()

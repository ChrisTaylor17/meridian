"""SQLite arm of the Meridian v0.1 state machine.

Arm A is the control. Mandates are signed and may only narrow authority.
Evidence is a signed claim hash with a challenge window. Finality is an
append-only receipt written after those checks. Model confidence, prompts,
and probabilities are not columns and are not accepted.
"""

from __future__ import annotations

import hashlib
import sqlite3
from pathlib import Path

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)

SCHEMA = (Path(__file__).with_name("schema.sql")).read_text(encoding="utf-8")

SET_STATE = bytes.fromhex("22b1ae1377ae291bc43a5a99180af1a0a80892d8c798278487a4baa51b790698")
NOTE_BALANCE = bytes.fromhex("754a12bd633fe0208d8883f0a041fec253a3972584b98e27a5ed1b431ef9e87e")
CHALLENGE = bytes.fromhex("36db107a1cf94ba10a52926a5532c9b97d04405b27ad2325b0e731dc6a36d98b")

REASON_CONTRADICTION = 1
REASON_OUT_OF_MANDATE = 2
REASON_SUPERSEDED = 3
VALID_REASONS = (REASON_CONTRADICTION, REASON_OUT_OF_MANDATE, REASON_SUPERSEDED)

MIN_WINDOW = 60 * 60
MAX_WINDOW = 30 * 24 * 60 * 60
ATTESTABLE = (SET_STATE, NOTE_BALANCE)
FORBIDDEN_COLUMNS = ("confidence", "prompt", "probability", "model_output", "score")


class RuleError(Exception):
    """A deterministic rule rejected the transition. The transaction is rolled back."""


class ProbabilisticOutputRejected(RuleError):
    pass


class AgentCannotAuthorize(RuleError):
    pass


class BadSignature(RuleError):
    pass


class MandateWidened(RuleError):
    pass


class RemoteGovernanceRejected(RuleError):
    pass


class NotLocalAuthority(RuleError):
    pass


class EvidenceNotFinal(RuleError):
    pass


class EvidenceNotReady(RuleError):
    pass


class AppendOnlyViolation(RuleError):
    pass


class Key:
    def __init__(self, private: Ed25519PrivateKey | None = None) -> None:
        self._private = private or Ed25519PrivateKey.generate()
        self.public = self._private.public_key().public_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PublicFormat.Raw,
        )

    def sign(self, payload: bytes) -> bytes:
        return self._private.sign(payload)


def verify(public: bytes, payload: bytes, signature: bytes) -> None:
    try:
        Ed25519PublicKey.from_public_bytes(public).verify(signature, payload)
    except (InvalidSignature, ValueError) as exc:
        raise BadSignature("signature does not match the registered key") from exc


def canon(*parts: bytes) -> bytes:
    out = bytearray()
    for part in parts:
        out += len(part).to_bytes(4, "big")
        out += part
    return bytes(out)


def u64(value: int) -> bytes:
    if value < 0 or value > 2**64 - 1:
        raise RuleError("value does not fit in uint64")
    return int(value).to_bytes(8, "big")


def sha256(payload: bytes) -> bytes:
    return hashlib.sha256(payload).digest()


def hid(payload: bytes) -> str:
    return sha256(payload).hex()


class Clock:
    def __init__(self, start: int = 1_700_000_000) -> None:
        self.now = start

    def advance(self, seconds: int) -> None:
        self.now += seconds


class Engine:
    def __init__(self, path: str = ":memory:", clock: Clock | None = None) -> None:
        self.clock = clock or Clock()
        self.db = sqlite3.connect(path, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.db.executescript(SCHEMA)
        self._assert_no_model_columns()
        self._nonce = 0

    def submit_model_output(self, *_args: object, **_kwargs: object) -> None:
        raise ProbabilisticOutputRejected(
            "model confidence, prompts, and probabilities are not protocol state"
        )

    def register_human(self, key: Key, salt: bytes) -> str:
        return self._register("human", key, salt, sponsor_id=None)

    def register_organization(self, key: Key, salt: bytes) -> str:
        return self._register("organization", key, salt, sponsor_id=None)

    def register_agent(self, sponsor_key: Key, sponsor_id: str, agent_public: bytes, salt: bytes) -> str:
        if len(agent_public) != 32:
            raise RuleError("agent public key must be 32 bytes")
        sponsor = self._identity(sponsor_id)
        if sponsor["kind"] not in ("human", "organization"):
            raise AgentCannotAuthorize("an agent cannot sponsor an identity")
        if sponsor_key.public != sponsor["public_key"]:
            raise BadSignature("key is not the sponsor controller")
        # The sponsor signs. The agent key is the subject, not the authorizer.
        payload = self._agent_payload(sponsor_id, agent_public, salt)
        signature = sponsor_key.sign(payload)
        verify(sponsor["public_key"], payload, signature)
        identity_id = hid(canon(b"MERIDIAN_ID_V0.1", b"agent", agent_public, sponsor_id.encode(), salt))

        def write() -> str:
            if self._identity_or_none(identity_id) is not None:
                raise RuleError("identity exists")
            self.db.execute(
                """
                INSERT INTO identities (id, kind, public_key, sponsor_id, salt, created_at)
                VALUES (?, 'agent', ?, ?, ?, ?)
                """,
                (identity_id, agent_public, sponsor_id, salt, self.clock.now),
            )
            return identity_id

        return self._tx(write)

    def register_resource(self, controller_key: Key, controller_id: str, salt: bytes, resolver_id: str) -> str:
        self._require_authorizer(controller_key, controller_id)
        resolver = self._identity(resolver_id)
        if resolver["kind"] not in ("human", "organization"):
            raise RuleError("resolver must be a human or an organization")
        resource_id = hid(canon(b"MERIDIAN_RESOURCE_V0.1", controller_id.encode(), salt))

        def write() -> str:
            self.db.execute(
                """
                INSERT INTO resources (
                    id, controller_id, resolver_id, state_hash, mock_stable_note, created_at
                ) VALUES (?, ?, ?, ?, 0, ?)
                """,
                (resource_id, controller_id, resolver_id, bytes(32), self.clock.now),
            )
            return resource_id

        return self._tx(write)

    def grant_mandate(
        self,
        grantor_key: Key,
        grantor_id: str,
        grantee_id: str,
        action_id: bytes,
        resource_id: str,
        expiry: int,
    ) -> str:
        return self._write_mandate(
            grantor_key, grantor_id, grantee_id, action_id, resource_id, expiry, parent_id=None
        )

    def delegate_mandate(
        self,
        grantor_key: Key,
        grantor_id: str,
        parent_id: str,
        grantee_id: str,
        action_id: bytes,
        resource_id: str,
        expiry: int,
    ) -> str:
        return self._write_mandate(
            grantor_key, grantor_id, grantee_id, action_id, resource_id, expiry, parent_id=parent_id
        )

    def revoke_mandate(self, grantor_key: Key, grantor_id: str, mandate_id: str) -> None:
        self._require_authorizer(grantor_key, grantor_id)
        mandate = self._mandate(mandate_id)
        if mandate["grantor_id"] != grantor_id:
            raise RuleError("only the grantor can revoke")

        def write() -> None:
            self.db.execute("UPDATE mandates SET revoked = 1 WHERE id = ?", (mandate_id,))

        self._tx(write)

    def record_payment(
        self, payer_key: Key, payer_id: str, resource_id: str, stated_units: int
    ) -> bytes:
        """Store a signed payment record and return its hash.

        This does not mint, credit a supply, or change mock_stable_note.
        """
        if stated_units < 0:
            raise RuleError("stated units cannot be negative")
        payer = self._identity(payer_id)
        self._resource(resource_id)
        nonce = self._next_nonce()
        payload = canon(
            b"MERIDIAN_PAYMENT_V0.1",
            payer_id.encode(),
            resource_id.encode(),
            u64(stated_units),
            u64(nonce),
        )
        signature = payer_key.sign(payload)
        verify(payer["public_key"], payload, signature)
        body_hash = sha256(payload)
        payment_id = body_hash.hex()

        def write() -> bytes:
            self.db.execute(
                """
                INSERT INTO payments (
                    id, payer_id, resource_id, stated_units, body_hash, payload, signature, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    payment_id,
                    payer_id,
                    resource_id,
                    stated_units,
                    body_hash,
                    payload,
                    signature,
                    self.clock.now,
                ),
            )
            return body_hash

        return self._tx(write)

    def submit_evidence(
        self,
        attester_key: Key,
        attester_id: str,
        mandate_id: str,
        claim_hash: bytes,
        mock_units: int,
        challenge_window: int,
        resolution_window: int,
        payment_hash: bytes | None = None,
    ) -> str:
        if claim_hash == bytes(32) or len(claim_hash) != 32:
            raise RuleError("claim hash must be 32 non-zero bytes")
        mandate = self._mandate(mandate_id)
        self._use_mandate(mandate, attester_key, attester_id, mandate["action_id"], mandate["resource_id"])
        action_id = mandate["action_id"]
        if action_id not in ATTESTABLE:
            raise RuleError("action is not attestable")
        if action_id == SET_STATE and mock_units != 0:
            raise RuleError("units are not allowed on set_state")
        self._check_windows(challenge_window, resolution_window)
        if payment_hash is not None:
            row = self.db.execute(
                "SELECT 1 FROM payments WHERE body_hash = ?", (payment_hash,)
            ).fetchone()
            if row is None:
                raise RuleError("payment hash is not an Arm A payment record")
        submitted = self.clock.now
        challenge_deadline = submitted + challenge_window
        resolution_deadline = challenge_deadline + resolution_window
        nonce = self._next_nonce()
        payload = canon(
            b"MERIDIAN_EVIDENCE_V0.1",
            attester_id.encode(),
            mandate_id.encode(),
            action_id,
            claim_hash,
            u64(mock_units),
            payment_hash or b"",
            u64(challenge_window),
            u64(resolution_window),
            u64(nonce),
        )
        attester = self._identity(attester_id)
        signature = attester_key.sign(payload)
        verify(attester["public_key"], payload, signature)
        evidence_id = hid(payload)

        def write() -> str:
            self.db.execute(
                """
                INSERT INTO evidence (
                    id, attester_id, mandate_id, resource_id, action_id, claim_hash, mock_units,
                    payment_hash, payload, signature, submitted_at, challenge_deadline,
                    resolution_deadline, status, challenge_reason, decided_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', NULL, NULL)
                """,
                (
                    evidence_id,
                    attester_id,
                    mandate_id,
                    mandate["resource_id"],
                    action_id,
                    claim_hash,
                    mock_units,
                    payment_hash,
                    payload,
                    signature,
                    submitted,
                    challenge_deadline,
                    resolution_deadline,
                ),
            )
            return evidence_id

        return self._tx(write)

    def challenge(
        self,
        challenger_key: Key,
        challenger_id: str,
        evidence_id: str,
        reason: int,
        challenge_mandate_id: str | None = None,
    ) -> None:
        if reason not in VALID_REASONS:
            raise RuleError("invalid reason")
        evidence = self._evidence(evidence_id)
        if evidence["status"] != "pending":
            raise RuleError("evidence is not pending")
        if self.clock.now >= evidence["challenge_deadline"]:
            raise RuleError("challenge window is closed")
        resource = self._resource(evidence["resource_id"])
        if challenger_id == resource["controller_id"]:
            self._require_authorizer(challenger_key, challenger_id)
        else:
            if challenge_mandate_id is None:
                raise RuleError("challenge mandate required")
            mandate = self._mandate(challenge_mandate_id)
            if mandate["action_id"] != CHALLENGE or mandate["resource_id"] != evidence["resource_id"]:
                raise RuleError("mandate does not cover this challenge")
            self._use_mandate(
                mandate, challenger_key, challenger_id, CHALLENGE, evidence["resource_id"]
            )
        payload = canon(b"MERIDIAN_CHALLENGE_V0.1", evidence_id.encode(), u64(reason))
        verify(self._identity(challenger_id)["public_key"], payload, challenger_key.sign(payload))

        def write() -> None:
            self.db.execute(
                """
                UPDATE evidence SET status = 'challenged', challenge_reason = ? WHERE id = ?
                """,
                (reason, evidence_id),
            )

        self._tx(write)

    def resolve(self, resolver_key: Key, evidence_id: str, uphold: bool) -> None:
        evidence = self._evidence(evidence_id)
        if evidence["status"] != "challenged":
            raise RuleError("evidence is not challenged")
        if self.clock.now >= evidence["resolution_deadline"]:
            raise RuleError("resolution window is closed")
        resolver_id = self._resource(evidence["resource_id"])["resolver_id"]
        resolver = self._identity(resolver_id)
        if resolver["kind"] == "agent":
            raise AgentCannotAuthorize("an agent cannot resolve a challenge")
        if resolver_id == evidence["attester_id"]:
            raise RuleError("the attester cannot resolve their own claim")
        payload = canon(
            b"MERIDIAN_RESOLVE_V0.1", evidence_id.encode(), b"\x01" if uphold else b"\x00"
        )
        verify(resolver["public_key"], payload, resolver_key.sign(payload))
        status = "final" if uphold else "rejected"

        def write() -> None:
            self.db.execute(
                "UPDATE evidence SET status = ?, decided_at = ? WHERE id = ?",
                (status, self.clock.now, evidence_id),
            )

        self._tx(write)

    def finalize(self, evidence_id: str) -> None:
        evidence = self._evidence(evidence_id)

        def write() -> None:
            if evidence["status"] == "pending":
                if self.clock.now < evidence["challenge_deadline"]:
                    raise EvidenceNotReady("challenge window is still open")
                self.db.execute(
                    "UPDATE evidence SET status = 'final', decided_at = ? WHERE id = ?",
                    (self.clock.now, evidence_id),
                )
                return
            if evidence["status"] == "challenged":
                if self.clock.now < evidence["resolution_deadline"]:
                    raise EvidenceNotReady("resolution window is still open")
                self.db.execute(
                    "UPDATE evidence SET status = 'rejected', decided_at = ? WHERE id = ?",
                    (self.clock.now, evidence_id),
                )
                return
            raise RuleError("evidence is already closed")

        self._tx(write)

    def commit(self, evidence_id: str, committer_public: bytes) -> str:
        evidence = self._evidence(evidence_id)
        if evidence["status"] != "final":
            raise EvidenceNotFinal("only final evidence can be committed")
        existing = self.db.execute(
            "SELECT id FROM receipts WHERE evidence_id = ?", (evidence_id,)
        ).fetchone()
        if existing is not None:
            raise RuleError("evidence is already committed")
        verify(self._identity(evidence["attester_id"])["public_key"], evidence["payload"], evidence["signature"])
        resource = self._resource(evidence["resource_id"])
        prior = resource["state_hash"]
        note = resource["mock_stable_note"]
        if evidence["action_id"] == NOTE_BALANCE:
            note = evidence["mock_units"]
        new_hash = sha256(
            canon(
                b"MERIDIAN_STATE_V0.1",
                prior,
                evidence_id.encode(),
                evidence["claim_hash"],
                evidence["action_id"],
                u64(note),
            )
        )
        receipt_id = hid(canon(b"MERIDIAN_RECEIPT_V0.1", evidence_id.encode()))

        def write() -> str:
            if evidence["action_id"] == NOTE_BALANCE:
                self.db.execute(
                    "UPDATE resources SET mock_stable_note = ?, state_hash = ? WHERE id = ?",
                    (note, new_hash, evidence["resource_id"]),
                )
            else:
                self.db.execute(
                    "UPDATE resources SET state_hash = ? WHERE id = ?",
                    (new_hash, evidence["resource_id"]),
                )
            self.db.execute(
                """
                INSERT INTO receipts (
                    id, evidence_id, mandate_id, actor_id, action_id, resource_id, claim_hash,
                    payment_hash, prior_state_hash, new_state_hash, mock_stable_note,
                    finalized_at, committer_public
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    receipt_id,
                    evidence_id,
                    evidence["mandate_id"],
                    evidence["attester_id"],
                    evidence["action_id"],
                    evidence["resource_id"],
                    evidence["claim_hash"],
                    evidence["payment_hash"],
                    prior,
                    new_hash,
                    note,
                    self.clock.now,
                    committer_public,
                ),
            )
            return receipt_id

        return self._tx(write)

    def open_safety_limit(self, operator_key: Key, initial: int) -> str:
        safety_id = hid(canon(b"MERIDIAN_SAFETY_V0.1", operator_key.public, u64(self._next_nonce())))

        def write() -> str:
            self.db.execute(
                "INSERT INTO safety_limits (id, limit_value, operator_public) VALUES (?, ?, ?)",
                (safety_id, initial, operator_key.public),
            )
            return safety_id

        return self._tx(write)

    def apply_remote_safety(self, safety_id: str, new_limit: int) -> None:
        self._safety(safety_id)
        raise RemoteGovernanceRejected(
            f"remote governance cannot set or loosen safety limit {safety_id} to {new_limit}"
        )

    def set_local_safety(self, safety_id: str, operator_key: Key, new_limit: int) -> None:
        row = self._safety(safety_id)
        if operator_key.public != row["operator_public"]:
            raise NotLocalAuthority("local safety is outside remote governance")
        payload = canon(b"MERIDIAN_LOCAL_SAFETY_V0.1", safety_id.encode(), u64(new_limit))
        verify(row["operator_public"], payload, operator_key.sign(payload))

        def write() -> None:
            self.db.execute(
                "UPDATE safety_limits SET limit_value = ? WHERE id = ?", (new_limit, safety_id)
            )

        self._tx(write)

    def receipt(self, receipt_id: str) -> sqlite3.Row:
        row = self.db.execute("SELECT * FROM receipts WHERE id = ?", (receipt_id,)).fetchone()
        if row is None:
            raise RuleError("unknown receipt")
        return row

    def evidence(self, evidence_id: str) -> sqlite3.Row:
        return self._evidence(evidence_id)

    def resource(self, resource_id: str) -> sqlite3.Row:
        return self._resource(resource_id)

    def mandate(self, mandate_id: str) -> sqlite3.Row:
        return self._mandate(mandate_id)

    def safety(self, safety_id: str) -> sqlite3.Row:
        return self._safety(safety_id)

    def _register(self, kind: str, key: Key, salt: bytes, sponsor_id: str | None) -> str:
        payload = canon(b"MERIDIAN_ID_V0.1", kind.encode(), key.public, (sponsor_id or "").encode(), salt)
        identity_id = hid(payload)
        signature = key.sign(payload)
        verify(key.public, payload, signature)

        def write() -> str:
            if self._identity_or_none(identity_id) is not None:
                raise RuleError("identity exists")
            self.db.execute(
                """
                INSERT INTO identities (id, kind, public_key, sponsor_id, salt, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (identity_id, kind, key.public, sponsor_id, salt, self.clock.now),
            )
            return identity_id

        return self._tx(write)

    def _agent_payload(self, sponsor_id: str, agent_public: bytes, salt: bytes) -> bytes:
        return canon(b"MERIDIAN_AGENT_V0.1", sponsor_id.encode(), agent_public, salt)

    def _write_mandate(
        self,
        grantor_key: Key,
        grantor_id: str,
        grantee_id: str,
        action_id: bytes,
        resource_id: str,
        expiry: int,
        parent_id: str | None,
    ) -> str:
        self._require_authorizer(grantor_key, grantor_id)
        if not action_id or len(action_id) != 32:
            raise RuleError("action must be 32 bytes")
        if expiry <= self.clock.now:
            raise RuleError("expiry must be in the future")
        self._identity(grantee_id)
        resource = self._resource(resource_id)
        if parent_id is None:
            if resource["controller_id"] != grantor_id:
                raise RuleError("only the resource controller can grant a root mandate")
        else:
            parent = self._mandate(parent_id)
            self._require_live_chain(parent_id)
            if parent["grantee_id"] != grantor_id:
                raise RuleError("only the mandate holder can delegate")
            if (
                action_id != parent["action_id"]
                or resource_id != parent["resource_id"]
                or expiry > parent["expiry"]
            ):
                raise MandateWidened("a mandate may only narrow action, resource, and expiry")
        nonce = self._next_nonce()
        payload = canon(
            b"MERIDIAN_MANDATE_V0.1",
            (parent_id or "").encode(),
            grantor_id.encode(),
            grantee_id.encode(),
            action_id,
            resource_id.encode(),
            u64(expiry),
            u64(nonce),
        )
        signature = grantor_key.sign(payload)
        verify(self._identity(grantor_id)["public_key"], payload, signature)
        mandate_id = hid(payload)

        def write() -> str:
            self.db.execute(
                """
                INSERT INTO mandates (
                    id, parent_id, grantor_id, grantee_id, action_id, resource_id, expiry,
                    revoked, payload, signature, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
                """,
                (
                    mandate_id,
                    parent_id,
                    grantor_id,
                    grantee_id,
                    action_id,
                    resource_id,
                    expiry,
                    payload,
                    signature,
                    self.clock.now,
                ),
            )
            return mandate_id

        return self._tx(write)

    def _use_mandate(
        self,
        mandate: sqlite3.Row,
        actor_key: Key,
        actor_id: str,
        action_id: bytes,
        resource_id: str,
    ) -> None:
        self._require_live_chain(mandate["id"])
        if (
            mandate["grantee_id"] != actor_id
            or mandate["action_id"] != action_id
            or mandate["resource_id"] != resource_id
        ):
            raise RuleError("action is outside the mandate")
        actor = self._identity(actor_id)
        if actor_key.public != actor["public_key"]:
            raise RuleError("actor key does not control this identity")
        grantor = self._identity(mandate["grantor_id"])
        verify(grantor["public_key"], mandate["payload"], mandate["signature"])

    def _require_live_chain(self, mandate_id: str) -> None:
        cursor = mandate_id
        for _depth in range(16):
            mandate = self._mandate(cursor)
            if mandate["revoked"]:
                raise RuleError(f"mandate {cursor} is revoked")
            if self.clock.now >= mandate["expiry"]:
                raise RuleError(f"mandate {cursor} is expired")
            if mandate["parent_id"] is None:
                return
            cursor = mandate["parent_id"]
        raise RuleError("mandate chain is too deep")

    def _require_authorizer(self, key: Key, identity_id: str) -> None:
        ident = self._identity(identity_id)
        if ident["kind"] == "agent":
            raise AgentCannotAuthorize("an agent identity cannot authorize itself")
        if key.public != ident["public_key"]:
            raise BadSignature("key is not the identity controller")

    def _check_windows(self, challenge_window: int, resolution_window: int) -> None:
        if (
            challenge_window < MIN_WINDOW
            or challenge_window > MAX_WINDOW
            or resolution_window < MIN_WINDOW
            or resolution_window > MAX_WINDOW
        ):
            raise RuleError("challenge or resolution window is out of range")

    def _assert_no_model_columns(self) -> None:
        rows = self.db.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table'"
        ).fetchall()
        for table in rows:
            columns = self.db.execute(f"PRAGMA table_info({table['name']})").fetchall()
            for column in columns:
                if column["name"].lower() in FORBIDDEN_COLUMNS:
                    raise RuleError(f"forbidden truth column {table['name']}.{column['name']}")

    def _next_nonce(self) -> int:
        self._nonce += 1
        return self._nonce

    def _tx(self, write):
        self.db.execute("BEGIN IMMEDIATE")
        try:
            result = write()
        except Exception:
            self.db.execute("ROLLBACK")
            raise
        self.db.execute("COMMIT")
        return result

    def _identity(self, identity_id: str) -> sqlite3.Row:
        row = self._identity_or_none(identity_id)
        if row is None:
            raise RuleError("unknown identity")
        return row

    def _identity_or_none(self, identity_id: str) -> sqlite3.Row | None:
        return self.db.execute("SELECT * FROM identities WHERE id = ?", (identity_id,)).fetchone()

    def _resource(self, resource_id: str) -> sqlite3.Row:
        row = self.db.execute("SELECT * FROM resources WHERE id = ?", (resource_id,)).fetchone()
        if row is None:
            raise RuleError("unknown resource")
        return row

    def _mandate(self, mandate_id: str) -> sqlite3.Row:
        row = self.db.execute("SELECT * FROM mandates WHERE id = ?", (mandate_id,)).fetchone()
        if row is None:
            raise RuleError("unknown mandate")
        return row

    def _evidence(self, evidence_id: str) -> sqlite3.Row:
        row = self.db.execute("SELECT * FROM evidence WHERE id = ?", (evidence_id,)).fetchone()
        if row is None:
            raise RuleError("unknown evidence")
        return row

    def _safety(self, safety_id: str) -> sqlite3.Row:
        row = self.db.execute("SELECT * FROM safety_limits WHERE id = ?", (safety_id,)).fetchone()
        if row is None:
            raise RuleError("unknown safety limit")
        return row

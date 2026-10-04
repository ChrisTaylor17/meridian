-- Arm A. Ordinary SQLite tables for the v0.1 state machine.
-- Receipts are append-only. A mandate row can only be revoked, never widened.
-- There is no token supply, mint, or model-score column.

PRAGMA foreign_keys = ON;

CREATE TABLE identities (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL CHECK (kind IN ('human', 'organization', 'agent')),
    public_key BLOB NOT NULL,
    sponsor_id TEXT,
    salt BLOB NOT NULL,
    created_at INTEGER NOT NULL,
    FOREIGN KEY (sponsor_id) REFERENCES identities (id)
);

CREATE TABLE resources (
    id TEXT PRIMARY KEY,
    controller_id TEXT NOT NULL,
    resolver_id TEXT NOT NULL,
    state_hash BLOB NOT NULL,
    mock_stable_note INTEGER NOT NULL CHECK (mock_stable_note >= 0),
    created_at INTEGER NOT NULL,
    FOREIGN KEY (controller_id) REFERENCES identities (id),
    FOREIGN KEY (resolver_id) REFERENCES identities (id)
);

CREATE TABLE mandates (
    id TEXT PRIMARY KEY,
    parent_id TEXT,
    grantor_id TEXT NOT NULL,
    grantee_id TEXT NOT NULL,
    action_id BLOB NOT NULL,
    resource_id TEXT NOT NULL,
    expiry INTEGER NOT NULL,
    revoked INTEGER NOT NULL CHECK (revoked IN (0, 1)),
    payload BLOB NOT NULL,
    signature BLOB NOT NULL,
    created_at INTEGER NOT NULL,
    FOREIGN KEY (parent_id) REFERENCES mandates (id),
    FOREIGN KEY (grantor_id) REFERENCES identities (id),
    FOREIGN KEY (grantee_id) REFERENCES identities (id),
    FOREIGN KEY (resource_id) REFERENCES resources (id)
);

CREATE TABLE evidence (
    id TEXT PRIMARY KEY,
    attester_id TEXT NOT NULL,
    mandate_id TEXT NOT NULL,
    resource_id TEXT NOT NULL,
    action_id BLOB NOT NULL,
    claim_hash BLOB NOT NULL,
    mock_units INTEGER,
    payment_hash BLOB,
    payload BLOB NOT NULL,
    signature BLOB NOT NULL,
    submitted_at INTEGER NOT NULL,
    challenge_deadline INTEGER NOT NULL,
    resolution_deadline INTEGER NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('pending', 'challenged', 'final', 'rejected')),
    challenge_reason INTEGER,
    decided_at INTEGER,
    FOREIGN KEY (attester_id) REFERENCES identities (id),
    FOREIGN KEY (mandate_id) REFERENCES mandates (id),
    FOREIGN KEY (resource_id) REFERENCES resources (id)
);

CREATE TABLE payments (
    id TEXT PRIMARY KEY,
    payer_id TEXT NOT NULL,
    resource_id TEXT NOT NULL,
    stated_units INTEGER NOT NULL CHECK (stated_units >= 0),
    body_hash BLOB NOT NULL UNIQUE,
    payload BLOB NOT NULL,
    signature BLOB NOT NULL,
    created_at INTEGER NOT NULL,
    FOREIGN KEY (payer_id) REFERENCES identities (id),
    FOREIGN KEY (resource_id) REFERENCES resources (id)
);

CREATE TABLE receipts (
    id TEXT PRIMARY KEY,
    evidence_id TEXT NOT NULL UNIQUE,
    mandate_id TEXT NOT NULL,
    actor_id TEXT NOT NULL,
    action_id BLOB NOT NULL,
    resource_id TEXT NOT NULL,
    claim_hash BLOB NOT NULL,
    payment_hash BLOB,
    prior_state_hash BLOB NOT NULL,
    new_state_hash BLOB NOT NULL,
    mock_stable_note INTEGER NOT NULL,
    finalized_at INTEGER NOT NULL,
    committer_public BLOB NOT NULL
);

CREATE TABLE safety_limits (
    id TEXT PRIMARY KEY,
    limit_value INTEGER NOT NULL,
    operator_public BLOB NOT NULL
);

CREATE TRIGGER mandates_no_widen
BEFORE UPDATE ON mandates
WHEN NOT (
    OLD.revoked = 0
    AND NEW.revoked = 1
    AND OLD.parent_id IS NEW.parent_id
    AND OLD.grantor_id = NEW.grantor_id
    AND OLD.grantee_id = NEW.grantee_id
    AND OLD.action_id = NEW.action_id
    AND OLD.resource_id = NEW.resource_id
    AND OLD.expiry = NEW.expiry
    AND OLD.payload = NEW.payload
    AND OLD.signature = NEW.signature
)
BEGIN
    SELECT RAISE(ABORT, 'mandate would widen or rewrite authority');
END;

CREATE TRIGGER mandates_no_delete
BEFORE DELETE ON mandates
BEGIN
    SELECT RAISE(ABORT, 'mandates are not deleted');
END;

CREATE TRIGGER evidence_claim_immutable
BEFORE UPDATE ON evidence
WHEN OLD.claim_hash != NEW.claim_hash
    OR OLD.attester_id != NEW.attester_id
    OR OLD.mandate_id != NEW.mandate_id
    OR OLD.action_id != NEW.action_id
    OR OLD.resource_id != NEW.resource_id
    OR OLD.signature != NEW.signature
    OR OLD.payload != NEW.payload
    OR OLD.payment_hash IS NOT NEW.payment_hash
BEGIN
    SELECT RAISE(ABORT, 'evidence claim is immutable');
END;

CREATE TRIGGER receipts_no_update
BEFORE UPDATE ON receipts
BEGIN
    SELECT RAISE(ABORT, 'receipts are append-only');
END;

CREATE TRIGGER receipts_no_delete
BEFORE DELETE ON receipts
BEGIN
    SELECT RAISE(ABORT, 'receipts are append-only');
END;

CREATE TRIGGER payments_no_update
BEFORE UPDATE ON payments
BEGIN
    SELECT RAISE(ABORT, 'payment records are append-only');
END;

CREATE TRIGGER payments_no_delete
BEFORE DELETE ON payments
BEGIN
    SELECT RAISE(ABORT, 'payment records are append-only');
END;

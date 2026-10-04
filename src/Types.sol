// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Self-asserted kind of a portable identity. v0 does not prove a key is human.
enum Kind {
    None,
    Human,
    Organization,
    Agent
}

/// @notice Lifecycle of an attestation. Final is the only status that can change business state.
enum EvidenceStatus {
    None,
    Pending,
    Challenged,
    Final,
    Rejected
}

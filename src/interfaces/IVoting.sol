// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Next step. Not implemented in v0.1. No contract in this repo inherits this.
/// @dev A later voting design would need its own threat analysis. v0.1 does not tally votes
///      and does not execute a proposal.
interface IVoting {
    event VoteCast(bytes32 indexed proposalId, bytes32 indexed voterId, bool support);

    function propose(bytes32 proposalId, bytes32 payloadHash) external;

    function cast(bytes32 proposalId, bytes32 voterId, bool support) external;
}

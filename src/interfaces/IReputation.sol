// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Next step. Not implemented in v0.1.
/// @dev A later design must not store a model-generated score as truth. This placeholder
///      is a note hash, not a rating.
interface IReputation {
    event Note(bytes32 indexed subjectId, bytes32 indexed authorId, bytes32 noteHash);
}

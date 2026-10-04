// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Exact action identifiers. v0 grants no wildcard authority.
library Actions {
    bytes32 internal constant SET_STATE = keccak256("meridian.action.set_state.v0");
    bytes32 internal constant NOTE_BALANCE = keccak256("meridian.action.note_balance.v0");
    bytes32 internal constant CHALLENGE = keccak256("meridian.action.challenge.v0");

    uint8 internal constant REASON_CONTRADICTION = 1;
    uint8 internal constant REASON_OUT_OF_MANDATE = 2;
    uint8 internal constant REASON_SUPERSEDED = 3;
}

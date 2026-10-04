// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Kind} from "./Types.sol";

error IdentityExists(bytes32 id);
error UnknownIdentity(bytes32 id);
error NotController(bytes32 id);
error AgentCannotAuthorize(bytes32 id);
error SponsorMustBeAuthority(bytes32 sponsorId);
error ZeroController();

/// @notice Portable identity records for a human, an organization, or an agent.
/// @dev The id is not an address. The same preimage computes the same id on any chain.
///      v0 does not replicate this registry across chains. Kind is chosen by the registrar.
///      An Agent identity cannot authorize: it cannot grant mandates, register resources,
///      or sponsor other agents.
contract IdentityRegistry {
    struct Identity {
        Kind kind;
        address controller;
        bytes32 sponsorId;
    }

    mapping(bytes32 => Identity) internal _identities;

    event IdentityRegistered(
        bytes32 indexed id, Kind kind, address indexed controller, bytes32 sponsorId
    );

    function computeId(Kind kind, address controller, bytes32 sponsorId, bytes32 salt)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode("MERIDIAN_ID_V0", kind, controller, sponsorId, salt));
    }

    function registerHuman(bytes32 salt) external returns (bytes32 id) {
        id = _register(Kind.Human, msg.sender, bytes32(0), salt);
    }

    function registerOrganization(bytes32 salt) external returns (bytes32 id) {
        id = _register(Kind.Organization, msg.sender, bytes32(0), salt);
    }

    /// @notice Only the sponsor's controller may register an agent. The agent key is not the sponsor.
    function registerAgent(bytes32 sponsorId, address agentController, bytes32 salt)
        external
        returns (bytes32 id)
    {
        Identity storage sponsor = _identities[sponsorId];
        if (sponsor.kind != Kind.Human && sponsor.kind != Kind.Organization) {
            revert SponsorMustBeAuthority(sponsorId);
        }
        if (msg.sender != sponsor.controller) revert NotController(sponsorId);
        if (agentController == address(0)) revert ZeroController();
        id = _register(Kind.Agent, agentController, sponsorId, salt);
    }

    function readIdentity(bytes32 id)
        external
        view
        returns (Kind kind, address controller, bytes32 sponsorId)
    {
        Identity storage ident = _identities[id];
        if (ident.kind == Kind.None) revert UnknownIdentity(id);
        return (ident.kind, ident.controller, ident.sponsorId);
    }

    function _register(Kind kind, address controller, bytes32 sponsorId, bytes32 salt)
        internal
        returns (bytes32 id)
    {
        id = computeId(kind, controller, sponsorId, salt);
        if (_identities[id].kind != Kind.None) revert IdentityExists(id);
        _identities[id] = Identity({kind: kind, controller: controller, sponsorId: sponsorId});
        emit IdentityRegistered(id, kind, controller, sponsorId);
    }

    function _requireController(bytes32 id) internal view returns (Identity storage ident) {
        ident = _identities[id];
        if (ident.kind == Kind.None) revert UnknownIdentity(id);
        if (msg.sender != ident.controller) revert NotController(id);
    }

    /// @dev Human or organization only. Agent identities fail closed.
    function _requireAuthorizer(bytes32 id) internal view returns (Identity storage ident) {
        ident = _requireController(id);
        if (ident.kind == Kind.Agent) revert AgentCannotAuthorize(id);
    }

    function _isAuthority(Kind kind) internal pure returns (bool) {
        return kind == Kind.Human || kind == Kind.Organization;
    }
}

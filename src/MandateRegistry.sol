// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {NotController, UnknownIdentity} from "./IdentityRegistry.sol";
import {UnknownResource} from "./ResourceRegistry.sol";
import {Kind} from "./Types.sol";
import {ResourceRegistry} from "./ResourceRegistry.sol";

error UnknownMandate(bytes32 id);
error MandateExpired(bytes32 id);
error MandateRevoked(bytes32 id);
error MandateMismatch(bytes32 id);
error ExpiryNotInFuture();
error EmptyScope();
error GrantorNotController(bytes32 resourceId, bytes32 grantorId);
error MandateWidened(bytes32 parentId);
error NotMandateHolder(bytes32 parentId, bytes32 grantorId);
error MandateChainTooDeep();

/// @notice Explicit bounded authority. One grantee, one action, one resource, one expiry.
/// @dev A mandate may only narrow authority. A root grant is the resource controller
///      cutting one (who, action, resource, expiry) out of their control of that resource.
///      A further grant may not exceed its parent's action, resource, or expiry.
///      An agent identity cannot grant. Mandates are reusable until expiry or revocation.
///      Revocation is not retroactive. A revoked or expired ancestor blocks new uses of a child.
contract MandateRegistry is ResourceRegistry {
    struct Mandate {
        bytes32 grantorId;
        bytes32 granteeId;
        bytes32 actionId;
        bytes32 resourceId;
        uint64 expiry;
        bool revoked;
        bytes32 parentId;
    }

    mapping(bytes32 => Mandate) internal _mandates;
    uint256 internal _mandateNonce;

    event MandateGranted(
        bytes32 indexed id,
        bytes32 indexed grantorId,
        bytes32 indexed granteeId,
        bytes32 actionId,
        bytes32 resourceId,
        uint64 expiry
    );
    event MandateRevocation(bytes32 indexed id, bytes32 indexed grantorId);

    function grantMandate(
        bytes32 grantorId,
        bytes32 granteeId,
        bytes32 actionId,
        bytes32 resourceId,
        uint64 expiry
    ) external returns (bytes32 id) {
        _requireAuthorizer(grantorId);
        if (actionId == bytes32(0)) revert EmptyScope();
        if (expiry <= block.timestamp) revert ExpiryNotInFuture();

        Resource storage resource = _resources[resourceId];
        if (!resource.exists) revert UnknownResource(resourceId);
        if (resource.controllerId != grantorId) revert GrantorNotController(resourceId, grantorId);
        if (_identities[granteeId].kind == Kind.None) revert UnknownIdentity(granteeId);

        id = keccak256(
            abi.encode(
                "MERIDIAN_MANDATE_V0",
                grantorId,
                granteeId,
                actionId,
                resourceId,
                expiry,
                _mandateNonce
            )
        );
        _mandateNonce += 1;

        _mandates[id] = Mandate({
            grantorId: grantorId,
            granteeId: granteeId,
            actionId: actionId,
            resourceId: resourceId,
            expiry: expiry,
            revoked: false,
            parentId: bytes32(0)
        });
        emit MandateGranted(id, grantorId, granteeId, actionId, resourceId, expiry);
    }

    /// @notice Pass a live mandate to another grantee without exceeding it.
    ///         A later expiry, a different action, or a different resource reverts.
    function delegateMandate(
        bytes32 parentId,
        bytes32 grantorId,
        bytes32 granteeId,
        bytes32 actionId,
        bytes32 resourceId,
        uint64 expiry
    ) external returns (bytes32 id) {
        _requireAuthorizer(grantorId);
        if (actionId == bytes32(0)) revert EmptyScope();
        if (expiry <= block.timestamp) revert ExpiryNotInFuture();
        if (_identities[granteeId].kind == Kind.None) revert UnknownIdentity(granteeId);

        _requireLiveChain(parentId);
        Mandate storage parent = _mandates[parentId];
        if (parent.granteeId != grantorId) revert NotMandateHolder(parentId, grantorId);
        if (
            actionId != parent.actionId || resourceId != parent.resourceId || expiry > parent.expiry
        ) {
            revert MandateWidened(parentId);
        }

        id = keccak256(
            abi.encode(
                "MERIDIAN_MANDATE_V0",
                grantorId,
                granteeId,
                actionId,
                resourceId,
                expiry,
                parentId,
                _mandateNonce
            )
        );
        _mandateNonce += 1;

        _mandates[id] = Mandate({
            grantorId: grantorId,
            granteeId: granteeId,
            actionId: actionId,
            resourceId: resourceId,
            expiry: expiry,
            revoked: false,
            parentId: parentId
        });
        emit MandateGranted(id, grantorId, granteeId, actionId, resourceId, expiry);
    }

    function revokeMandate(bytes32 mandateId) external {
        Mandate storage mandate = _mandates[mandateId];
        if (mandate.grantorId == bytes32(0)) revert UnknownMandate(mandateId);
        _requireAuthorizer(mandate.grantorId);
        mandate.revoked = true;
        emit MandateRevocation(mandateId, mandate.grantorId);
    }

    function readMandate(bytes32 mandateId) external view returns (Mandate memory) {
        Mandate storage mandate = _mandates[mandateId];
        if (mandate.grantorId == bytes32(0)) revert UnknownMandate(mandateId);
        return mandate;
    }

    /// @dev Caller must be the grantee controller. Fields must match exactly.
    ///      Every ancestor must still be live. A child cannot outlive a narrower parent.
    function _useMandate(bytes32 mandateId, bytes32 actorId, bytes32 actionId, bytes32 resourceId)
        internal
        view
    {
        _requireLiveChain(mandateId);
        Mandate storage mandate = _mandates[mandateId];
        if (
            mandate.granteeId != actorId || mandate.actionId != actionId
                || mandate.resourceId != resourceId
        ) {
            revert MandateMismatch(mandateId);
        }
        if (msg.sender != _identities[actorId].controller) revert NotController(actorId);
    }

    function _requireLiveChain(bytes32 mandateId) internal view {
        bytes32 cursor = mandateId;
        for (uint256 depth = 0; depth < 16; depth++) {
            Mandate storage mandate = _mandates[cursor];
            if (mandate.grantorId == bytes32(0)) revert UnknownMandate(cursor);
            if (mandate.revoked) revert MandateRevoked(cursor);
            if (block.timestamp >= mandate.expiry) revert MandateExpired(cursor);
            if (mandate.parentId == bytes32(0)) return;
            cursor = mandate.parentId;
        }
        revert MandateChainTooDeep();
    }
}

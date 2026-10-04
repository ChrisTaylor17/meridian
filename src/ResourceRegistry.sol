// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IdentityRegistry} from "./IdentityRegistry.sol";

error ResourceExists(bytes32 id);
error UnknownResource(bytes32 id);
error ResolverMustBeAuthority(bytes32 resolverId);

/// @notice A resource is the object a mandate can name. The resolver is fixed at creation.
/// @dev There is no setter for the resolver. Swapping a resolver after a challenge is out of v0.
contract ResourceRegistry is IdentityRegistry {
    struct Resource {
        bytes32 controllerId;
        bytes32 resolverId;
        bytes32 stateHash;
        /// @notice Mock stable-asset figure. Not a token, not transferable, not a supply.
        uint256 mockStableNote;
        bool exists;
    }

    mapping(bytes32 => Resource) internal _resources;

    event ResourceRegistered(bytes32 indexed id, bytes32 indexed controllerId, bytes32 resolverId);

    function computeResourceId(bytes32 controllerId, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode("MERIDIAN_RESOURCE_V0", controllerId, salt));
    }

    function registerResource(bytes32 controllerId, bytes32 salt, bytes32 resolverId)
        external
        returns (bytes32 resourceId)
    {
        _requireAuthorizer(controllerId);
        if (!_isAuthority(_identities[resolverId].kind)) {
            revert ResolverMustBeAuthority(resolverId);
        }

        resourceId = computeResourceId(controllerId, salt);
        if (_resources[resourceId].exists) revert ResourceExists(resourceId);

        _resources[resourceId] = Resource({
            controllerId: controllerId,
            resolverId: resolverId,
            stateHash: bytes32(0),
            mockStableNote: 0,
            exists: true
        });
        emit ResourceRegistered(resourceId, controllerId, resolverId);
    }

    function readResource(bytes32 resourceId) external view returns (Resource memory) {
        Resource storage resource = _resources[resourceId];
        if (!resource.exists) revert UnknownResource(resourceId);
        return resource;
    }
}

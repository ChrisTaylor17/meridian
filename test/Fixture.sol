// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Actions} from "../src/Actions.sol";
import {Meridian} from "../src/Meridian.sol";
import {LocalSafetyLimit} from "../src/LocalSafetyLimit.sol";
import {EvidenceStatus, Kind} from "../src/Types.sol";

abstract contract Fixture is Test {
    Meridian internal meridian;
    LocalSafetyLimit internal safety;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal orgKey = makeAddr("org");
    address internal agentKey = makeAddr("agent");
    address internal local = makeAddr("local");
    address internal stranger = makeAddr("stranger");

    bytes32 internal aliceId;
    bytes32 internal bobId;
    bytes32 internal orgId;
    bytes32 internal agentId;
    bytes32 internal resourceId;

    bytes32 internal constant ALICE_SALT = bytes32("alice");
    bytes32 internal constant BOB_SALT = bytes32("bob");
    bytes32 internal constant ORG_SALT = bytes32("org");
    bytes32 internal constant AGENT_SALT = bytes32("agent");
    bytes32 internal constant RESOURCE_SALT = bytes32("resource");

    function setUp() public virtual {
        meridian = new Meridian();
        safety = new LocalSafetyLimit(local, 100);

        vm.prank(alice);
        aliceId = meridian.registerHuman(ALICE_SALT);
        vm.prank(bob);
        bobId = meridian.registerHuman(BOB_SALT);
        vm.prank(orgKey);
        orgId = meridian.registerOrganization(ORG_SALT);
        vm.prank(alice);
        agentId = meridian.registerAgent(aliceId, agentKey, AGENT_SALT);
        vm.prank(alice);
        resourceId = meridian.registerResource(aliceId, RESOURCE_SALT, bobId);
    }

    function _window() internal view returns (uint64) {
        return meridian.MIN_CHALLENGE_WINDOW();
    }

    function _expiry() internal view returns (uint64) {
        return uint64(block.timestamp + 7 days);
    }

    function _grant(
        address key,
        bytes32 grantorId,
        bytes32 granteeId,
        bytes32 actionId,
        bytes32 resource
    ) internal returns (bytes32 mandateId) {
        uint64 expiry = _expiry();
        vm.prank(key);
        mandateId = meridian.grantMandate(grantorId, granteeId, actionId, resource, expiry);
    }

    function _submit(
        address key,
        bytes32 actorId,
        bytes32 mandateId,
        bytes32 actionId,
        bytes32 claimHash,
        uint256 units
    ) internal returns (bytes32 evidenceId) {
        uint64 window = _window();
        vm.prank(key);
        evidenceId = meridian.submitAttestation(
            actorId, mandateId, resourceId, actionId, claimHash, units, window, window
        );
    }

    function _finalizeAfterChallenge(bytes32 evidenceId) internal {
        Meridian.Attestation memory attestation = meridian.readAttestation(evidenceId);
        vm.warp(attestation.challengeDeadline);
        meridian.finalize(evidenceId);
    }
}

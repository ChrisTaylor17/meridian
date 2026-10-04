// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actions} from "../src/Actions.sol";
import {
    AgentCannotAuthorize,
    IdentityExists,
    NotController,
    SponsorMustBeAuthority,
    ZeroController
} from "../src/IdentityRegistry.sol";
import {Meridian} from "../src/Meridian.sol";
import {Kind} from "../src/Types.sol";
import {Fixture} from "./Fixture.sol";

contract IdentityTest is Fixture {
    function test_registersHumanOrganizationAndAgent() public view {
        (Kind aliceKind, address aliceController, bytes32 aliceSponsor) =
            meridian.readIdentity(aliceId);
        (Kind orgKind, address orgController, bytes32 orgSponsor) = meridian.readIdentity(orgId);
        (Kind agentKind, address agentController, bytes32 agentSponsor) =
            meridian.readIdentity(agentId);

        assertEq(uint8(aliceKind), uint8(Kind.Human));
        assertEq(aliceController, alice);
        assertEq(aliceSponsor, bytes32(0));

        assertEq(uint8(orgKind), uint8(Kind.Organization));
        assertEq(orgController, orgKey);
        assertEq(orgSponsor, bytes32(0));

        assertEq(uint8(agentKind), uint8(Kind.Agent));
        assertEq(agentController, agentKey);
        assertEq(agentSponsor, aliceId);
    }

    function test_idsArePortablePreimagesNotAddresses() public view {
        bytes32 human =
            keccak256(abi.encode("MERIDIAN_ID_V0", Kind.Human, alice, bytes32(0), ALICE_SALT));
        bytes32 organization = keccak256(
            abi.encode("MERIDIAN_ID_V0", Kind.Organization, orgKey, bytes32(0), ORG_SALT)
        );
        bytes32 agent =
            keccak256(abi.encode("MERIDIAN_ID_V0", Kind.Agent, agentKey, aliceId, AGENT_SALT));

        assertEq(aliceId, human);
        assertEq(orgId, organization);
        assertEq(agentId, agent);
        assertEq(aliceId, meridian.computeId(Kind.Human, alice, bytes32(0), ALICE_SALT));

        assertTrue(aliceId != bytes32(uint256(uint160(alice))));
        assertTrue(orgId != bytes32(uint256(uint160(orgKey))));
        assertTrue(agentId != bytes32(uint256(uint160(agentKey))));
        assertTrue(agentId != aliceId);
    }

    function test_duplicateSaltReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IdentityExists.selector, aliceId));
        meridian.registerHuman(ALICE_SALT);
    }

    function test_strangerCannotRegisterAnAgentForAlice() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotController.selector, aliceId));
        meridian.registerAgent(aliceId, stranger, bytes32("nope"));
    }

    function test_agentCannotSponsorAnotherAgent() public {
        vm.prank(agentKey);
        vm.expectRevert(abi.encodeWithSelector(SponsorMustBeAuthority.selector, agentId));
        meridian.registerAgent(agentId, makeAddr("sub"), bytes32("sub"));
    }

    function test_zeroAgentControllerReverts() public {
        vm.prank(alice);
        vm.expectRevert(ZeroController.selector);
        meridian.registerAgent(aliceId, address(0), bytes32("zero"));
    }

    function test_organizationCanGrantAMandateToAHuman() public {
        vm.prank(orgKey);
        bytes32 orgResource = meridian.registerResource(orgId, bytes32("org-res"), bobId);
        bytes32 mandateId = _grant(orgKey, orgId, aliceId, Actions.SET_STATE, orgResource);

        Meridian.Mandate memory mandate = meridian.readMandate(mandateId);
        assertEq(mandate.grantorId, orgId);
        assertEq(mandate.granteeId, aliceId);
        assertEq(mandate.actionId, Actions.SET_STATE);
        assertEq(mandate.resourceId, orgResource);
        assertGt(uint256(mandate.expiry), block.timestamp);
        assertFalse(mandate.revoked);

        uint64 window = _window();
        vm.prank(alice);
        bytes32 evidenceId = meridian.submitAttestation(
            aliceId,
            mandateId,
            orgResource,
            Actions.SET_STATE,
            keccak256("org-act"),
            0,
            window,
            window
        );
        assertEq(meridian.readAttestation(evidenceId).attesterId, aliceId);
    }

    /// @dev Kind is self-asserted. Blocking Agent ids does not prove the key is a human.
    function test_gap_agentKeyCanRegisterASeparateHumanIdentity() public {
        vm.prank(agentKey);
        bytes32 other = meridian.registerHuman(bytes32("not-proof"));
        (Kind kind, address controller, bytes32 sponsor) = meridian.readIdentity(other);
        assertEq(uint8(kind), uint8(Kind.Human));
        assertEq(controller, agentKey);
        assertEq(sponsor, bytes32(0));
        assertTrue(other != agentId);

        vm.prank(agentKey);
        bytes32 owned = meridian.registerResource(other, bytes32("gap-resource"), other);
        assertTrue(owned != bytes32(0));

        vm.prank(agentKey);
        vm.expectRevert(abi.encodeWithSelector(AgentCannotAuthorize.selector, agentId));
        meridian.grantMandate(agentId, agentId, Actions.SET_STATE, resourceId, _expiry());
    }
}

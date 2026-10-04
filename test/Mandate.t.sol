// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actions} from "../src/Actions.sol";
import {AgentCannotAuthorize, NotController, UnknownIdentity} from "../src/IdentityRegistry.sol";
import {
    EmptyScope,
    ExpiryNotInFuture,
    GrantorNotController,
    MandateMismatch,
    MandateRevoked,
    MandateWidened,
    NotMandateHolder
} from "../src/MandateRegistry.sol";
import {Meridian} from "../src/Meridian.sol";
import {EvidenceStatus} from "../src/Types.sol";
import {Fixture} from "./Fixture.sol";

contract MandateTest is Fixture {
    function test_actionOutsideMandateFails() public {
        bytes32 mandateId = _grant(alice, aliceId, agentId, Actions.SET_STATE, resourceId);
        uint64 window = _window();

        vm.prank(agentKey);
        vm.expectRevert(abi.encodeWithSelector(MandateMismatch.selector, mandateId));
        meridian.submitAttestation(
            agentId,
            mandateId,
            resourceId,
            Actions.NOTE_BALANCE,
            keccak256("wrong-action"),
            1,
            window,
            window
        );

        vm.prank(alice);
        bytes32 other = meridian.registerResource(aliceId, bytes32("other"), bobId);
        vm.prank(agentKey);
        vm.expectRevert(abi.encodeWithSelector(MandateMismatch.selector, mandateId));
        meridian.submitAttestation(
            agentId,
            mandateId,
            other,
            Actions.SET_STATE,
            keccak256("wrong-resource"),
            0,
            window,
            window
        );

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MandateMismatch.selector, mandateId));
        meridian.submitAttestation(
            aliceId,
            mandateId,
            resourceId,
            Actions.SET_STATE,
            keccak256("wrong-grantee"),
            0,
            window,
            window
        );
    }

    function test_agentInsideMandateCanSubmit() public {
        bytes32 mandateId = _grant(alice, aliceId, agentId, Actions.SET_STATE, resourceId);
        bytes32 evidenceId =
            _submit(agentKey, agentId, mandateId, Actions.SET_STATE, keccak256("in-bounds"), 0);
        assertEq(uint8(meridian.readAttestation(evidenceId).status), uint8(EvidenceStatus.Pending));
    }

    function test_onlyResourceControllerCanGrant() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(GrantorNotController.selector, resourceId, bobId));
        meridian.grantMandate(bobId, agentId, Actions.SET_STATE, resourceId, _expiry());
    }

    function test_agentCannotRevoke() public {
        bytes32 mandateId = _grant(alice, aliceId, agentId, Actions.SET_STATE, resourceId);
        vm.prank(agentKey);
        vm.expectRevert(abi.encodeWithSelector(NotController.selector, aliceId));
        meridian.revokeMandate(mandateId);
    }

    function test_unknownGranteeReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UnknownIdentity.selector, bytes32("missing")));
        meridian.grantMandate(aliceId, bytes32("missing"), Actions.SET_STATE, resourceId, _expiry());
    }

    function test_emptyActionReverts() public {
        vm.prank(alice);
        vm.expectRevert(EmptyScope.selector);
        meridian.grantMandate(aliceId, agentId, bytes32(0), resourceId, _expiry());
    }

    function test_expiryMustBeInTheFuture() public {
        vm.prank(alice);
        vm.expectRevert(ExpiryNotInFuture.selector);
        meridian.grantMandate(
            aliceId, agentId, Actions.SET_STATE, resourceId, uint64(block.timestamp)
        );
    }

    function test_mandateIsReusableUntilExpiry() public {
        bytes32 mandateId = _grant(alice, aliceId, agentId, Actions.SET_STATE, resourceId);
        _submit(agentKey, agentId, mandateId, Actions.SET_STATE, keccak256("one"), 0);
        _submit(agentKey, agentId, mandateId, Actions.SET_STATE, keccak256("two"), 0);
        assertEq(meridian.attestationCount(), 2);
    }

    function test_delegationCanOnlyNarrow() public {
        address carol = makeAddr("carol");
        vm.prank(carol);
        bytes32 carolId = meridian.registerHuman(bytes32("carol"));

        uint64 expiry = uint64(block.timestamp + 7 days);
        vm.prank(alice);
        bytes32 parent =
            meridian.grantMandate(aliceId, carolId, Actions.SET_STATE, resourceId, expiry);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(MandateWidened.selector, parent));
        meridian.delegateMandate(
            parent, carolId, agentId, Actions.SET_STATE, resourceId, expiry + 1
        );

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(MandateWidened.selector, parent));
        meridian.delegateMandate(parent, carolId, agentId, Actions.NOTE_BALANCE, resourceId, expiry);

        vm.prank(alice);
        bytes32 other = meridian.registerResource(aliceId, bytes32("other-narrow"), bobId);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(MandateWidened.selector, parent));
        meridian.delegateMandate(parent, carolId, agentId, Actions.SET_STATE, other, expiry);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NotMandateHolder.selector, parent, aliceId));
        meridian.delegateMandate(parent, aliceId, agentId, Actions.SET_STATE, resourceId, expiry);

        vm.prank(alice);
        bytes32 agentParent =
            meridian.grantMandate(aliceId, agentId, Actions.SET_STATE, resourceId, expiry);
        vm.prank(agentKey);
        vm.expectRevert(abi.encodeWithSelector(AgentCannotAuthorize.selector, agentId));
        meridian.delegateMandate(
            agentParent, agentId, carolId, Actions.SET_STATE, resourceId, expiry
        );

        uint64 window = _window();
        vm.prank(carol);
        bytes32 child = meridian.delegateMandate(
            parent, carolId, agentId, Actions.SET_STATE, resourceId, expiry - 1
        );
        Meridian.Mandate memory narrowed = meridian.readMandate(child);
        assertEq(narrowed.parentId, parent);
        assertEq(narrowed.granteeId, agentId);
        assertEq(narrowed.actionId, Actions.SET_STATE);
        assertEq(narrowed.resourceId, resourceId);
        assertEq(uint256(narrowed.expiry), uint256(expiry - 1));

        vm.prank(agentKey);
        meridian.submitAttestation(
            agentId, child, resourceId, Actions.SET_STATE, keccak256("narrowed"), 0, window, window
        );

        vm.prank(alice);
        meridian.revokeMandate(parent);
        vm.prank(agentKey);
        vm.expectRevert(abi.encodeWithSelector(MandateRevoked.selector, parent));
        meridian.submitAttestation(
            agentId,
            child,
            resourceId,
            Actions.SET_STATE,
            keccak256("parent-dead"),
            0,
            window,
            window
        );
    }

    /// @dev Revocation stops new uses. It does not delete an attestation already submitted.
    function test_gap_revocationIsNotRetroactive() public {
        bytes32 mandateId = _grant(alice, aliceId, agentId, Actions.SET_STATE, resourceId);
        bytes32 evidenceId =
            _submit(agentKey, agentId, mandateId, Actions.SET_STATE, keccak256("already-in"), 0);

        vm.prank(alice);
        meridian.revokeMandate(mandateId);
        assertTrue(meridian.readMandate(mandateId).revoked);

        _finalizeAfterChallenge(evidenceId);
        assertEq(uint8(meridian.readAttestation(evidenceId).status), uint8(EvidenceStatus.Final));

        uint64 window = _window();
        vm.prank(agentKey);
        vm.expectRevert(abi.encodeWithSelector(MandateRevoked.selector, mandateId));
        meridian.submitAttestation(
            agentId,
            mandateId,
            resourceId,
            Actions.SET_STATE,
            keccak256("after-revoke"),
            0,
            window,
            window
        );
    }
}

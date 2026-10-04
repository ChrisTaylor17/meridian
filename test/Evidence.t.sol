// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actions} from "../src/Actions.sol";
import {
    EmptyClaim,
    EvidenceClosed,
    EvidenceNotPending,
    EvidenceNotReady,
    InvalidReason,
    NotResolver,
    ProbabilisticOutputRejected,
    ResolverIsAttester,
    UnitsNotAllowed,
    WindowOutOfRange
} from "../src/EvidenceRegistry.sol";
import {NotController} from "../src/IdentityRegistry.sol";
import {UnknownMandate} from "../src/MandateRegistry.sol";
import {EvidenceNotFinal, Meridian} from "../src/Meridian.sol";
import {ResolverMustBeAuthority} from "../src/ResourceRegistry.sol";
import {EvidenceStatus} from "../src/Types.sol";
import {Fixture} from "./Fixture.sol";

contract EvidenceTest is Fixture {
    bytes32 internal mandateId;

    function setUp() public override {
        super.setUp();
        mandateId = _grant(alice, aliceId, agentId, Actions.SET_STATE, resourceId);
    }

    function test_pendingAttestationIsNotFinal() public {
        bytes32 evidenceId =
            _submit(agentKey, agentId, mandateId, Actions.SET_STATE, keccak256("pending"), 0);
        assertEq(uint8(meridian.readAttestation(evidenceId).status), uint8(EvidenceStatus.Pending));
        vm.expectRevert(abi.encodeWithSelector(EvidenceNotReady.selector, evidenceId));
        meridian.finalize(evidenceId);
    }

    function test_controllerCanChallengeAndResolverCanUpholdOrReject() public {
        bytes32 first =
            _submit(agentKey, agentId, mandateId, Actions.SET_STATE, keccak256("uphold"), 0);
        vm.prank(alice);
        meridian.challenge(aliceId, first, bytes32(0), Actions.REASON_CONTRADICTION);
        assertEq(meridian.readAttestation(first).challengeReason, Actions.REASON_CONTRADICTION);

        vm.prank(bob);
        meridian.resolveChallenge(first, true);
        assertEq(uint8(meridian.readAttestation(first).status), uint8(EvidenceStatus.Final));

        bytes32 second =
            _submit(agentKey, agentId, mandateId, Actions.SET_STATE, keccak256("reject"), 0);
        vm.prank(alice);
        meridian.challenge(aliceId, second, bytes32(0), Actions.REASON_SUPERSEDED);
        vm.prank(bob);
        meridian.resolveChallenge(second, false);
        assertEq(uint8(meridian.readAttestation(second).status), uint8(EvidenceStatus.Rejected));
    }

    function test_mandatedChallengerCanChallenge() public {
        bytes32 challengeMandate = _grant(alice, aliceId, agentId, Actions.CHALLENGE, resourceId);
        bytes32 evidenceId =
            _submit(agentKey, agentId, mandateId, Actions.SET_STATE, keccak256("watched"), 0);

        vm.prank(agentKey);
        meridian.challenge(agentId, evidenceId, challengeMandate, Actions.REASON_OUT_OF_MANDATE);
        assertEq(
            uint8(meridian.readAttestation(evidenceId).status), uint8(EvidenceStatus.Challenged)
        );
    }

    function test_strangerCannotChallenge() public {
        bytes32 evidenceId =
            _submit(agentKey, agentId, mandateId, Actions.SET_STATE, keccak256("closed"), 0);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotController.selector, aliceId));
        meridian.challenge(aliceId, evidenceId, bytes32(0), Actions.REASON_CONTRADICTION);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(UnknownMandate.selector, bytes32(0)));
        meridian.challenge(strangerId(), evidenceId, bytes32(0), Actions.REASON_CONTRADICTION);
    }

    function test_challengeClosesAtTheDeadline() public {
        bytes32 evidenceId =
            _submit(agentKey, agentId, mandateId, Actions.SET_STATE, keccak256("clock"), 0);
        uint64 deadline = meridian.readAttestation(evidenceId).challengeDeadline;

        vm.warp(deadline - 1);
        vm.prank(alice);
        meridian.challenge(aliceId, evidenceId, bytes32(0), Actions.REASON_CONTRADICTION);
        assertEq(
            uint8(meridian.readAttestation(evidenceId).status), uint8(EvidenceStatus.Challenged)
        );

        bytes32 later =
            _submit(agentKey, agentId, mandateId, Actions.SET_STATE, keccak256("clock-2"), 0);
        vm.warp(meridian.readAttestation(later).challengeDeadline);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EvidenceClosed.selector, later));
        meridian.challenge(aliceId, later, bytes32(0), Actions.REASON_CONTRADICTION);
    }

    function test_windowsMustSitInsideTheBounds() public {
        uint64 minW = _window();
        uint64 maxW = meridian.MAX_CHALLENGE_WINDOW();

        vm.prank(agentKey);
        vm.expectRevert(WindowOutOfRange.selector);
        meridian.submitAttestation(
            agentId, mandateId, resourceId, Actions.SET_STATE, keccak256("short"), 0, minW - 1, minW
        );

        vm.prank(agentKey);
        vm.expectRevert(WindowOutOfRange.selector);
        meridian.submitAttestation(
            agentId,
            mandateId,
            resourceId,
            Actions.SET_STATE,
            keccak256("short-r"),
            0,
            minW,
            minW - 1
        );

        vm.prank(agentKey);
        vm.expectRevert(WindowOutOfRange.selector);
        meridian.submitAttestation(
            agentId, mandateId, resourceId, Actions.SET_STATE, keccak256("long"), 0, maxW + 1, minW
        );

        vm.prank(agentKey);
        bytes32 evidenceId = meridian.submitAttestation(
            agentId, mandateId, resourceId, Actions.SET_STATE, keccak256("max"), 0, maxW, maxW
        );
        assertEq(uint8(meridian.readAttestation(evidenceId).status), uint8(EvidenceStatus.Pending));
    }

    function test_emptyClaimAndUnitsOnSetStateRevert() public {
        uint64 window = _window();
        vm.prank(agentKey);
        vm.expectRevert(EmptyClaim.selector);
        meridian.submitAttestation(
            agentId, mandateId, resourceId, Actions.SET_STATE, bytes32(0), 0, window, window
        );

        vm.prank(agentKey);
        vm.expectRevert(UnitsNotAllowed.selector);
        meridian.submitAttestation(
            agentId, mandateId, resourceId, Actions.SET_STATE, keccak256("units"), 5, window, window
        );
    }

    function test_invalidReasonAndDoubleChallengeRevert() public {
        bytes32 evidenceId =
            _submit(agentKey, agentId, mandateId, Actions.SET_STATE, keccak256("reason"), 0);
        vm.prank(alice);
        vm.expectRevert(InvalidReason.selector);
        meridian.challenge(aliceId, evidenceId, bytes32(0), 9);

        vm.prank(alice);
        meridian.challenge(aliceId, evidenceId, bytes32(0), Actions.REASON_CONTRADICTION);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EvidenceNotPending.selector, evidenceId));
        meridian.challenge(aliceId, evidenceId, bytes32(0), Actions.REASON_CONTRADICTION);
    }

    function test_strangerCannotResolveAndAttesterCannotResolveSelf() public {
        bytes32 evidenceId =
            _submit(agentKey, agentId, mandateId, Actions.SET_STATE, keccak256("resolve"), 0);
        vm.prank(alice);
        meridian.challenge(aliceId, evidenceId, bytes32(0), Actions.REASON_CONTRADICTION);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotResolver.selector, bobId));
        meridian.resolveChallenge(evidenceId, true);

        vm.prank(agentKey);
        vm.expectRevert(abi.encodeWithSelector(NotResolver.selector, bobId));
        meridian.resolveChallenge(evidenceId, true);

        vm.prank(alice);
        bytes32 selfResource = meridian.registerResource(aliceId, bytes32("self"), aliceId);
        bytes32 selfMandate = _grant(alice, aliceId, aliceId, Actions.SET_STATE, selfResource);
        uint64 window = _window();
        vm.prank(alice);
        bytes32 selfEvidence = meridian.submitAttestation(
            aliceId,
            selfMandate,
            selfResource,
            Actions.SET_STATE,
            keccak256("self"),
            0,
            window,
            window
        );
        vm.prank(alice);
        meridian.challenge(aliceId, selfEvidence, bytes32(0), Actions.REASON_CONTRADICTION);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ResolverIsAttester.selector, selfEvidence));
        meridian.resolveChallenge(selfEvidence, true);
    }

    function test_agentCannotBeNamedResolver() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ResolverMustBeAuthority.selector, agentId));
        meridian.registerResource(aliceId, bytes32("bad-resolver"), agentId);
    }

    function test_resolverIsFixed() public {
        (bool ok,) = address(meridian)
            .call(abi.encodeWithSignature("setResolver(bytes32,bytes32)", resourceId, aliceId));
        assertFalse(ok);
        assertEq(meridian.readResource(resourceId).resolverId, bobId);
    }

    function test_defaultRejectWhenChallengeIsUnresolved() public {
        bytes32 evidenceId =
            _submit(agentKey, agentId, mandateId, Actions.SET_STATE, keccak256("timeout"), 0);
        vm.prank(alice);
        meridian.challenge(aliceId, evidenceId, bytes32(0), Actions.REASON_CONTRADICTION);

        uint64 resolutionDeadline = meridian.readAttestation(evidenceId).resolutionDeadline;
        vm.warp(resolutionDeadline - 1);
        vm.expectRevert(abi.encodeWithSelector(EvidenceNotReady.selector, evidenceId));
        meridian.finalize(evidenceId);

        vm.warp(resolutionDeadline);
        meridian.finalize(evidenceId);
        assertEq(uint8(meridian.readAttestation(evidenceId).status), uint8(EvidenceStatus.Rejected));

        vm.expectRevert(abi.encodeWithSelector(EvidenceNotFinal.selector, evidenceId));
        meridian.commit(evidenceId);
    }

    function test_modelOutputCallRevertsAndWritesNothing() public {
        uint256 attestationsBefore = meridian.attestationCount();
        uint256 receiptsBefore = meridian.receiptCount();
        Meridian.Resource memory before = meridian.readResource(resourceId);

        vm.expectRevert(ProbabilisticOutputRejected.selector);
        meridian.submitModelOutput(hex"01020304", 999_999, keccak256("some-model"));

        assertEq(meridian.attestationCount(), attestationsBefore);
        assertEq(meridian.receiptCount(), receiptsBefore);
        Meridian.Resource memory later = meridian.readResource(resourceId);
        assertEq(later.stateHash, before.stateHash);
        assertEq(later.mockStableNote, before.mockStableNote);

        (bool ok,) =
            address(meridian).call(abi.encodeWithSignature("confidence(bytes32)", resourceId));
        assertFalse(ok);
    }

    /// @dev Finality here means the challenge window ended, not that the preimage was checked.
    function test_gap_unchallengedHashFinalizesWithoutAPreimage() public {
        bytes32 claim = keccak256("this preimage is never submitted");
        bytes32 evidenceId = _submit(agentKey, agentId, mandateId, Actions.SET_STATE, claim, 0);
        _finalizeAfterChallenge(evidenceId);
        Meridian.Attestation memory attestation = meridian.readAttestation(evidenceId);
        assertEq(uint8(attestation.status), uint8(EvidenceStatus.Final));
        assertEq(attestation.claimHash, claim);
    }

    function strangerId() internal pure returns (bytes32) {
        return bytes32("stranger-not-registered");
    }
}

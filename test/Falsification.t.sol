// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actions} from "../src/Actions.sol";
import {EvidenceNotReady, ProbabilisticOutputRejected} from "../src/EvidenceRegistry.sol";
import {AgentCannotAuthorize, NotController} from "../src/IdentityRegistry.sol";
import {MandateExpired, MandateMismatch, MandateRevoked} from "../src/MandateRegistry.sol";
import {EvidenceNotFinal, Meridian, UnknownReceipt} from "../src/Meridian.sol";
import {EvidenceStatus} from "../src/Types.sol";
import {Fixture} from "./Fixture.sol";
import {LocalSafetyLimit} from "../src/LocalSafetyLimit.sol";

/// @title Falsification tests for Meridian v0.1, Arm B
/// @notice Each test is one attack question from docs/FALSIFICATION.md.
///         A failure means the v0.1 rule, as implemented on the contract arm, is false.
contract FalsificationTest is Fixture {
    /// @notice Can an agent identity grant itself a mandate?
    function test_F01_agentCannotGrantItselfAMandate() public {
        vm.prank(agentKey);
        vm.expectRevert(abi.encodeWithSelector(AgentCannotAuthorize.selector, agentId));
        meridian.grantMandate(agentId, agentId, Actions.SET_STATE, resourceId, _expiry());

        vm.prank(agentKey);
        vm.expectRevert(abi.encodeWithSelector(AgentCannotAuthorize.selector, agentId));
        meridian.registerResource(agentId, bytes32("self-resource"), bobId);

        vm.prank(agentKey);
        vm.expectRevert(abi.encodeWithSelector(NotController.selector, aliceId));
        meridian.grantMandate(aliceId, agentId, Actions.SET_STATE, resourceId, _expiry());
    }

    /// @notice Can a grantee act in the block the mandate expires?
    function test_F02_expiredMandateCannotAct() public {
        uint64 expiry = uint64(block.timestamp + 1 hours);
        vm.prank(alice);
        bytes32 mandateId =
            meridian.grantMandate(aliceId, agentId, Actions.SET_STATE, resourceId, expiry);

        uint64 window = _window();
        vm.warp(expiry - 1);
        vm.prank(agentKey);
        bytes32 evidenceId = meridian.submitAttestation(
            agentId,
            mandateId,
            resourceId,
            Actions.SET_STATE,
            keccak256("still-valid"),
            0,
            window,
            window
        );
        assertEq(uint8(meridian.readAttestation(evidenceId).status), uint8(EvidenceStatus.Pending));

        vm.warp(expiry);
        vm.prank(agentKey);
        vm.expectRevert(abi.encodeWithSelector(MandateExpired.selector, mandateId));
        meridian.submitAttestation(
            agentId,
            mandateId,
            resourceId,
            Actions.SET_STATE,
            keccak256("expired"),
            0,
            window,
            window
        );
    }

    /// @notice Can a mandate for resource A authorize an action on resource B?
    function test_F03_mandateDoesNotCoverADifferentResource() public {
        vm.prank(alice);
        bytes32 other = meridian.registerResource(aliceId, bytes32("resource-b"), bobId);
        bytes32 mandateId = _grant(alice, aliceId, agentId, Actions.SET_STATE, resourceId);

        uint64 window = _window();
        vm.prank(agentKey);
        vm.expectRevert(abi.encodeWithSelector(MandateMismatch.selector, mandateId));
        meridian.submitAttestation(
            agentId,
            mandateId,
            other,
            Actions.SET_STATE,
            keccak256("other-resource"),
            0,
            window,
            window
        );
        assertEq(meridian.readResource(other).stateHash, bytes32(0));
    }

    /// @notice Can a confidence score or model blob be written into protocol state?
    function test_F04_modelConfidenceCannotBeStored() public {
        uint256 attestationsBefore = meridian.attestationCount();
        bytes32 beforeHash = meridian.readResource(resourceId).stateHash;

        vm.expectRevert(ProbabilisticOutputRejected.selector);
        meridian.submitModelOutput(hex"deadbeef", 8_500, keccak256("model-id"));

        assertEq(meridian.attestationCount(), attestationsBefore);
        assertEq(meridian.receiptCount(), 0);
        assertEq(meridian.readResource(resourceId).stateHash, beforeHash);
        assertEq(meridian.readResource(resourceId).mockStableNote, 0);

        (bool confidenceOk,) =
            address(meridian).call(abi.encodeWithSignature("confidence(bytes32)", resourceId));
        (bool scoreOk,) =
            address(meridian).call(abi.encodeWithSignature("modelScore(bytes32)", resourceId));
        assertFalse(confidenceOk);
        assertFalse(scoreOk);
    }

    /// @notice Can a challenged attestation become final before the resolver rules?
    function test_F05_challengedClaimDoesNotFinalizeBeforeResolution() public {
        bytes32 mandateId = _grant(alice, aliceId, agentId, Actions.SET_STATE, resourceId);
        bytes32 evidenceId =
            _submit(agentKey, agentId, mandateId, Actions.SET_STATE, keccak256("disputed"), 0);
        vm.prank(alice);
        meridian.challenge(aliceId, evidenceId, bytes32(0), Actions.REASON_CONTRADICTION);

        Meridian.Attestation memory attestation = meridian.readAttestation(evidenceId);
        vm.warp(attestation.challengeDeadline);
        vm.expectRevert(abi.encodeWithSelector(EvidenceNotReady.selector, evidenceId));
        meridian.finalize(evidenceId);

        vm.warp(attestation.resolutionDeadline - 1);
        vm.expectRevert(abi.encodeWithSelector(EvidenceNotReady.selector, evidenceId));
        meridian.finalize(evidenceId);
        vm.expectRevert(abi.encodeWithSelector(EvidenceNotFinal.selector, evidenceId));
        meridian.commit(evidenceId);

        assertEq(
            uint8(meridian.readAttestation(evidenceId).status), uint8(EvidenceStatus.Challenged)
        );
        assertEq(meridian.readResource(resourceId).stateHash, bytes32(0));
    }

    /// @notice If nobody resolves a challenge, does the claim become final anyway?
    function test_F06_unresolvedChallengeIsRejectedNotFinal() public {
        bytes32 mandateId = _grant(alice, aliceId, agentId, Actions.SET_STATE, resourceId);
        bytes32 evidenceId =
            _submit(agentKey, agentId, mandateId, Actions.SET_STATE, keccak256("unresolved"), 0);
        vm.prank(alice);
        meridian.challenge(aliceId, evidenceId, bytes32(0), Actions.REASON_OUT_OF_MANDATE);

        vm.warp(meridian.readAttestation(evidenceId).resolutionDeadline);
        meridian.finalize(evidenceId);

        assertEq(uint8(meridian.readAttestation(evidenceId).status), uint8(EvidenceStatus.Rejected));
        vm.expectRevert(abi.encodeWithSelector(EvidenceNotFinal.selector, evidenceId));
        meridian.commit(evidenceId);
        assertEq(meridian.receiptCount(), 0);
        assertEq(meridian.readResource(resourceId).stateHash, bytes32(0));
    }

    /// @notice Can a remote governance call set or loosen a local safety limit?
    function test_F07_remoteGovernanceCannotSetOrLoosenLocalSafetyLimit() public {
        uint256 beforeLimit = safety.limit();
        uint256 loosened = beforeLimit + 500;

        vm.expectRevert(
            abi.encodeWithSelector(
                LocalSafetyLimit.RemoteGovernanceRejected.selector, address(meridian), loosened
            )
        );
        meridian.attemptRemoteSafetyUpdate(safety, loosened);

        vm.prank(address(meridian));
        vm.expectRevert(
            abi.encodeWithSelector(LocalSafetyLimit.NotLocalAuthority.selector, address(meridian))
        );
        safety.setLocalLimit(beforeLimit - 1);

        address remote = makeAddr("remote-governance");
        vm.prank(remote);
        vm.expectRevert(
            abi.encodeWithSelector(
                LocalSafetyLimit.RemoteGovernanceRejected.selector, remote, loosened
            )
        );
        safety.applyRemoteDecision(loosened);

        assertEq(safety.limit(), beforeLimit);
    }

    /// @notice Can a stranger submit an attestation as someone else's identity?
    function test_F08_controllerKeyRequiredToAttestAsIdentity() public {
        bytes32 mandateId = _grant(alice, aliceId, agentId, Actions.SET_STATE, resourceId);

        uint64 window = _window();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotController.selector, agentId));
        meridian.submitAttestation(
            agentId,
            mandateId,
            resourceId,
            Actions.SET_STATE,
            keccak256("forged"),
            0,
            window,
            window
        );

        vm.prank(agentKey);
        vm.expectRevert(abi.encodeWithSelector(MandateMismatch.selector, mandateId));
        meridian.submitAttestation(
            aliceId,
            mandateId,
            resourceId,
            Actions.SET_STATE,
            keccak256("wrong-actor"),
            0,
            window,
            window
        );

        assertEq(meridian.attestationCount(), 0);
    }

    /// @notice Can a revoked mandate still authorize a new submission?
    function test_F09_revokedMandateCannotBeReused() public {
        bytes32 mandateId = _grant(alice, aliceId, agentId, Actions.SET_STATE, resourceId);
        vm.prank(alice);
        meridian.revokeMandate(mandateId);

        uint64 window = _window();
        vm.prank(agentKey);
        vm.expectRevert(abi.encodeWithSelector(MandateRevoked.selector, mandateId));
        meridian.submitAttestation(
            agentId,
            mandateId,
            resourceId,
            Actions.SET_STATE,
            keccak256("revoked"),
            0,
            window,
            window
        );
        assertEq(meridian.attestationCount(), 0);
    }

    /// @notice Can business state change without a final audit receipt?
    function test_F10_stateDoesNotChangeWithoutAFinalReceipt() public {
        bytes32 mandateId = _grant(alice, aliceId, agentId, Actions.NOTE_BALANCE, resourceId);
        bytes32 claim = keccak256("note-77");
        bytes32 evidenceId = _submit(agentKey, agentId, mandateId, Actions.NOTE_BALANCE, claim, 77);

        assertEq(meridian.readResource(resourceId).mockStableNote, 0);
        assertEq(meridian.readResource(resourceId).stateHash, bytes32(0));
        bytes32 missingReceipt = meridian.computeReceiptId(evidenceId);
        vm.expectRevert(abi.encodeWithSelector(UnknownReceipt.selector, missingReceipt));
        meridian.readReceipt(missingReceipt);

        vm.prank(alice);
        meridian.challenge(aliceId, evidenceId, bytes32(0), Actions.REASON_CONTRADICTION);
        vm.expectRevert(abi.encodeWithSelector(EvidenceNotFinal.selector, evidenceId));
        meridian.commit(evidenceId);

        vm.warp(meridian.readAttestation(evidenceId).resolutionDeadline);
        meridian.finalize(evidenceId);
        assertEq(uint8(meridian.readAttestation(evidenceId).status), uint8(EvidenceStatus.Rejected));
        vm.expectRevert(abi.encodeWithSelector(EvidenceNotFinal.selector, evidenceId));
        meridian.commit(evidenceId);
        assertEq(meridian.readResource(resourceId).mockStableNote, 0);
        assertEq(meridian.readResource(resourceId).stateHash, bytes32(0));
        assertEq(meridian.receiptCount(), 0);

        bytes32 accepted =
            _submit(agentKey, agentId, mandateId, Actions.NOTE_BALANCE, keccak256("ok"), 77);
        _finalizeAfterChallenge(accepted);
        assertEq(meridian.readResource(resourceId).mockStableNote, 0);

        bytes32 receiptId = meridian.commit(accepted);
        Meridian.Receipt memory receipt = meridian.readReceipt(receiptId);
        assertEq(receipt.mockStableNote, 77);
        assertEq(receipt.evidenceId, accepted);
        assertEq(meridian.readResource(resourceId).mockStableNote, 77);
        assertEq(meridian.readResource(resourceId).stateHash, receipt.newStateHash);
        assertEq(meridian.receiptCount(), 1);
    }
}

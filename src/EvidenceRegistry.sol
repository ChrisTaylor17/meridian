// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actions} from "./Actions.sol";
import {EvidenceStatus, Kind} from "./Types.sol";
import {MandateRegistry} from "./MandateRegistry.sol";

error ProbabilisticOutputRejected();
error WindowOutOfRange();
error EmptyClaim();
error ActionNotAttestable(bytes32 actionId);
error UnitsNotAllowed();
error UnknownEvidence(bytes32 id);
error InvalidReason();
error EvidenceNotPending(bytes32 id);
error NotChallenged(bytes32 id);
error NotResolver(bytes32 resolverId);
error ResolverIsAttester(bytes32 id);
error AgentCannotResolve(bytes32 resolverId);
error EvidenceNotReady(bytes32 id);
error EvidenceClosed(bytes32 id);

/// @notice Attestations are claims under a mandate. They are not facts until the rule below says so.
/// @dev Deterministic challenge rule (fail closed). No score is an input.
///      1. submit stores a claim hash. Status becomes Pending. The preimage is not stored.
///      2. Until challengeDeadline, the resource controller, or a holder of an exact
///         ACTION_CHALLENGE mandate on that resource, may challenge with reason code 1, 2, or 3.
///      3. A challenged attestation does not become Final because time passed.
///      4. The resource resolver, a Human or Organization that is not the attester, may
///         uphold (true) or reject (false). The verdict is a boolean.
///      5. If the resolution deadline passes with no verdict, finalize() sets Rejected.
///      6. If the challenge deadline passes with no challenge, finalize() sets Final.
///      7. Only Final evidence can be committed to business state. Rejected evidence cannot.
contract EvidenceRegistry is MandateRegistry {
    struct Attestation {
        bytes32 attesterId;
        bytes32 resourceId;
        bytes32 claimHash;
        bytes32 mandateId;
        bytes32 actionId;
        uint256 mockUnits;
        uint64 submittedAt;
        uint64 challengeDeadline;
        uint64 resolutionDeadline;
        uint64 decidedAt;
        EvidenceStatus status;
        uint8 challengeReason;
    }

    /// @dev Shortest window that still leaves time for a challenger. Zero is rejected.
    uint64 public constant MIN_CHALLENGE_WINDOW = 1 hours;
    uint64 public constant MAX_CHALLENGE_WINDOW = 30 days;
    uint64 public constant MIN_RESOLUTION_WINDOW = 1 hours;
    uint64 public constant MAX_RESOLUTION_WINDOW = 30 days;

    mapping(bytes32 => Attestation) internal _attestations;
    uint256 public attestationCount;

    event AttestationSubmitted(
        bytes32 indexed evidenceId,
        bytes32 indexed attesterId,
        bytes32 indexed resourceId,
        bytes32 claimHash,
        bytes32 actionId,
        uint64 challengeDeadline
    );
    event AttestationChallenged(
        bytes32 indexed evidenceId, bytes32 indexed challengerId, uint8 reason
    );
    event ChallengeResolved(bytes32 indexed evidenceId, bool uphold);
    event AttestationBecameFinal(bytes32 indexed evidenceId, bytes32 claimHash);
    event AttestationDefaultRejected(bytes32 indexed evidenceId, bytes32 claimHash);

    /// @notice Refuses model output. This function is pure: it cannot write storage.
    /// @dev A failed transaction may still show calldata to node operators. That calldata
    ///      is not protocol state and is not a finalized claim.
    function submitModelOutput(bytes calldata, uint256, bytes32) external pure {
        revert ProbabilisticOutputRejected();
    }

    function submitAttestation(
        bytes32 attesterId,
        bytes32 mandateId,
        bytes32 resourceId,
        bytes32 actionId,
        bytes32 claimHash,
        uint256 mockUnits,
        uint64 challengeWindow,
        uint64 resolutionWindow
    ) external returns (bytes32 evidenceId) {
        if (claimHash == bytes32(0)) revert EmptyClaim();
        if (actionId != Actions.SET_STATE && actionId != Actions.NOTE_BALANCE) {
            revert ActionNotAttestable(actionId);
        }
        if (actionId == Actions.SET_STATE && mockUnits != 0) revert UnitsNotAllowed();
        _checkWindows(challengeWindow, resolutionWindow);
        _useMandate(mandateId, attesterId, actionId, resourceId);

        uint64 submittedAt = uint64(block.timestamp);
        uint64 challengeDeadline = submittedAt + challengeWindow;
        uint64 resolutionDeadline = challengeDeadline + resolutionWindow;

        evidenceId = keccak256(
            abi.encode(
                "MERIDIAN_EVIDENCE_V0",
                attesterId,
                mandateId,
                resourceId,
                actionId,
                claimHash,
                mockUnits,
                attestationCount
            )
        );
        attestationCount += 1;

        _attestations[evidenceId] = Attestation({
            attesterId: attesterId,
            resourceId: resourceId,
            claimHash: claimHash,
            mandateId: mandateId,
            actionId: actionId,
            mockUnits: mockUnits,
            submittedAt: submittedAt,
            challengeDeadline: challengeDeadline,
            resolutionDeadline: resolutionDeadline,
            decidedAt: 0,
            status: EvidenceStatus.Pending,
            challengeReason: 0
        });

        emit AttestationSubmitted(
            evidenceId, attesterId, resourceId, claimHash, actionId, challengeDeadline
        );
    }

    function challenge(
        bytes32 challengerId,
        bytes32 evidenceId,
        bytes32 challengeMandateId,
        uint8 reason
    ) external {
        if (!_validReason(reason)) revert InvalidReason();
        Attestation storage attestation = _attestations[evidenceId];
        if (attestation.status == EvidenceStatus.None) revert UnknownEvidence(evidenceId);
        if (attestation.status != EvidenceStatus.Pending) revert EvidenceNotPending(evidenceId);
        if (block.timestamp >= attestation.challengeDeadline) revert EvidenceClosed(evidenceId);

        _requireChallenger(challengerId, attestation.resourceId, challengeMandateId);

        attestation.status = EvidenceStatus.Challenged;
        attestation.challengeReason = reason;
        emit AttestationChallenged(evidenceId, challengerId, reason);
    }

    /// @notice Boolean verdict from the designated resolver. Not a score.
    function resolveChallenge(bytes32 evidenceId, bool uphold) external {
        Attestation storage attestation = _attestations[evidenceId];
        if (attestation.status != EvidenceStatus.Challenged) revert NotChallenged(evidenceId);
        if (block.timestamp >= attestation.resolutionDeadline) revert EvidenceClosed(evidenceId);

        bytes32 resolverId = _resources[attestation.resourceId].resolverId;
        Identity storage resolver = _identities[resolverId];
        if (resolver.kind == Kind.Agent) revert AgentCannotResolve(resolverId);
        if (!_isAuthority(resolver.kind)) revert AgentCannotResolve(resolverId);
        if (msg.sender != resolver.controller) revert NotResolver(resolverId);
        if (resolverId == attestation.attesterId) revert ResolverIsAttester(evidenceId);

        attestation.decidedAt = uint64(block.timestamp);
        if (uphold) {
            attestation.status = EvidenceStatus.Final;
            emit ChallengeResolved(evidenceId, true);
            emit AttestationBecameFinal(evidenceId, attestation.claimHash);
        } else {
            attestation.status = EvidenceStatus.Rejected;
            emit ChallengeResolved(evidenceId, false);
        }
    }

    /// @notice Moves a Pending attestation to Final after the challenge window,
    ///         or a Challenged attestation to Rejected after the resolution window.
    function finalize(bytes32 evidenceId) external {
        Attestation storage attestation = _attestations[evidenceId];
        if (attestation.status == EvidenceStatus.Pending) {
            if (block.timestamp < attestation.challengeDeadline) {
                revert EvidenceNotReady(evidenceId);
            }
            attestation.status = EvidenceStatus.Final;
            attestation.decidedAt = uint64(block.timestamp);
            emit AttestationBecameFinal(evidenceId, attestation.claimHash);
            return;
        }
        if (attestation.status == EvidenceStatus.Challenged) {
            if (block.timestamp < attestation.resolutionDeadline) {
                revert EvidenceNotReady(evidenceId);
            }
            attestation.status = EvidenceStatus.Rejected;
            attestation.decidedAt = uint64(block.timestamp);
            emit AttestationDefaultRejected(evidenceId, attestation.claimHash);
            return;
        }
        if (attestation.status == EvidenceStatus.None) revert UnknownEvidence(evidenceId);
        revert EvidenceClosed(evidenceId);
    }

    function readAttestation(bytes32 evidenceId) external view returns (Attestation memory) {
        Attestation storage attestation = _attestations[evidenceId];
        if (attestation.status == EvidenceStatus.None) revert UnknownEvidence(evidenceId);
        return attestation;
    }

    function _requireChallenger(
        bytes32 challengerId,
        bytes32 resourceId,
        bytes32 challengeMandateId
    ) internal view {
        if (challengerId == _resources[resourceId].controllerId) {
            _requireController(challengerId);
            return;
        }
        _useMandate(challengeMandateId, challengerId, Actions.CHALLENGE, resourceId);
    }

    function _checkWindows(uint64 challengeWindow, uint64 resolutionWindow) internal pure {
        if (
            challengeWindow < MIN_CHALLENGE_WINDOW || challengeWindow > MAX_CHALLENGE_WINDOW
                || resolutionWindow < MIN_RESOLUTION_WINDOW
                || resolutionWindow > MAX_RESOLUTION_WINDOW
        ) {
            revert WindowOutOfRange();
        }
    }

    function _validReason(uint8 reason) internal pure returns (bool) {
        return reason == Actions.REASON_CONTRADICTION || reason == Actions.REASON_OUT_OF_MANDATE
            || reason == Actions.REASON_SUPERSEDED;
    }
}

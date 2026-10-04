// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actions} from "./Actions.sol";
import {EvidenceStatus} from "./Types.sol";
import {EvidenceRegistry} from "./EvidenceRegistry.sol";
import {LocalSafetyLimit} from "./LocalSafetyLimit.sol";

error EvidenceNotFinal(bytes32 evidenceId);
error AlreadyCommitted(bytes32 evidenceId);
error UnknownReceipt(bytes32 receiptId);
error EthRejected();

/// @title Meridian Arm B
/// @notice Contract arm of the v0.1 state machine. Local Anvil only.
///         AI reasons. The protocol authorizes. Evidence verifies. The chain finalizes.
///         Model output is not on-chain truth. This arm does not mint a token.
/// @dev Only a Final attestation can change resource state. The receipt and
///      `TransitionFinalized` are what a later auditor reads. This contract does not
///      store a safety limit. The only call it can make toward one always reverts.
contract Meridian is EvidenceRegistry {
    struct Receipt {
        bytes32 evidenceId;
        bytes32 mandateId;
        bytes32 actorId;
        bytes32 actionId;
        bytes32 resourceId;
        bytes32 claimHash;
        bytes32 priorStateHash;
        bytes32 newStateHash;
        uint256 mockStableNote;
        uint64 finalizedAt;
        uint64 blockNumber;
        address committer;
    }

    mapping(bytes32 => Receipt) internal _receipts;
    mapping(bytes32 => bytes32) public receiptByEvidence;
    uint256 public receiptCount;

    event TransitionFinalized(
        bytes32 indexed receiptId,
        bytes32 indexed evidenceId,
        bytes32 indexed resourceId,
        bytes32 actorId,
        bytes32 actionId,
        bytes32 claimHash,
        bytes32 priorStateHash,
        bytes32 newStateHash,
        uint256 mockStableNote,
        uint64 finalizedAt,
        uint64 blockNumber
    );

    function computeReceiptId(bytes32 evidenceId) public pure returns (bytes32) {
        return keccak256(abi.encode("MERIDIAN_RECEIPT_V0", evidenceId));
    }

    function previewStateHash(
        bytes32 prior,
        bytes32 evidenceId,
        bytes32 claimHash,
        bytes32 actionId,
        uint256 mockStableNote
    ) public pure returns (bytes32) {
        return keccak256(
            abi.encode("MERIDIAN_STATE_V0", prior, evidenceId, claimHash, actionId, mockStableNote)
        );
    }

    /// @notice Materialize a Final attestation as business state and an audit receipt.
    /// @dev Permissionless. Authority was checked at submit time. This function does not
    ///      take new claim contents, scores, or amounts.
    function commit(bytes32 evidenceId) external returns (bytes32 receiptId) {
        Attestation storage attestation = _attestations[evidenceId];
        if (attestation.status != EvidenceStatus.Final) revert EvidenceNotFinal(evidenceId);
        if (receiptByEvidence[evidenceId] != bytes32(0)) revert AlreadyCommitted(evidenceId);

        Resource storage resource = _resources[attestation.resourceId];
        bytes32 prior = resource.stateHash;
        uint256 note = resource.mockStableNote;
        if (attestation.actionId == Actions.NOTE_BALANCE) {
            note = attestation.mockUnits;
            resource.mockStableNote = note;
        }

        bytes32 next =
            previewStateHash(prior, evidenceId, attestation.claimHash, attestation.actionId, note);
        resource.stateHash = next;

        receiptId = computeReceiptId(evidenceId);
        uint64 nowTs = uint64(block.timestamp);
        uint64 blockNo = uint64(block.number);
        _receipts[receiptId] = Receipt({
            evidenceId: evidenceId,
            mandateId: attestation.mandateId,
            actorId: attestation.attesterId,
            actionId: attestation.actionId,
            resourceId: attestation.resourceId,
            claimHash: attestation.claimHash,
            priorStateHash: prior,
            newStateHash: next,
            mockStableNote: note,
            finalizedAt: nowTs,
            blockNumber: blockNo,
            committer: msg.sender
        });
        receiptByEvidence[evidenceId] = receiptId;
        receiptCount += 1;

        emit TransitionFinalized(
            receiptId,
            evidenceId,
            attestation.resourceId,
            attestation.attesterId,
            attestation.actionId,
            attestation.claimHash,
            prior,
            next,
            note,
            nowTs,
            blockNo
        );
    }

    function readReceipt(bytes32 receiptId) external view returns (Receipt memory) {
        Receipt storage receipt = _receipts[receiptId];
        if (receipt.evidenceId == bytes32(0)) revert UnknownReceipt(receiptId);
        return receipt;
    }

    /// @notice Remote governance stub. Forwards to a local safety contract, which rejects the call.
    ///         There is no path here that writes a local limit.
    function attemptRemoteSafetyUpdate(LocalSafetyLimit target, uint256 newLimit) external view {
        target.applyRemoteDecision(newLimit);
    }

    receive() external payable {
        revert EthRejected();
    }
}

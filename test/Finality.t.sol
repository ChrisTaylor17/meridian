// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actions} from "../src/Actions.sol";
import {AlreadyCommitted, EvidenceNotFinal, Meridian} from "../src/Meridian.sol";
import {EvidenceStatus} from "../src/Types.sol";
import {Fixture} from "./Fixture.sol";

contract FinalityTest is Fixture {
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

    function test_auditorCanReadFinalReceipt() public {
        bytes32 mandateId = _grant(alice, aliceId, agentId, Actions.SET_STATE, resourceId);
        bytes32 claim = keccak256("delivery-receipt");
        bytes32 evidenceId = _submit(agentKey, agentId, mandateId, Actions.SET_STATE, claim, 0);
        _finalizeAfterChallenge(evidenceId);

        vm.roll(42);
        uint64 ts = uint64(block.timestamp);
        bytes32 prior = bytes32(0);
        bytes32 next = meridian.previewStateHash(prior, evidenceId, claim, Actions.SET_STATE, 0);
        bytes32 receiptId = meridian.computeReceiptId(evidenceId);

        vm.expectEmit(true, true, true, true, address(meridian));
        emit TransitionFinalized(
            receiptId,
            evidenceId,
            resourceId,
            agentId,
            Actions.SET_STATE,
            claim,
            prior,
            next,
            0,
            ts,
            42
        );

        vm.prank(stranger);
        bytes32 returned = meridian.commit(evidenceId);

        assertEq(returned, receiptId);
        Meridian.Receipt memory receipt = meridian.readReceipt(receiptId);
        assertEq(receipt.evidenceId, evidenceId);
        assertEq(receipt.mandateId, mandateId);
        assertEq(receipt.actorId, agentId);
        assertEq(receipt.actionId, Actions.SET_STATE);
        assertEq(receipt.resourceId, resourceId);
        assertEq(receipt.claimHash, claim);
        assertEq(receipt.priorStateHash, prior);
        assertEq(receipt.newStateHash, next);
        assertEq(receipt.mockStableNote, 0);
        assertEq(uint256(receipt.finalizedAt), uint256(ts));
        assertEq(uint256(receipt.blockNumber), 42);
        assertEq(receipt.committer, stranger);
        assertEq(meridian.receiptByEvidence(evidenceId), receiptId);
        assertEq(meridian.readResource(resourceId).stateHash, next);
        assertEq(uint8(meridian.readAttestation(evidenceId).status), uint8(EvidenceStatus.Final));
    }

    function test_secondReceiptChainsThePriorStateHash() public {
        bytes32 mandateId = _grant(alice, aliceId, agentId, Actions.SET_STATE, resourceId);
        bytes32 firstClaim = keccak256("first");
        bytes32 firstEvidence =
            _submit(agentKey, agentId, mandateId, Actions.SET_STATE, firstClaim, 0);
        _finalizeAfterChallenge(firstEvidence);
        meridian.commit(firstEvidence);
        bytes32 firstHash = meridian.readResource(resourceId).stateHash;

        bytes32 secondClaim = keccak256("second");
        bytes32 secondEvidence =
            _submit(agentKey, agentId, mandateId, Actions.SET_STATE, secondClaim, 0);
        _finalizeAfterChallenge(secondEvidence);
        bytes32 receiptId = meridian.commit(secondEvidence);

        Meridian.Receipt memory receipt = meridian.readReceipt(receiptId);
        assertEq(receipt.priorStateHash, firstHash);
        assertEq(
            receipt.newStateHash,
            meridian.previewStateHash(firstHash, secondEvidence, secondClaim, Actions.SET_STATE, 0)
        );
        assertEq(meridian.readResource(resourceId).stateHash, receipt.newStateHash);
    }

    function test_commitRejectsPendingChallengedAndRejectedEvidence() public {
        bytes32 mandateId = _grant(alice, aliceId, agentId, Actions.SET_STATE, resourceId);

        bytes32 pending =
            _submit(agentKey, agentId, mandateId, Actions.SET_STATE, keccak256("pending"), 0);
        vm.expectRevert(abi.encodeWithSelector(EvidenceNotFinal.selector, pending));
        meridian.commit(pending);

        bytes32 challenged =
            _submit(agentKey, agentId, mandateId, Actions.SET_STATE, keccak256("challenged"), 0);
        vm.prank(alice);
        meridian.challenge(aliceId, challenged, bytes32(0), Actions.REASON_CONTRADICTION);
        vm.expectRevert(abi.encodeWithSelector(EvidenceNotFinal.selector, challenged));
        meridian.commit(challenged);

        vm.prank(bob);
        meridian.resolveChallenge(challenged, false);
        vm.expectRevert(abi.encodeWithSelector(EvidenceNotFinal.selector, challenged));
        meridian.commit(challenged);
        assertEq(meridian.readResource(resourceId).stateHash, bytes32(0));
    }

    function test_doubleCommitReverts() public {
        bytes32 mandateId = _grant(alice, aliceId, agentId, Actions.SET_STATE, resourceId);
        bytes32 evidenceId =
            _submit(agentKey, agentId, mandateId, Actions.SET_STATE, keccak256("once"), 0);
        _finalizeAfterChallenge(evidenceId);
        bytes32 receiptId = meridian.commit(evidenceId);
        vm.expectRevert(abi.encodeWithSelector(AlreadyCommitted.selector, evidenceId));
        meridian.commit(evidenceId);
        assertEq(meridian.receiptCount(), 1);
        assertEq(meridian.receiptByEvidence(evidenceId), receiptId);
    }

    function test_mockStableNoteUpdatesOnlyWhenANoteBalanceCommits() public {
        bytes32 noteMandate = _grant(alice, aliceId, agentId, Actions.NOTE_BALANCE, resourceId);
        bytes32 claim = keccak256("units-19");
        bytes32 evidenceId =
            _submit(agentKey, agentId, noteMandate, Actions.NOTE_BALANCE, claim, 19);
        assertEq(meridian.readResource(resourceId).mockStableNote, 0);

        _finalizeAfterChallenge(evidenceId);
        assertEq(meridian.readResource(resourceId).mockStableNote, 0);

        bytes32 receiptId = meridian.commit(evidenceId);
        assertEq(meridian.readReceipt(receiptId).mockStableNote, 19);
        assertEq(meridian.readResource(resourceId).mockStableNote, 19);

        bytes32 stateMandate = _grant(alice, aliceId, agentId, Actions.SET_STATE, resourceId);
        bytes32 stateClaim = keccak256("state-only");
        bytes32 stateEvidence =
            _submit(agentKey, agentId, stateMandate, Actions.SET_STATE, stateClaim, 0);
        _finalizeAfterChallenge(stateEvidence);
        meridian.commit(stateEvidence);
        assertEq(meridian.readResource(resourceId).mockStableNote, 19);
    }

    function test_noTokenSurfaceAndNoEther() public {
        string[7] memory names = [
            "totalSupply()",
            "mint(address,uint256)",
            "transfer(address,uint256)",
            "approve(address,uint256)",
            "balanceOf(address)",
            "sell(uint256)",
            "moduleId()"
        ];
        for (uint256 i = 0; i < names.length; i++) {
            (bool ok,) = address(meridian).call(abi.encodeWithSignature(names[i]));
            assertFalse(ok, names[i]);
        }
        (bool voteOk,) = address(meridian)
            .call(abi.encodeWithSignature("propose(bytes32,bytes32)", bytes32(0), bytes32(0)));
        assertFalse(voteOk);

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool paid,) = address(meridian).call{value: 1 ether}("");
        assertFalse(paid);
        assertEq(address(meridian).balance, 0);
    }
}

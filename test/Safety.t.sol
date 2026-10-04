// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./Fixture.sol";
import {LocalSafetyLimit} from "../src/LocalSafetyLimit.sol";

contract SafetyTest is Fixture {
    function test_remoteGovernanceCannotSetOrLoosenTheLocalLimit() public {
        uint256 current = safety.limit();
        uint256 loosened = current + 1000;
        uint256 tighter = current - 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                LocalSafetyLimit.RemoteGovernanceRejected.selector, address(meridian), loosened
            )
        );
        meridian.attemptRemoteSafetyUpdate(safety, loosened);
        assertEq(safety.limit(), current);

        address remote = makeAddr("remote-governance");
        vm.prank(remote);
        vm.expectRevert(
            abi.encodeWithSelector(
                LocalSafetyLimit.RemoteGovernanceRejected.selector, remote, tighter
            )
        );
        safety.applyRemoteDecision(tighter);
        assertEq(safety.limit(), current);

        vm.prank(address(meridian));
        vm.expectRevert(
            abi.encodeWithSelector(LocalSafetyLimit.NotLocalAuthority.selector, address(meridian))
        );
        safety.setLocalLimit(loosened);
        assertEq(safety.limit(), current);

        vm.prank(local);
        vm.expectRevert(
            abi.encodeWithSelector(
                LocalSafetyLimit.RemoteGovernanceRejected.selector, local, loosened
            )
        );
        safety.applyRemoteDecision(loosened);
        assertEq(safety.limit(), current);
        assertTrue(address(safety) != address(meridian));
        assertEq(safety.localAuthority(), local);
    }

    function test_localOperatorCanSetAndLoosenBecauseTheyAreOutOfBand() public {
        vm.prank(local);
        safety.setLocalLimit(40);
        assertEq(safety.limit(), 40);

        vm.prank(local);
        safety.setLocalLimit(90);
        assertEq(safety.limit(), 90);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(LocalSafetyLimit.NotLocalAuthority.selector, stranger)
        );
        safety.setLocalLimit(1);
        assertEq(safety.limit(), 90);
    }
}

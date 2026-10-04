// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LocalDeploy} from "../script/LocalDeploy.s.sol";

contract LocalChainTest is Test {
    function test_refusesSepoliaAndEveryNonAnvilChain() public {
        LocalDeploy deploy = new LocalDeploy();

        vm.expectRevert(
            abi.encodeWithSelector(LocalDeploy.RefusingNonLocalChain.selector, 11155111)
        );
        deploy.assertLocalAnvil(11155111);

        vm.expectRevert(abi.encodeWithSelector(LocalDeploy.RefusingNonLocalChain.selector, 1));
        deploy.assertLocalAnvil(1);

        deploy.assertLocalAnvil(31337);
    }
}

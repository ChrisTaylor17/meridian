// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Meridian} from "../src/Meridian.sol";
import {LocalSafetyLimit} from "../src/LocalSafetyLimit.sol";

/// @notice Deploys Arm B to local Anvil only (chain id 31337).
///         Refuses every other chain, including Sepolia (11155111).
///         Does not spend, mint a token, or start a consensus client.
contract LocalDeploy is Script {
    uint256 public constant LOCAL_ANVIL_CHAIN_ID = 31337;
    uint256 public constant SEPOLIA_CHAIN_ID = 11155111;

    error RefusingNonLocalChain(uint256 chainId);

    function assertLocalAnvil(uint256 chainId) public pure {
        if (chainId != LOCAL_ANVIL_CHAIN_ID) revert RefusingNonLocalChain(chainId);
    }

    function run() external {
        assertLocalAnvil(block.chainid);

        vm.startBroadcast();
        Meridian meridian = new Meridian();
        LocalSafetyLimit safety = new LocalSafetyLimit(msg.sender, 100);
        vm.stopBroadcast();

        console2.log("Meridian", address(meridian));
        console2.log("LocalSafetyLimit", address(safety));
        console2.log("chainId", block.chainid);
    }
}

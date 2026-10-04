// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Next step. Not implemented in v0.1.
/// @dev v0.1 has no treasury, no token, and no mint. A later treasury must not become a
///      new native coin and must not treat model output as a balance.
interface ITreasury {
    function moduleId() external pure returns (bytes32);
}

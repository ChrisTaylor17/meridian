// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Physical-authority stub. Not wired to hardware.
/// @dev A remote governance decision cannot set or loosen this limit.
///      `applyRemoteDecision` is view and always reverts, so it cannot write.
///      The local operator is out of band: this contract does not make them safe.
contract LocalSafetyLimit {
    uint256 public limit;
    address public immutable localAuthority;

    error RemoteGovernanceRejected(address caller, uint256 requested);
    error NotLocalAuthority(address caller);
    error ZeroAuthority();

    event LocalLimitChanged(uint256 previous, uint256 next, address indexed operator);

    constructor(address localAuthority_, uint256 initialLimit) {
        if (localAuthority_ == address(0)) revert ZeroAuthority();
        localAuthority = localAuthority_;
        limit = initialLimit;
        emit LocalLimitChanged(0, initialLimit, localAuthority_);
    }

    /// @notice Entry used by a remote governance decision. Always fails, whether the
    ///         requested value is tighter or looser than the current limit.
    function applyRemoteDecision(uint256 newLimit) external view {
        revert RemoteGovernanceRejected(msg.sender, newLimit);
    }

    /// @notice Local operator only. This is outside Meridian. It can set or loosen the
    ///         stored number because the physical operator is not the remote protocol.
    function setLocalLimit(uint256 newLimit) external {
        if (msg.sender != localAuthority) revert NotLocalAuthority(msg.sender);
        uint256 previous = limit;
        limit = newLimit;
        emit LocalLimitChanged(previous, newLimit, msg.sender);
    }
}

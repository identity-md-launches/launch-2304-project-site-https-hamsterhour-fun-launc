// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The IMD Intake: one transaction pays for an oracle question and names the callback that
/// receives the signed answer. Function shape from imd.fun/docs, "Pay onchain".
interface IIntake {
    struct Callback {
        address target;
        bytes4 selector;
    }

    function request(bytes32 action, bytes calldata body, Callback calldata callback, address asset, uint256 amount)
        external
        returns (bytes32 requestId);
}

/// @notice The same purchase, plus a function on the callback target that hears a refusal (status 1)
/// or a panel that ended without a result (status 2). From imd.fun/docs, "Pay onchain".
interface IIntakeWithFailure {
    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        IIntake.Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external returns (bytes32 requestId);
}

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

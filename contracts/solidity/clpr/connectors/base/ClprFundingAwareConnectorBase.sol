// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { ClprTypes } from "../../types/ClprTypes.sol";
import { IClprMiddleware } from "../../interfaces/IClprMiddleware.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title CLPR Funding-Aware Connector Base
/// @notice Shared funding-state machine for connector implementations.
/// @dev Connectors own local asset balances, while middleware owns cross-ledger state propagation.
abstract contract ClprFundingAwareConnectorBase {
    using SafeERC20 for IERC20;

    /// @notice Thrown when attempting native deposit for token-based connectors.
    error NativeFundingDisabled();

    /// @notice Thrown when attempting token deposit for native-only connectors.
    error TokenFundingDisabled();

    /// @notice Thrown for zero-value token deposits.
    error InvalidDepositAmount();

    /// @notice Current local funding state.
    ClprTypes.ClprFundingState private _fundingState;

    /// @notice Monotonic epoch incremented on each funding-state transition.
    uint64 private _fundingEpoch;

    /// @notice Indicates whether baseline funding state has been initialized.
    bool private _fundingInitialized;

    /// @notice Middleware endpoint that receives funding transition callbacks.
    address private _fundingMiddleware;

    /// @notice Emitted when a deposit mutates connector funds.
    event FundingDeposited(address indexed funder, address indexed token, uint256 amount, uint256 balanceAfter);

    /// @notice Emitted on funding-state transitions.
    event FundingStateTransition(
        bytes32 indexed connectorId,
        ClprTypes.ClprFundingState fromState,
        ClprTypes.ClprFundingState toState,
        uint64 fundingEpoch,
        uint256 availableBalance,
        uint256 safetyThreshold
    );

    /// @notice Emitted when a transition is notified to middleware.
    event FundingNotifiedMiddleware(
        bytes32 indexed connectorId,
        address indexed middleware,
        uint64 fundingEpoch,
        ClprTypes.ClprFundingState state
    );

    /// @notice Deposits native value into a native-funded connector.
    function depositNative() external payable virtual {
        if (_fundingTokenAddress() != address(0)) revert NativeFundingDisabled();
        _afterFundingMutation(msg.sender, address(0), msg.value);
    }

    /// @notice Deposits ERC20 funds into a token-funded connector.
    function depositToken(uint256 amount) external virtual {
        address tokenAddress = _fundingTokenAddress();
        if (tokenAddress == address(0)) revert TokenFundingDisabled();
        if (amount == 0) revert InvalidDepositAmount();

        IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), amount);
        _afterFundingMutation(msg.sender, tokenAddress, amount);
    }

    /// @notice Returns current local funding state.
    function fundingState() public view virtual returns (ClprTypes.ClprFundingState state) {
        if (!_fundingInitialized) {
            return _deriveFundingState(_availableFundingBalance(), _fundingSafetyThreshold());
        }
        return _fundingState;
    }

    /// @notice Returns current funding epoch.
    function fundingEpoch() public view virtual returns (uint64 epoch) {
        return _fundingEpoch;
    }

    /// @notice Funding-hooks ABI version.
    function fundingHooksVersion() public pure virtual returns (uint32 version) {
        return 1;
    }

    /// @notice Reconciles funding state after out-of-band balance changes.
    function reconcileFundingState() public virtual {
        _refreshFundingStateAndNotify();
    }

    /// @notice Returns middleware currently configured for funding callbacks.
    function fundingMiddleware() public view returns (address middleware) {
        middleware = _fundingMiddleware;
    }

    /// @dev Sets middleware endpoint for transition callbacks.
    function _setFundingMiddleware(address middleware) internal {
        _fundingMiddleware = middleware;
    }

    /// @dev Returns connector-local available funding balance.
    function _availableFundingBalance() internal view virtual returns (uint256);

    /// @dev Returns connector safety threshold in local unit.
    function _fundingSafetyThreshold() internal view virtual returns (uint256);

    /// @dev Returns connector local amount unit.
    function _fundingUnit() internal view virtual returns (string memory);

    /// @dev Returns connector id.
    function _fundingConnectorId() internal view virtual returns (bytes32);

    /// @dev Returns token address used for connector funding (zero address => native).
    function _fundingTokenAddress() internal view virtual returns (address);

    /// @dev Returns connector minimum charge policy.
    function _fundingMinimumCharge() internal view virtual returns (ClprTypes.ClprAmount memory);

    /// @dev Returns connector maximum charge policy.
    function _fundingMaximumCharge() internal view virtual returns (ClprTypes.ClprAmount memory);

    function _afterFundingMutation(address funder, address token, uint256 amount) internal {
        emit FundingDeposited(funder, token, amount, _availableFundingBalance());
        _refreshFundingStateAndNotify();
    }

    function _refreshFundingStateAndNotify() internal {
        uint256 available = _availableFundingBalance();
        uint256 safetyThreshold = _fundingSafetyThreshold();
        ClprTypes.ClprFundingState nextState = _deriveFundingState(available, safetyThreshold);

        if (!_fundingInitialized) {
            _fundingState = nextState;
            _fundingInitialized = true;
            return;
        }

        if (nextState == _fundingState) {
            return;
        }

        ClprTypes.ClprFundingState fromState = _fundingState;
        _fundingState = nextState;
        _fundingEpoch += 1;

        emit FundingStateTransition(
            _fundingConnectorId(),
            fromState,
            nextState,
            _fundingEpoch,
            available,
            safetyThreshold
        );

        address middleware = _fundingMiddleware;
        if (middleware == address(0)) {
            return;
        }

        ClprTypes.ClprBalanceReport memory report = ClprTypes.ClprBalanceReport({
            connectorId: _fundingConnectorId(),
            availableBalance: ClprTypes.ClprAmount({value: available, unit: _fundingUnit()}),
            safetyThreshold: ClprTypes.ClprAmount({value: safetyThreshold, unit: _fundingUnit()}),
            outstandingCommitments: ClprTypes.ClprAmount({value: 0, unit: _fundingUnit()})
        });

        try IClprMiddleware(middleware).onConnectorFundingStateTransition(
            _fundingConnectorId(),
            _fundingEpoch,
            nextState,
            report
        ) {
            emit FundingNotifiedMiddleware(_fundingConnectorId(), middleware, _fundingEpoch, nextState);
        } catch {}
    }

    function _deriveFundingState(
        uint256 available,
        uint256 safetyThreshold
    ) private pure returns (ClprTypes.ClprFundingState state) {
        if (available <= safetyThreshold) {
            return ClprTypes.ClprFundingState.Underfunded;
        }
        return ClprTypes.ClprFundingState.Available;
    }
}

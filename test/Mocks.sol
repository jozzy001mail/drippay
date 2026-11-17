// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";

/// @notice Test double for the Reactive system contract.
///         Records subscriptions and callback requests for assertions.
contract MockSystem is ISystemContract {
    struct Subscription {
        uint256 chainId;
        address contractAddr;
        uint256 topic0;
        uint256 topic1;
        uint256 topic2;
        uint256 topic3;
    }

    Subscription[] public subscriptions;
    CallbackConfiguration_V_1_0[] public callbacks;

    receive() external payable {}

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    function subscribe(
        uint256 chainId_,
        address contract_,
        uint256 topic0_,
        uint256 topic1_,
        uint256 topic2_,
        uint256 topic3_
    ) external {
        subscriptions.push(
            Subscription(chainId_, contract_, topic0_, topic1_, topic2_, topic3_)
        );
    }

    function unsubscribe(
        uint256 chainId_,
        address contract_,
        uint256 topic0_,
        uint256 topic1_,
        uint256 topic2_,
        uint256 topic3_
    ) external {
        for (uint256 i = 0; i < subscriptions.length; i++) {
            Subscription storage s = subscriptions[i];
            if (
                s.chainId == chainId_ && s.contractAddr == contract_ && s.topic0 == topic0_
                    && s.topic1 == topic1_ && s.topic2 == topic2_ && s.topic3 == topic3_
            ) {
                subscriptions[i] = subscriptions[subscriptions.length - 1];
                subscriptions.pop();
                return;
            }
        }
    }

    function requestCallback(CallbackVersion, bytes memory) external {}

    function requestCallbackV_1_0(CallbackConfiguration_V_1_0 memory config_) external {
        callbacks.push(config_);
    }

    function subscriptionCount() external view returns (uint256) {
        return subscriptions.length;
    }

    function callbackCount() external view returns (uint256) {
        return callbacks.length;
    }

    function getCallback(uint256 i_) external view returns (CallbackConfiguration_V_1_0 memory) {
        return callbacks[i_];
    }
}

/// @notice Test double for a destination-chain callback proxy.
contract MockProxy is IPayable {
    receive() external payable {}

    function debt(address) external pure returns (uint256) {
        return 0;
    }
}

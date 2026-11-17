// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { DripVault } from "../src/DripVault.sol";

/// @notice Deploys DripVault on a destination chain.
/// @dev Run with: REACTIVE_ADDR=<deployed DripReactive address>
///      PROXY_ADDR=<callback proxy of the destination chain>
///      forge script script/DeployVault.s.sol --rpc-url <destination RPC>
///      --private-key $DEPLOYER_KEY --broadcast --chain-id <destination chain id>
///      Destination chains (testnet):
///        Base Sepolia 84532 — proxy 0x476F44b11F5C942c58f4c8E3d0300E5710743585, RPC https://sepolia.base.org
///        Unichain Sepolia 1301 — proxy 0x775c9B990ADe401060B78D0e98684eEf8d2466C1, RPC https://sepolia.unichain.org
///        Lasna 5318007 — proxy 0x8888888888888888888888888888888888888888, RPC https://lasna-rpc.rnk.dev/
contract DeployVault is Script {
    function run() external {
        address reactive = vm.envAddress("REACTIVE_ADDR");
        IPayable proxy = IPayable(vm.envAddress("PROXY_ADDR"));
        uint256 fund = vm.envOr("VAULT_FUND_WEI", uint256(0.02 ether));

        vm.startBroadcast();
        DripVault vault = new DripVault{ value: fund }(proxy, reactive);
        vm.stopBroadcast();

        console.log("DripVault deployed at:", address(vault));
        console.log("  callback proxy:", address(proxy));
        console.log("  callback sender (reactive):", reactive);
        console.log("  funded with (native wei):", fund);
        console.log("NEXT: verify with: cast call <vault> \"nextScheduleId()(uint256)\"");
    }
}

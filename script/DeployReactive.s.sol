// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { DripReactive } from "../src/DripReactive.sol";

/// @notice Deploys DripReactive on Reactive Lasna (chain 5318007).
/// @dev Run with: VAULT_ADDR=<precomputed vault address> ORIGIN_CHAIN_ID=84532
///      forge script script/DeployReactive.s.sol --rpc-url https://lasna-rpc.rnk.dev
///      --private-key $DEPLOYER_KEY --broadcast --chain-id 5318007
///      The vault address must be the address the vault WILL deploy at on the
///      destination chain (compute it first with cast compute-address).
contract DeployReactive is Script {
    function run() external {
        address vault = vm.envAddress("VAULT_ADDR");
        uint256 originChain = vm.envOr("ORIGIN_CHAIN_ID", uint256(84532));
        uint256 destChain = vm.envOr("DESTINATION_CHAIN_ID", uint256(84532));
        uint256 fund = vm.envOr("REACTIVE_FUND_WEI", uint256(0.05 ether));

        vm.startBroadcast();
        DripReactive reactive = new DripReactive{ value: fund }(originChain, vault, destChain);
        vm.stopBroadcast();

        console.log("DripReactive deployed at:", address(reactive));
        console.log("  originChainId:", originChain);
        console.log("  vault:", vault);
        console.log("  destinationChainId:", destChain);
        console.log("  funded with (lREACT wei):", fund);
        console.log("NEXT: deploy the vault with REACTIVE_ADDR=%s", address(reactive));
    }
}

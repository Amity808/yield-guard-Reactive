// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {console2} from "forge-std/Script.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {YieldGuard} from "../src/YieldGuard.sol";
import {MockYieldVault} from "../src/mocks/MockYieldVault.sol";

/// @notice Mines the address, deploys YieldGuard, and sets up mock yield vaults
contract DeployYieldGuardScript is BaseScript {
    function run() public {
        // YieldGuard requires:
        // - afterAddLiquidity
        // - beforeRemoveLiquidity
        // - beforeSwap
        // - afterSwap
        uint160 flags = uint160(
            Hooks.AFTER_ADD_LIQUIDITY_FLAG |
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG
        );

        address reactiveRelayer = vm.envOr("REACTIVE_RELAYER", deployerAddress);

        // Mine a salt that will produce a hook address with the correct flags
        bytes memory constructorArgs = abi.encode(poolManager, reactiveRelayer);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(YieldGuard).creationCode, constructorArgs);

        vm.startBroadcast();

        // Deploy the hook using CREATE2
        YieldGuard yieldGuard = new YieldGuard{salt: salt}(poolManager, reactiveRelayer);
        require(address(yieldGuard) == hookAddress, "DeployYieldGuardScript: Hook Address Mismatch");

        // Deploy mock yield vaults for token0 and token1
        MockYieldVault vault0 = new MockYieldVault(address(token0));
        MockYieldVault vault1 = new MockYieldVault(address(token1));

        // Configure vaults on the hook
        yieldGuard.setYieldVault(address(token0), vault0);
        yieldGuard.setYieldVault(address(token1), vault1);

        vm.stopBroadcast();

        console2.log("Deployed YieldGuard at:", address(yieldGuard));
        console2.log("Deployed MockYieldVault for Token0 at:", address(vault0));
        console2.log("Deployed MockYieldVault for Token1 at:", address(vault1));
    }
}

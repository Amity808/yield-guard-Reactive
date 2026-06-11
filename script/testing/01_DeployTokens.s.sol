// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {BaseScript} from "../base/BaseScript.sol";

contract DeployTokensScript is BaseScript {
    function run() public {
        require(block.chainid == 31337, "Local deployment only");

        vm.startBroadcast();

        // Deploy Mock Token A and Mock Token B
        MockERC20 tokenA = new MockERC20("Mock Token A", "MTKNA", 18);
        MockERC20 tokenB = new MockERC20("Mock Token B", "MTKNB", 18);

        // Mint some tokens to the deployer
        tokenA.mint(deployerAddress, 1_000_000 ether);
        tokenB.mint(deployerAddress, 1_000_000 ether);

        vm.stopBroadcast();

        console2.log("Deployed Token A at:", address(tokenA));
        console2.log("Deployed Token B at:", address(tokenB));
    }
}

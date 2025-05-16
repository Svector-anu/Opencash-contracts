// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import "../src/SimpleGateway.sol";

contract DeploySimpleGateway is Script {
    function run() external {
        // Retrieve private key and other deployment parameters from environment variables
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        uint256 protocolFeePercent = vm.envUint("PROTOCOL_FEE_PERCENT"); // in basis points (e.g., 100 = 1%)

        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // Deploy the contract
        SimpleGateway gateway = new SimpleGateway(treasury, protocolFeePercent);
        
        // Optional: Setup additional configurations
        // If you want to configure the Uniswap router during deployment:
        // address uniswapRouter = vm.envAddress("UNISWAP_ROUTER_ADDRESS");
        // gateway.setUniswapRouter(uniswapRouter);

        // Stop broadcasting transactions
        vm.stopBroadcast();

        // Log the deployed contract address
        console.log("SimpleGateway deployed at:", address(gateway));
    }
}
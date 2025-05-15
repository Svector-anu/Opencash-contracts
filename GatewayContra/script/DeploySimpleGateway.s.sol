// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {SimpleGateway} from "../src/simpleGateway.sol";

contract DeploySimpleGateway is Script {
    SimpleGateway public simpleGateway;
    address private constant _TREASURY = 0xD0A2362c6cF02f8FdaCD3E2aBCbfBc625AA0f967;
    uint256 private constant _FEE = 100;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        simpleGateway= new SimpleGateway(_TREASURY, _FEE);

        vm.stopBroadcast();
    }
}

//Contract address : 0x6479973F4C38025918d9b252AA03964be874b6D5

//contrzct on mainnet  0x998f0be3FA78a085374e49EcBF8E37703a4575A4

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {DSCEngine} from "src/DSCEngine.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {Script, console2} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployDSC is Script {
    DecentralizedStableCoin public dsc;
    DSCEngine public dscEngine;

    function run() external {
        vm.startBroadcast();
        dsc = new DecentralizedStableCoin();

        vm.stopBroadcast();
    }
}

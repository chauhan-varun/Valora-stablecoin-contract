// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {Test, console} from "forge-std/Test.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

contract DecentralizedStableCoinTest is Test {
    DecentralizedStableCoin public dsc;

    function setUp() external {
        dsc = new DecentralizedStableCoin();
    }

    function testRevertIfMintZeroDSC() public {
        vm.prank(dsc.owner());
        vm.expectRevert();
        dsc.mint(address(this), 0);
    }

    function testRevertIfBurnZeroDSC() public {
        vm.prank(dsc.owner());
        dsc.mint(address(this), 1000e18);
        vm.expectRevert();
        dsc.burn(0);
    }

    function testRevertIfBurnMoreThanBalance() public {
        vm.prank(dsc.owner());
        dsc.mint(address(this), 1000e18);
        vm.expectRevert();
        dsc.burn(1001e18);
    }

    function testRevertIfMintToZeroAddress() public {
        vm.prank(dsc.owner());
        vm.expectRevert();
        dsc.mint(address(0), 1000e18);
    }
}

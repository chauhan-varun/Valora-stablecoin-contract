// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {DSCEngine} from "src/DSCEngine.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {Test, console2} from "forge-std/Test.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract DSCEngineTest is Test {
    DecentralizedStableCoin public dsc;
    DSCEngine public dscEngine;
    HelperConfig public config;
    address public ethUsdPriceFeed;
    address public weth;

    address public USER = makeAddr("USER");
    uint256 public constant AMOUNT_COLLATORAL = 10 ether;
    uint256 public constant STARTING_ER20_BALANCE = 10 ether;

    function setUp() external {
        DeployDSC deployDSC = new DeployDSC();
        (dsc, dscEngine, config) = deployDSC.run();
        (ethUsdPriceFeed, , weth, , ) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ER20_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////
                               PRICE TEST
    //////////////////////////////////////////////////////////////*/

    function testGetUsdValue() public view {
        uint256 ethAmount = 15 ether;
        uint256 expectedUsdValue = 30000 ether;

        uint256 usdValue = dscEngine.getCollatoralValue(weth, ethAmount);
        assert(usdValue == expectedUsdValue);
    }

    /*//////////////////////////////////////////////////////////////
                               DEPOSIT COLLATORAL TEST
    //////////////////////////////////////////////////////////////*/

    function testRevertIfCollatoralValueIsZero() public {
        vm.startPrank(USER);

        ERC20Mock(weth).approve(USER, AMOUNT_COLLATORAL);
        vm.expectRevert(
            DSCEngine.DSCEngine__AmountMustBeGreaterThanZero.selector
        );

        dscEngine.depositCollatoral(weth, 0);
    }
}

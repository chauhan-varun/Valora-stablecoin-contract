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
    address public btcUsdPriceFeed;
    address public wbtc;
    address public weth;
    uint256 public deployerKey;

    address public USER = makeAddr("USER");
    uint256 public constant AMOUNT_COLLATORAL = 10 ether;
    uint256 public constant STARTING_ER20_BALANCE = 10 ether;

    function setUp() external {
        DeployDSC deployDSC = new DeployDSC();
        (dsc, dscEngine, config) = deployDSC.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = config
            .activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ER20_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier depositCollatoral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATORAL);
        dscEngine.depositCollatoral(weth, AMOUNT_COLLATORAL);
        vm.stopPrank();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR TEST
    //////////////////////////////////////////////////////////////*/

    address[] public tokens = [weth];
    address[] public priceFeeds = [ethUsdPriceFeed, btcUsdPriceFeed];

    function testRevertIfLengthsOfTokensAndPriceFeedsDontMatch() public {
        vm.expectRevert(
            DSCEngine.DSCEngine__LengthsOfTokensAndPriceFeedsMustMatch.selector
        );
        new DSCEngine(tokens, priceFeeds, address(dsc));
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        uint256 expectedTokenAmount = 0.05 ether;
        uint256 tokenAmount = dscEngine.getTokenAmountFromUsd(weth, usdAmount);
        assert(tokenAmount == expectedTokenAmount);
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

    function testRevertIfUnapproveCollatoral() public {
        ERC20Mock token = new ERC20Mock("token", "token", USER, 1000 ether);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotSupported.selector);
        dscEngine.depositCollatoral(address(token), AMOUNT_COLLATORAL);
        vm.stopPrank();
    }

    function testUserCanDepositeAndGetInfo() public depositCollatoral {
        (uint256 totalDscMinted, uint256 collatoralValueInUsd) = dscEngine
            .getAccountInfo(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedCollateralValueInUsd = dscEngine.getCollatoralValue(
            weth,
            AMOUNT_COLLATORAL
        );
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(collatoralValueInUsd, expectedCollateralValueInUsd);
    }
}

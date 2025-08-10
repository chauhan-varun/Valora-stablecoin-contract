// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
// import { ERC20Mock } from "@openzeppelin/contracts/mocks/ERC20Mock.sol"; Updated mock location
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {MockMoreDebtDSC} from "../mocks/MockMoreDebtDSC.sol";
import {MockFailedMintDSC} from "../mocks/MockFailedMintDSC.sol";
import {MockFailedTransferFrom} from "../mocks/MockFailedTransferFrom.sol";
import {MockFailedTransfer} from "../mocks/MockFailedTransfer.sol";
import {Test, console2} from "forge-std/Test.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

contract DSCEngineTest is Test {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a user deposits collateral
    event DepositCollateral(
        address indexed user,
        address indexed tokenCollateral,
        uint256 indexed amount
    );

    /// @notice Emitted when collateral is redeemed (withdrawn or liquidated)
    event CollateralRedeemed(
        address indexed redeemFrom,
        address indexed redeemTo,
        address indexed tokenCollateral,
        uint256 amount
    );

    /*//////////////////////////////////////////////////////////////
                           STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    DecentralizedStableCoin public dsc;
    DSCEngine public dscEngine;
    HelperConfig public config;
    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public wbtc;
    address public weth;
    uint256 public deployerKey;

    // Test users
    address public USER = makeAddr("USER");
    address public LIQUIDATOR = makeAddr("LIQUIDATOR");
    address public USER2 = makeAddr("USER2");

    // Test constants
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;
    uint256 public constant COLLATERAL_TO_COVER = 20 ether;
    uint256 public constant AMOUNT_DSC_TO_MINT = 100 ether;

    // Price constants for testing (assuming ETH = $2000, BTC = $60000)
    int256 public constant ETH_USD_PRICE = 2000e8;
    int256 public constant BTC_USD_PRICE = 60000e8;

    /*//////////////////////////////////////////////////////////////
                              SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        DeployDSC deployDSC = new DeployDSC();
        (dsc, dscEngine, config) = deployDSC.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = config
            .activeNetworkConfig();

        if (block.chainid == 31_337) {
            vm.deal(USER, STARTING_ERC20_BALANCE);
        }

        // Mint tokens to test users
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(wbtc).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(weth).mint(LIQUIDATOR, STARTING_ERC20_BALANCE);
        ERC20Mock(wbtc).mint(LIQUIDATOR, STARTING_ERC20_BALANCE);
        ERC20Mock(weth).mint(USER2, STARTING_ERC20_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier depositCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier depositCollateralAndMintDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 5000e18); // Mint 5000 DSC
        vm.stopPrank();
        _;
    }

    modifier liquidated() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(
            weth,
            AMOUNT_COLLATERAL,
            AMOUNT_DSC_TO_MINT
        );
        vm.stopPrank();
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = dscEngine.getHealthFactor(USER);

        ERC20Mock(weth).mint(LIQUIDATOR, COLLATERAL_TO_COVER);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dscEngine), COLLATERAL_TO_COVER);
        dscEngine.depositCollateralAndMintDsc(
            weth,
            COLLATERAL_TO_COVER,
            AMOUNT_DSC_TO_MINT
        );
        dsc.approve(address(dscEngine), AMOUNT_DSC_TO_MINT);
        dscEngine.liquidate(weth, USER, AMOUNT_DSC_TO_MINT); // We are covering their whole debt
        vm.stopPrank();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                         CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function testRevertIfLengthsOfTokensAndPriceFeedsDontMatch() public {
        address[] memory tokens = new address[](1);
        tokens[0] = weth;

        address[] memory priceFeeds = new address[](2);
        priceFeeds[0] = btcUsdPriceFeed;
        priceFeeds[1] = ethUsdPriceFeed;

        vm.expectRevert(
            DSCEngine.DSCEngine__LengthsOfTokensAndPriceFeedsMustMatch.selector
        );
        new DSCEngine(tokens, priceFeeds, address(dsc));
    }

    function testConstructorSetsTokensAndPriceFeeds() public {
        address[] memory collateralTokens = dscEngine.getCollateralTokens();
        assertEq(collateralTokens.length, 2);
        assertEq(collateralTokens[0], weth);
        assertEq(collateralTokens[1], wbtc);

        assertEq(dscEngine.getCollateralTokenPriceFeed(weth), ethUsdPriceFeed);
        assertEq(dscEngine.getCollateralTokenPriceFeed(wbtc), btcUsdPriceFeed);
    }

    function testConstructorSetsDscAddress() public {
        assertEq(dscEngine.getDsc(), address(dsc));
    }

    /*//////////////////////////////////////////////////////////////
                           PRICE TESTS
    //////////////////////////////////////////////////////////////*/

    function testGetUsdValue() public {
        uint256 ethAmount = 15 ether;
        uint256 expectedUsdValue = 30000 ether; // 15 ETH * $2000 = $30,000
        uint256 usdValue = dscEngine.getUsdValue(weth, ethAmount);
        assertEq(usdValue, expectedUsdValue);
    }

    function testGetUsdValueBTC() public {
        uint256 btcAmount = 1 ether; // 1 BTC
        uint256 expectedUsdValue = 1000 ether; // 1 BTC * $60,000 = $60,000
        uint256 usdValue = dscEngine.getUsdValue(wbtc, btcAmount);
        assertEq(usdValue, expectedUsdValue);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether; // $100
        uint256 expectedTokenAmount = 0.05 ether; // $100 / $2000 = 0.05 ETH
        uint256 tokenAmount = dscEngine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(tokenAmount, expectedTokenAmount);
    }

    function testGetTokenAmountFromUsdBTC() public {
        uint256 usdAmount = 1000 ether; // $60,000
        uint256 expectedTokenAmount = 1 ether; // $60,000 / $60,000 = 1 BTC
        uint256 tokenAmount = dscEngine.getTokenAmountFromUsd(wbtc, usdAmount);
        assertEq(tokenAmount, expectedTokenAmount);
    }

    /*//////////////////////////////////////////////////////////////
                       DEPOSIT COLLATERAL TESTS
    //////////////////////////////////////////////////////////////*/

    function testRevertIfCollateralValueIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        vm.expectRevert(
            DSCEngine.DSCEngine__AmountMustBeGreaterThanZero.selector
        );
        dscEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertIfUnapprovedCollateral() public {
        ERC20Mock unsupportedToken = new ERC20Mock(
            "UNSUPPORTED",
            "UNSUP",
            USER,
            1000 ether
        );

        vm.startPrank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__TokenNotSupported.selector,
                address(unsupportedToken)
            )
        );
        dscEngine.depositCollateral(
            address(unsupportedToken),
            AMOUNT_COLLATERAL
        );
        vm.stopPrank();
    }

    function testRevertIfCollateralAddressIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        vm.expectRevert(
            abi.encodeWithSelector(DSCEngine.DSCEngine__TokenNotSupported.selector, address(0))
        );
        dscEngine.depositCollateral(address(0), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testCanDepositCollateralAndGetAccountInfo()
        public
        depositCollateral
    {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine
            .getAccountInfo(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedCollateralValue = dscEngine.getUsdValue(
            weth,
            AMOUNT_COLLATERAL
        );

        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(collateralValueInUsd, expectedCollateralValue);
    }

    function testDepositCollateralWithoutMintingDsc() public depositCollateral {
        uint256 totalDscMinted = dsc.balanceOf(USER);
        assertEq(totalDscMinted, 0);
    }

    function testDepositCollateralEmitsEvent() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        vm.expectEmit(true, true, true, true, address(dscEngine));
        emit DepositCollateral(USER, weth, AMOUNT_COLLATERAL);

        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testDepositUpdatesCollateralBalance() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();

        uint256 collateralBalance = dscEngine.getCollateralBalanceOfUser(
            USER,
            weth
        );
        assertEq(collateralBalance, AMOUNT_COLLATERAL);
    }

    function testRevertIfTransferFromFails() public {
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransferFrom mockCollateralToken = new MockFailedTransferFrom();
        address[] memory tokens = new address[](1);
        address[] memory priceFeeds = new address[](1);
        tokens[0] = address(mockCollateralToken);
        priceFeeds[0] = ethUsdPriceFeed;
        // DSCEngine receives the third parameter as dscAddress, not the tokenAddress used as collateral.
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokens, priceFeeds, address(dsc));
        mockCollateralToken.mint(USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        ERC20Mock(address(mockCollateralToken)).approve(
            address(mockDsce),
            AMOUNT_COLLATERAL
        );
        // Act / Assert
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDsce.depositCollateral(
            address(mockCollateralToken),
            AMOUNT_COLLATERAL
        );
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                         MINT DSC TESTS
    //////////////////////////////////////////////////////////////*/

    function testCanMintDsc() public depositCollateral {
        uint256 amountToMint = 1000e18; // 1000 DSC

        vm.prank(USER);
        dscEngine.mintDsc(amountToMint);

        uint256 userDscBalance = dsc.balanceOf(USER);
        assertEq(userDscBalance, amountToMint);
    }


    function testRevertMintDscIfZeroAmount() public depositCollateral {
        vm.prank(USER);
        vm.expectRevert(
            DSCEngine.DSCEngine__AmountMustBeGreaterThanZero.selector
        );
        dscEngine.mintDsc(0);
    }

    function testRevertsIfMintFails() public {
        // Arrange - Setup
        MockFailedMintDSC mockDsc = new MockFailedMintDSC();

        address[] memory tokenAddresses = new address[](1);
        tokenAddresses[0] = weth;

        address[] memory feedAddresses = new address[](1);
        feedAddresses[0] = ethUsdPriceFeed;

        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(
            tokenAddresses,
            feedAddresses,
            address(mockDsc)
        );
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockDsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
        mockDsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 1000e18);
        vm.stopPrank();
    }

    function testRevertMintDscIfBreaksHealthFactor() public {
        (, int256 price, , , ) = MockV3Aggregator(ethUsdPriceFeed)
            .latestRoundData();
        uint256 amountToMint = (AMOUNT_COLLATERAL *
            (uint256(price) * dscEngine.getAdditionalFeedPrecision())) /
            dscEngine.getPrecision();
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        uint256 expectedHealthFactor = dscEngine.calculateHealthFactor(
            amountToMint,
            dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__BreakHealthFactor.selector,
                expectedHealthFactor
            )
        );
        dscEngine.depositCollateralAndMintDsc(
            weth,
            AMOUNT_COLLATERAL,
            amountToMint
        );
        vm.stopPrank();
    }

    function testMintDscUpdatesUserDebt() public depositCollateral {
        uint256 amountToMint = 1000e18;

        vm.prank(USER);
        dscEngine.mintDsc(amountToMint);

        uint256 userDebt = dscEngine.getDscMinted(USER);
        assertEq(userDebt, amountToMint);
    }

    /*//////////////////////////////////////////////////////////////
                    DEPOSIT AND MINT COMBINED TESTS
    //////////////////////////////////////////////////////////////*/

    function testDepositCollateralAndMintDsc() public {
        uint256 collateralAmount = 5 ether;
        uint256 dscAmount = 2000e18;

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), collateralAmount);
        dscEngine.depositCollateralAndMintDsc(
            weth,
            collateralAmount,
            dscAmount
        );
        vm.stopPrank();

        uint256 userCollateral = dscEngine.getCollateralBalanceOfUser(
            USER,
            weth
        );
        uint256 userDebt = dscEngine.getDscMinted(USER);
        uint256 userDscBalance = dsc.balanceOf(USER);

        assertEq(userCollateral, collateralAmount);
        assertEq(userDebt, dscAmount);
        assertEq(userDscBalance, dscAmount);
    }

    /*//////////////////////////////////////////////////////////////
                         HEALTH FACTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function testHealthFactorCalculation() public depositCollateralAndMintDsc {
        uint256 healthFactor = dscEngine.getHealthFactor(USER);

        // Expected: (10 ETH * $2000 * 0.5) / 5000 DSC = 2.0
        uint256 expectedHealthFactor = 2e18;
        assertEq(healthFactor, expectedHealthFactor);
    }

    function testHealthFactorWhenNoDscMinted() public depositCollateral {
        uint256 healthFactor = dscEngine.getHealthFactor(USER);
        assertEq(healthFactor, type(uint256).max); // Should be max uint256
    }

    function testHealthFactorCanGoBelowOne()
        public
        depositCollateralAndMintDsc
    {
        int256 ethUsdUpdatedPrice = 18e8;

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        uint256 userHealthFactor = dscEngine.getHealthFactor(USER);
        console2.log("User health factor: %s", userHealthFactor);
        assert(userHealthFactor == 18e15);
    }

    function testCalculateHealthFactor() public {
        uint256 totalDscMinted = 1000e18;
        uint256 collateralValueInUsd = 4000e18; // $4000 worth

        uint256 healthFactor = dscEngine.calculateHealthFactor(
            totalDscMinted,
            collateralValueInUsd
        );

        // Expected: ($4000 * 0.5) / 1000 = 2.0
        uint256 expectedHealthFactor = 2e18;
        assertEq(healthFactor, expectedHealthFactor);
    }

    /*//////////////////////////////////////////////////////////////
                         BURN DSC TESTS
    //////////////////////////////////////////////////////////////*/

    function testBurnDsc() public depositCollateralAndMintDsc {
        uint256 amountToBurn = 1000e18;

        vm.startPrank(USER);
        dsc.approve(address(dscEngine), amountToBurn);
        dscEngine.burnDsc(amountToBurn);
        vm.stopPrank();

        uint256 userDebt = dscEngine.getDscMinted(USER);
        assertEq(userDebt, 4000e18); // Original 5000 - 1000 burned = 4000
    }

    function testCantBurnMoreThanUserHas() public {
        vm.prank(USER);
        vm.expectRevert();
        dscEngine.burnDsc(1);
    }

    function testRevertBurnDscIfZeroAmount()
        public
        depositCollateralAndMintDsc
    {
        vm.prank(USER);
        vm.expectRevert(
            DSCEngine.DSCEngine__AmountMustBeGreaterThanZero.selector
        );
        dscEngine.burnDsc(0);
    }

    function testBurnDscReducesTotalSupply()
        public
        depositCollateralAndMintDsc
    {
        uint256 initialSupply = dsc.totalSupply();
        uint256 amountToBurn = 1000e18;

        vm.startPrank(USER);
        dsc.approve(address(dscEngine), amountToBurn);
        dscEngine.burnDsc(amountToBurn);
        vm.stopPrank();

        uint256 finalSupply = dsc.totalSupply();
        assertEq(finalSupply, initialSupply - amountToBurn);
    }

    /*//////////////////////////////////////////////////////////////
                      REDEEM COLLATERAL TESTS
    //////////////////////////////////////////////////////////////*/

    function testRevertsIfTransferFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransfer mockDsc = new MockFailedTransfer();
        address[] memory tokenAddresses = new address[](1);
        tokenAddresses[0] = address(mockDsc);
        address[] memory feedAddresses = new address[](1);
        feedAddresses[0] = ethUsdPriceFeed;
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(
            tokenAddresses,
            feedAddresses,
            address(mockDsc)
        );
        mockDsc.mint(USER, AMOUNT_COLLATERAL);

        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(address(mockDsc)).approve(
            address(mockDsce),
            AMOUNT_COLLATERAL
        );
        mockDsce.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDsce.redeemCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRedeemCollateralForDsc() public depositCollateralAndMintDsc {
        uint256 collateralToRedeem = 1 ether;
        uint256 dscToBurn = 1000e18;

        vm.startPrank(USER);
        dsc.approve(address(dscEngine), dscToBurn);
        dscEngine.redeemCollateralForDsc(weth, collateralToRedeem, dscToBurn);
        vm.stopPrank();

        uint256 userCollateral = dscEngine.getCollateralBalanceOfUser(
            USER,
            weth
        );
        uint256 userDebt = dscEngine.getDscMinted(USER);

        assertEq(userCollateral, AMOUNT_COLLATERAL - collateralToRedeem);
        assertEq(userDebt, 4000e18); // 5000 - 1000 burned
    }

    function testCanRedeemCollateral() public depositCollateral {
        vm.startPrank(USER);
        uint256 userBalanceBeforeRedeem = dscEngine.getCollateralBalanceOfUser(
            USER,
            weth
        );
        assertEq(userBalanceBeforeRedeem, AMOUNT_COLLATERAL);
        dscEngine.redeemCollateral(weth, AMOUNT_COLLATERAL);
        uint256 userBalanceAfterRedeem = dscEngine.getCollateralBalanceOfUser(
            USER,
            weth
        );
        assertEq(userBalanceAfterRedeem, 0);
        vm.stopPrank();
    }

    function testRevertRedeemCollateralIfBreaksHealthFactor()
        public
        depositCollateralAndMintDsc
    {
        uint256 collateralToRedeem = 8 ether; // Too much collateral to redeem
        uint256 dscToBurn = 1000e18;

        vm.startPrank(USER);
        dsc.approve(address(dscEngine), dscToBurn);
        vm.expectRevert(); // Should revert due to broken health factor
        dscEngine.redeemCollateralForDsc(weth, collateralToRedeem, dscToBurn);
        vm.stopPrank();
    }

    function testRedeemCollateralEmitsEvent()
        public
        depositCollateralAndMintDsc
    {
        uint256 collateralToRedeem = 1 ether;
        uint256 dscToBurn = 2000e18;

        vm.startPrank(USER);
        dsc.approve(address(dscEngine), dscToBurn);

        vm.expectEmit(true, true, true, true, address(dscEngine));
        emit CollateralRedeemed(USER, USER, weth, collateralToRedeem);

        dscEngine.redeemCollateralForDsc(weth, collateralToRedeem, dscToBurn);
        vm.stopPrank();
    }

    function testRevertsIfRedeemAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 5000e18);
        vm.expectRevert(
            DSCEngine.DSCEngine__AmountMustBeGreaterThanZero.selector
        );
        dscEngine.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testMustRedeemMoreThanZero() public depositCollateralAndMintDsc {
        vm.startPrank(USER);
        dsc.approve(address(dscEngine), AMOUNT_COLLATERAL);
        vm.expectRevert(
            DSCEngine.DSCEngine__AmountMustBeGreaterThanZero.selector
        );
        dscEngine.redeemCollateralForDsc(weth, 0, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                         LIQUIDATION TESTS
    //////////////////////////////////////////////////////////////*/

    // Helper function to setup a liquidatable position
    function setupLiquidatableUser() public {
        // USER deposits collateral and mints DSC
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 8000e18);
        vm.stopPrank();

        // Crash ETH price to make position liquidatable
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(1200e8); // ETH drops to $1200
    }

    function testLiquidateUser() public {
        setupLiquidatableUser();

        // Give LIQUIDATOR DSC to cover debt
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 5000e18);

        // Approve DSC for liquidation
        uint256 debtToCover = 2000e18;
        dsc.approve(address(dscEngine), debtToCover);

        // Perform liquidation
        dscEngine.liquidate(weth, USER, debtToCover);
        vm.stopPrank();

        // Check that USER's debt was reduced
        uint256 userDebtAfter = dscEngine.getDscMinted(USER);
        assertLt(userDebtAfter, 8000e18);
    }



    function testRevertLiquidateHealthyUser()
        public
        depositCollateralAndMintDsc
    {
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 5000e18);

        dsc.approve(address(dscEngine), 1000e18);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dscEngine.liquidate(weth, USER, 1000e18);
        vm.stopPrank();
    }


    function testLiquidationImproveHealthFactor() public {
        setupLiquidatableUser();

        uint256 healthFactorBefore = dscEngine.getHealthFactor(USER);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 5000e18);

        uint256 debtToCover = 2000e18;
        dsc.approve(address(dscEngine), debtToCover);
        dscEngine.liquidate(weth, USER, debtToCover);
        vm.stopPrank();

        uint256 healthFactorAfter = dscEngine.getHealthFactor(USER);
        assertGt(healthFactorAfter, healthFactorBefore);
    }

    function testPartialLiquidation() public {
        setupLiquidatableUser();

        uint256 initialDebt = dscEngine.getDscMinted(USER);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 5000e18);

        uint256 debtToCover = 1000e18; // Partial liquidation
        dsc.approve(address(dscEngine), debtToCover);
        dscEngine.liquidate(weth, USER, debtToCover);
        vm.stopPrank();

        uint256 finalDebt = dscEngine.getDscMinted(USER);
        assertEq(finalDebt, initialDebt - debtToCover);
    }

    function testUserStillHasSomeEthAfterLiquidation() public liquidated {
        // Get how much WETH the user lost
        uint256 amountLiquidated = dscEngine.getTokenAmountFromUsd(
            weth,
            AMOUNT_DSC_TO_MINT
        ) +
            ((dscEngine.getTokenAmountFromUsd(weth, AMOUNT_DSC_TO_MINT) *
                dscEngine.getLiquidationBonus()) /
                dscEngine.getLiquidationPrecision());

        uint256 usdAmountLiquidated = dscEngine.getUsdValue(
            weth,
            amountLiquidated
        );
        uint256 expectedUserCollateralValueInUsd = dscEngine.getUsdValue(
            weth,
            AMOUNT_COLLATERAL
        ) - (usdAmountLiquidated);

        (, uint256 userCollateralValueInUsd) = dscEngine.getAccountInfo(USER);
        uint256 hardCodedExpectedValue = 70_000_000_000_000_000_020;
        assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
        assertEq(userCollateralValueInUsd, hardCodedExpectedValue);
    }

    function testLiquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(LIQUIDATOR);

        // Calculate the expected liquidation reward (collateral + bonus)
        uint256 tokenAmountFromDebtCovered = dscEngine.getTokenAmountFromUsd(
            weth,
            AMOUNT_DSC_TO_MINT
        );
        uint256 bonusCollateral = (tokenAmountFromDebtCovered *
            dscEngine.getLiquidationBonus()) /
            dscEngine.getLiquidationPrecision();
        uint256 totalCollateralToLiquidator = tokenAmountFromDebtCovered +
            bonusCollateral;

        // Liquidator's expected balance = starting balance + minted tokens + liquidation reward - deposited collateral
        // Starting balance: STARTING_ERC20_BALANCE (10 ether)
        // Minted in liquidated modifier: COLLATERAL_TO_COVER (20 ether)
        // Deposited as collateral: COLLATERAL_TO_COVER (20 ether)
        // Liquidation reward: totalCollateralToLiquidator
        uint256 expectedWeth = STARTING_ERC20_BALANCE +
            totalCollateralToLiquidator;
        // Simplifies to: STARTING_ERC20_BALANCE + totalCollateralToLiquidator
        expectedWeth = STARTING_ERC20_BALANCE + totalCollateralToLiquidator;

        uint256 hardCodedExpected = 16_111_111_111_111_111_110;
        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function testLiquidatorTakesOnUsersDebt() public liquidated {
        (uint256 liquidatorDscMinted, ) = dscEngine.getAccountInfo(
            LIQUIDATOR
        );
        assertEq(liquidatorDscMinted, AMOUNT_DSC_TO_MINT);
    }

    function testUserHasNoMoreDebt() public liquidated {
        (uint256 userDscMinted, ) = dscEngine.getAccountInfo(USER);
        assertEq(userDscMinted, 0);
    }

    /*//////////////////////////////////////////////////////////////
                       GETTER FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function testGetCollateralTokens() public {
        address[] memory tokens = dscEngine.getCollateralTokens();
        assertEq(tokens.length, 2);
        assertEq(tokens[0], weth);
        assertEq(tokens[1], wbtc);
    }

    function testGetCollateralTokenPriceFeed() public {
        address priceFeed = dscEngine.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, ethUsdPriceFeed);
    }

    function testGetMinHealthFactor() public {
        assertEq(dscEngine.getMinHealthFactor(), 1e18);
    }

    function testGetAccountCollateralValueFromInformation() public depositCollateral {
        (, uint256 collateralValue) = dscEngine.getAccountInfo(USER);
        uint256 expectedCollateralValue = dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetLiquidationThreshold() public {
        assertEq(dscEngine.getLiquidationThreshold(), 50);
    }

    function testGetLiquidationBonus() public {
        assertEq(dscEngine.getLiquidationBonus(), 10);
    }

    function testGetPrecision() public {
        assertEq(dscEngine.getPrecision(), 1e18);
    }

    function testGetDsc() public {
        address dscAddress = dscEngine.getDsc();
        assertEq(dscAddress, address(dsc));
    }

    function testGetCollateralBalanceOfUser() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        uint256 collateralBalance = dscEngine.getCollateralBalanceOfUser(USER, weth);
        assertEq(collateralBalance, AMOUNT_COLLATERAL);
    }

    function testGetAccountCollateralValue() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        uint256 collateralValue = dscEngine.getAccountCollateralValue(USER);
        uint256 expectedCollateralValue = dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetAdditionalFeedPrecision() public {
        assertEq(dscEngine.getAdditionalFeedPrecision(), 1e10);
    }

    function testGetLiquidationPrecision() public {
        assertEq(dscEngine.getLiquidationPrecision(), 100);
    }

    /*//////////////////////////////////////////////////////////////
                          EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    function testMultipleUsersCanDepositAndMint() public {
        // USER deposits and mints
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), 5 ether);
        dscEngine.depositCollateralAndMintDsc(weth, 5 ether, 2000e18);
        vm.stopPrank();

        // USER2 deposits and mints
        vm.startPrank(USER2);
        ERC20Mock(weth).approve(address(dscEngine), 5 ether);
        dscEngine.depositCollateralAndMintDsc(weth, 5 ether, 3000e18);
        vm.stopPrank();

        uint256 user1Debt = dscEngine.getDscMinted(USER);
        uint256 user2Debt = dscEngine.getDscMinted(USER2);

        assertEq(user1Debt, 2000e18);
        assertEq(user2Debt, 3000e18);
    }

    function testCanDepositMultipleCollateralTypes() public {
        vm.startPrank(USER);

        // Deposit WETH
        ERC20Mock(weth).approve(address(dscEngine), 5 ether);
        dscEngine.depositCollateral(weth, 5 ether);

        // Deposit WBTC
        ERC20Mock(wbtc).approve(address(dscEngine), 1 ether);
        dscEngine.depositCollateral(wbtc, 1 ether);

        vm.stopPrank();

        uint256 wethBalance = dscEngine.getCollateralBalanceOfUser(USER, weth);
        uint256 wbtcBalance = dscEngine.getCollateralBalanceOfUser(USER, wbtc);
        uint256 totalCollateralValue = dscEngine.getAccountCollateralValue(
            USER
        );

        assertEq(wethBalance, 5 ether);
        assertEq(wbtcBalance, 1 ether);
        // 5 ETH * $2000 + 1 BTC * $1000 = $11,000
        assertEq(totalCollateralValue, 11000e18);
    }

    function testMaxDscCanBeMinted() public {
        uint256 collateralAmount = 10 ether; // $20,000 worth
        uint256 maxDscToMint = 10000e18; // 50% of collateral value

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), collateralAmount);
        dscEngine.depositCollateralAndMintDsc(
            weth,
            collateralAmount,
            maxDscToMint
        );
        vm.stopPrank();

        uint256 healthFactor = dscEngine.getHealthFactor(USER);
        assertEq(healthFactor, 1e18); // Exactly at liquidation threshold
    }
}

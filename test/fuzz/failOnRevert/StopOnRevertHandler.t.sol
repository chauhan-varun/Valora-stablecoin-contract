// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Test} from "forge-std/Test.sol";
// import { ERC20Mock } from "@openzeppelin/contracts/mocks/ERC20Mock.sol"; Updated mock location
import {ERC20Mock} from "../../mocks/ERC20Mock.sol";

import {MockV3Aggregator} from "../../mocks/MockV3Aggregator.sol";
import {DSCEngine, AggregatorV3Interface} from "../../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../../src/DecentralizedStableCoin.sol";
// import {Randomish, EnumerableSet} from "../Randomish.sol"; // Randomish is not found in the codebase, EnumerableSet
// is imported from openzeppelin
import {console} from "forge-std/console.sol";

contract StopOnRevertHandler is Test {
    using EnumerableSet for EnumerableSet.AddressSet;

    DSCEngine public dscEngine;
    DecentralizedStableCoin public dsc;
    ERC20Mock public weth;
    ERC20Mock public wbtc;
    MockV3Aggregator public usdPriceFeed;
    MockV3Aggregator public btcPriceFeed;

    uint256 public constant MAX_DEPOSIT_VALUE = type(uint96).max;
    address[] public userWithCollateralDeposit;

    constructor(DSCEngine _dscEngine, DecentralizedStableCoin _dsc) {
        dscEngine = _dscEngine;
        dsc = _dsc;
        address[] memory collateralTokens = dscEngine.getCollateralTokens();
        wbtc = ERC20Mock(collateralTokens[1]);
        weth = ERC20Mock(collateralTokens[0]);

        usdPriceFeed = MockV3Aggregator(
            dscEngine.getCollateralTokenPriceFeed(address(weth))
        );
        btcPriceFeed = MockV3Aggregator(
            dscEngine.getCollateralTokenPriceFeed(address(wbtc))
        );
    }

    function mintDsc(uint256 amount, uint256 addressSeed) public {
        if (userWithCollateralDeposit.length == 0) return;
        address sender = userWithCollateralDeposit[
            addressSeed % userWithCollateralDeposit.length
        ];
        (uint256 totalDscMinted, uint256 collateralValue) = dscEngine
            .getAccountInfo(sender);
        int256 collateralDelta = (int256(collateralValue) / 2) -
            int256(totalDscMinted);

        if (collateralDelta < 0) return;

        amount = bound(amount, 0, uint256(collateralDelta));

        if (amount == 0) return;

        vm.startPrank(sender);
        dscEngine.mintDsc(amount);
        vm.stopPrank();
    }

    function mintAndDepositCollateral(
        uint256 collateralSeed,
        uint256 amount
    ) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amount = bound(amount, 1, MAX_DEPOSIT_VALUE);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amount);
        collateral.approve(address(dscEngine), amount);
        dscEngine.depositCollateral(address(collateral), amount);
        vm.stopPrank();
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amount) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollatoralToRedeem = dscEngine.getCollatoralBalanceOfUser(
            address(collateral),
            msg.sender
        );
        amount = bound(amount, 0, maxCollatoralToRedeem);
        if (amount == 0) return;
        dscEngine.redeemCollateral(address(collateral), amount);
    }

    function transferDsc(uint256 amount, address recipient) public {
        if (recipient == address(0)) return;
        amount = bound(amount, 0, dsc.balanceOf(msg.sender));
        if (amount == 0) return;
        vm.startPrank(msg.sender);
        dsc.transfer(recipient, amount);
        vm.stopPrank();
    }

    function updateCollateralPrice(
        uint96 newPrice,
        uint256 collateralSeed
    ) public {
        int256 intNewPrice = int256(uint256(newPrice));
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        MockV3Aggregator priceFeed = MockV3Aggregator(
            dscEngine.getCollateralTokenPriceFeed(address(collateral))
        );

        priceFeed.updateAnswer(intNewPrice);
    }

    function burnDsc(uint256 amount) public {
        amount = bound(amount, 0, dsc.balanceOf(msg.sender));
        if (amount == 0) return;

        vm.startPrank(msg.sender);
        dsc.approve(address(dscEngine), amount);
        dscEngine.burnDsc(amount);
        vm.stopPrank();
    }

    function liquidate(
        uint256 collatoralSeed,
        address userToBeLiquidated,
        uint256 debtToCover
    ) public {
        uint256 minHF = dscEngine.getMinHealthFactor();
        if (dscEngine.getHealthFactor(userToBeLiquidated) >= minHF) return;

        debtToCover = bound(debtToCover, 1, MAX_DEPOSIT_VALUE);
        ERC20Mock collateral = _getCollateralFromSeed(collatoralSeed);
        dscEngine.liquidate(
            address(collateral),
            userToBeLiquidated,
            debtToCover
        );
    }

    function _getCollateralFromSeed(
        uint256 seed
    ) private view returns (ERC20Mock) {
        if (seed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }
}

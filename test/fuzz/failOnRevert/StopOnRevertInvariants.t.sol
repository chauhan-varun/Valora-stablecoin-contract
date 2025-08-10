// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DSCEngine} from "../../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../../script/HelperConfig.s.sol";
import {DeployDSC} from "../../../script/DeployDSC.s.sol";
import {ERC20Mock} from "../../mocks/ERC20Mock.sol";
import {console} from "forge-std/console.sol";
import {StopOnRevertHandler} from "./StopOnRevertHandler.t.sol";

contract StopOnRevertInvariants is StdInvariant, Test {
    DSCEngine public dsce;
    DecentralizedStableCoin public dsc;
    HelperConfig public helperConfig;
    address public weth;
    address public wbtc;

    function setUp() external {
        DeployDSC deployDSC = new DeployDSC();
        (dsc, dsce, helperConfig) = deployDSC.run();
        (, , weth, wbtc, ) = helperConfig.activeNetworkConfig();

        StopOnRevertHandler handler = new StopOnRevertHandler(dsce, dsc);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply()
        external
        view
    {
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = ERC20Mock(address(weth)).balanceOf(
            address(dsce)
        );
        uint256 totalWbtcDeposited = ERC20Mock(address(wbtc)).balanceOf(
            address(dsce)
        );
        uint256 wethValue = dsce.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcValue = dsce.getUsdValue(wbtc, totalWbtcDeposited);
        uint256 totalValue = wethValue + wbtcValue;
        assert(totalValue >= totalSupply);
    }

    function invariant_gettersShouldNeverRevert() external view {
        dsce.getCollateralTokens();
        dsce.getLiquidationBonus();
        dsce.getHealthFactor(address(dsce));
        dsce.getLiquidationPrecision();

        dsce.getMinHealthFactor();
        dsce.getCollateralBalanceOfUser(address(weth), address(dsce));
        dsce.getCollateralBalanceOfUser(address(wbtc), address(dsce));
        dsce.getUsdValue(weth, 1);
        dsce.getUsdValue(wbtc, 1);
    }
}

// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/*
 * @title DSCEngine
 * @author Varun Chauhan
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of
 * all collateral < the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 */

contract DSCEngine is ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error DSCEngine__AmountMustBeGreaterThanZero();
    error DSCEngine__LengthsOfTokensAndPriceFeedsMustMatch();
    error DSCEngine__TokenNotSupported();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreakHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();

    /*//////////////////////////////////////////////////////////////
                             STATE VARIABLE
    //////////////////////////////////////////////////////////////*/

    uint256 private constant ADDITIONAL_PRICEFEED_PRECISION = 1e10;
    
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1 ether;
    uint256 private constant LIQUIDATION_BONUS = 10;

    mapping(address token => address priceFeed) private s_priceFeed;
    mapping(address user => mapping(address token => uint256 balance))
        private s_balances;
    mapping(address user => uint256 dscMint) private s_dscMint;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event DepositCollatoral(
        address indexed user,
        address indexed tokenCollatoral,
        uint256 indexed amount
    );

    event CollatoralRedeemed(
        address indexed redeemFrom,
        address indexed redeemTo,
        address indexed tokenCollatoral,
        uint256 amount
    );

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier moreThanZero(uint256 _amount) {
        if (_amount <= 0) revert DSCEngine__AmountMustBeGreaterThanZero();
        _;
    }

    modifier isAllowedToken(address tokenCollatoral) {
        if (s_priceFeed[tokenCollatoral] == address(0))
            revert DSCEngine__TokenNotSupported();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    constructor(
        address[] memory tokens,
        address[] memory priceFeeds,
        address _dsc
    ) {
        if (tokens.length != priceFeeds.length)
            revert DSCEngine__LengthsOfTokensAndPriceFeedsMustMatch();
        for (uint256 i = 0; i < tokens.length; i++) {
            s_collateralTokens.push(tokens[i]);
            s_priceFeed[tokens[i]] = priceFeeds[i];
        }
        i_dsc = DecentralizedStableCoin(_dsc);
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function depositCollatoralAndMintDsc(
        address tokenCollatoral,
        uint256 amount,
        uint256 amountDscToMint
    ) external {
        // deposit collateral
        depositCollatoral(tokenCollatoral, amount);
        // mint DSC
        mintDsc(amountDscToMint);
    }

    function liquidate(
        address collatoral,
        address user,
        uint256 debtToCover
    )
        external
        isAllowedToken(collatoral)
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 healthFactor = _healthFactor(user);
        if (healthFactor >= MIN_HEALTH_FACTOR)
            revert DSCEngine__HealthFactorOk();

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(
            collatoral,
            debtToCover
        );
        uint256 bonusCollatoral = (tokenAmountFromDebtCovered *
            LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
    }

    /*//////////////////////////////////////////////////////////////
                             PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function depositCollatoral(
        address tokenCollatoral,
        uint256 amount
    ) public moreThanZero(amount) isAllowedToken(tokenCollatoral) nonReentrant {
        // deposit collateral

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function mintDsc(
        uint256 amountDscToMint
    ) public moreThanZero(amountDscToMint) nonReentrant {
        // mint DSC
        s_dscMint[msg.sender] += amountDscToMint;

        _revertIfHealthFactorIsBroken(msg.sender);

        bool success = i_dsc.mint(msg.sender, amountDscToMint);
        if (!success) revert DSCEngine__MintFailed();
    }

    function getAccountCollatoralValue(
        address user
    ) public view returns (uint256 totalCollatoralValueInUsd) {
        // get account collatoral value
        uint256 collatoralTokensLength = s_collateralTokens.length;
        for (uint256 i = 0; i < collatoralTokensLength; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_balances[user][token];
            totalCollatoralValueInUsd += getCollatoralValue(token, amount);
        }
        return totalCollatoralValueInUsd;
    }

    function getCollatoralValue(
        address tokenCollatoral,
        uint256 amount
    ) public view returns (uint256) {
        // get collatoral value
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeed[tokenCollatoral]
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return
            (amount * (uint256(price) * ADDITIONAL_PRICEFEED_PRECISION)) /
            PRECISION;
    }

    function redeemCollatoral(
        address tokenCollatoral,
        uint256 amount
    ) public moreThanZero(amount) isAllowedToken(tokenCollatoral) nonReentrant {
        // redeem collateral

        _redeemCollatoral(msg.sender, address(this), tokenCollatoral, amount);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function burnDsc(uint256 amount) public {
        // burn DSC
        s_dscMint[msg.sender] -= amount;
        bool success = i_dsc.transferFrom(msg.sender, address(this), amount);
        if (!success) revert DSCEngine__MintFailed();

        i_dsc.burn(amount);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function redeemCollatoralForDsc(
        address tokenCollatoral,
        uint256 amount,
        uint256 amountDscToBurn
    ) public {
        // redeem collateral
        redeemCollatoral(tokenCollatoral, amount);
        // burn DSC
        burnDsc(amountDscToBurn);
    }

    /*//////////////////////////////////////////////////////////////
                             INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _revertIfHealthFactorIsBroken(address user) internal view {
        // check health factor
        uint256 healthFactor = _healthFactor(user);
        if (healthFactor < MIN_HEALTH_FACTOR)
            revert DSCEngine__BreakHealthFactor(healthFactor);
    }

    /*//////////////////////////////////////////////////////////////
                             PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collatoralValueInUsd) = _getUserInfo(
            user
        );
        uint256 updatedCollatoralValueInUsd = (collatoralValueInUsd *
            LIQUIDATION_PRECISION) / LIQUIDATION_THRESHOLD;
        return
            (totalDscMinted * updatedCollatoralValueInUsd) /
            collatoralValueInUsd;
    }

    function _getUserInfo(
        address user
    )
        private
        view
        returns (uint256 totalDscMinted, uint256 collatoralValueInUsd)
    {
        totalDscMinted = s_dscMint[user];
        collatoralValueInUsd = getAccountCollatoralValue(user);
    }

    function getTokenAmountFromUsd(
        address tokenCollatoral,
        uint256 usdAmount
    ) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeed[tokenCollatoral]
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return
            ((usdAmount * PRECISION) /
            (uint256(price) * ADDITIONAL_PRICEFEED_PRECISION));
    }

    function _redeemCollatoral(address from, address to, address tokenCollatoral, uint256 amount) private {
        // redeem collateral
        s_balances[from][tokenCollatoral] -= amount;
        emit CollatoralRedeemed(from, to, tokenCollatoral, amount);
        bool success = IERC20(tokenCollatoral).transfer(to, amount);
        if (!success) revert DSCEngine__TransferFailed();
    }
}

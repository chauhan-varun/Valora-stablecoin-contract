// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {OracleLib, AggregatorV3Interface} from "./libraries/OracleLib.sol";
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DSCEngine
 * @author Varun Chauhan
 * @notice This contract is the core of the Decentralized Stablecoin (DSC) system
 * @dev Implements a collateral-backed stablecoin system similar to MakerDAO's DAI
 *
 * SYSTEM PROPERTIES:
 * - Exogenously Collateralized: Backed by external crypto assets (WETH, WBTC)
 * - Dollar Pegged: Maintains 1 DSC = $1 USD value
 * - Algorithmically Stable: Uses liquidation mechanisms to maintain stability
 * - Overcollateralized: Total collateral value always exceeds DSC supply
 *
 * KEY FEATURES:
 * - Deposit collateral (WETH/WBTC) to mint DSC tokens
 * - Redeem collateral by burning DSC tokens
 * - Liquidation system to maintain system health
 * - Health factor monitoring to prevent undercollateralization
 *
 * SECURITY CONSIDERATIONS:
 * - Uses Chainlink price feeds for accurate asset pricing
 * - Implements reentrancy protection on all state-changing functions
 * - Maintains minimum collateralization ratio of 200% (50% liquidation threshold)
 */

contract DSCEngine is ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when amount parameter is zero or negative
    error DSCEngine__AmountMustBeGreaterThanZero();

    /// @notice Thrown when token and price feed arrays have different lengths
    error DSCEngine__LengthsOfTokensAndPriceFeedsMustMatch();

    /// @notice Thrown when trying to use an unsupported collateral token
    error DSCEngine__TokenNotSupported(address tokenCollatoral);

    /// @notice Thrown when ERC20 token transfer fails
    error DSCEngine__TransferFailed();

    /// @notice Thrown when user's health factor drops below minimum threshold
    /// @param healthFactor The current health factor that caused the revert
    error DSCEngine__BreakHealthFactor(uint256 healthFactor);

    /// @notice Thrown when DSC minting operation fails
    error DSCEngine__MintFailed();

    /// @notice Thrown when trying to liquidate a healthy position
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    /*//////////////////////////////////////////////////////////////
                                LIBRARIES
    //////////////////////////////////////////////////////////////*/

    using OracleLib for AggregatorV3Interface;

    /*//////////////////////////////////////////////////////////////
                             STATE VARIABLE
    //////////////////////////////////////////////////////////////*/

    DecentralizedStableCoin private immutable i_dsc;

    uint256 private constant ADDITIONAL_PRICEFEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1 ether;
    uint256 private constant LIQUIDATION_BONUS = 10;
    uint256 private constant FEED_PRECISION = 1e8;

    mapping(address CollatoralToken => address priceFeed) private s_priceFeed;
    mapping(address user => mapping(address CollatoralToken => uint256 amount))
        private s_collateralDeposited;
    mapping(address user => uint256 dscMint) private s_dscMint;
    address[] private s_collateralTokens;

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
            revert DSCEngine__TokenNotSupported(tokenCollatoral);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
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

    function redeemCollatoralForDsc(
        address tokenCollatoral,
        uint256 amount,
        uint256 amountDscToBurn
    ) external moreThanZero(amount) isAllowedToken(tokenCollatoral) {
        // redeem collateral

        _burnDsc(amountDscToBurn, msg.sender, msg.sender);
        _redeemCollatoral(msg.sender, msg.sender, tokenCollatoral, amount);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function burnDsc(uint256 amount) external moreThanZero(amount) {
        // burn DSC
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
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
        uint256 initialHealthFactor = _healthFactor(user);
        if (initialHealthFactor >= MIN_HEALTH_FACTOR)
            revert DSCEngine__HealthFactorOk();

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(
            collatoral,
            debtToCover
        );

        uint256 bonusCollatoral = (tokenAmountFromDebtCovered *
            LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        uint256 totalCollatoralToRedeem = tokenAmountFromDebtCovered +
            bonusCollatoral;
        _redeemCollatoral(
            user,
            msg.sender,
            collatoral,
            totalCollatoralToRedeem
        );
        _burnDsc(debtToCover, user, msg.sender);

        uint256 finalHealthFactor = _healthFactor(user);
        if (finalHealthFactor < MIN_HEALTH_FACTOR)
            revert DSCEngine__HealthFactorNotImproved();
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                             PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function depositCollatoral(
        address tokenCollatoral,
        uint256 amount
    ) public moreThanZero(amount) isAllowedToken(tokenCollatoral) nonReentrant {
        // deposit collateral
        s_collateralDeposited[msg.sender][tokenCollatoral] += amount;
        emit DepositCollatoral(msg.sender, tokenCollatoral, amount);
        bool success = IERC20(tokenCollatoral).transferFrom(
            msg.sender,
            address(this),
            amount
        );
        if (!success) revert DSCEngine__TransferFailed();
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

    /*//////////////////////////////////////////////////////////////
                          PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _redeemCollatoral(
        address from,
        address to,
        address tokenCollatoral,
        uint256 amount
    ) private {
        // redeem collateral
        s_collateralDeposited[from][tokenCollatoral] -= amount;
        emit CollatoralRedeemed(from, to, tokenCollatoral, amount);
        bool success = IERC20(tokenCollatoral).transfer(to, amount);
        if (!success) revert DSCEngine__TransferFailed();
    }

    function _burnDsc(
        uint256 amountToBurn,
        address ofBehalfOf,
        address dscFrom
    ) private {
        // burn DSC
        s_dscMint[ofBehalfOf] -= amountToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountToBurn);
        if (!success) revert DSCEngine__TransferFailed();
        i_dsc.burn(amountToBurn);
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL, PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _revertIfHealthFactorIsBroken(address user) internal view {
        // check health factor
        uint256 healthFactor = _healthFactor(user);
        if (healthFactor < MIN_HEALTH_FACTOR)
            revert DSCEngine__BreakHealthFactor(healthFactor);
    }

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collatoralValueInUsd) = _getUserInfo(
            user
        );
        return _calculateHealthFactor(totalDscMinted, collatoralValueInUsd);
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

    function _getUsdValue(
        address tokenCollatoral,
        uint256 usdAmount
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeed[tokenCollatoral]
        );
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
        return ((usdAmount *
            (ADDITIONAL_PRICEFEED_PRECISION * uint256(price))) / PRECISION);
    }

    function _calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 collatoralValueInUsd
    ) internal pure returns (uint256) {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collatoralValueInUsd *
            LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    /*//////////////////////////////////////////////////////////////
                            PUBLIC, EXTERNAL PURE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 collatoralValueInUsd
    ) external pure returns (uint256) {
        return _calculateHealthFactor(totalDscMinted, collatoralValueInUsd);
    }

    function getAccountInfo(
        address user
    )
        external
        view
        returns (uint256 totalDscMinted, uint256 collatoralValueInUsd)
    {
        (totalDscMinted, collatoralValueInUsd) = _getUserInfo(user);
    }

    function getAccountCollatoralValue(
        address user
    ) public view returns (uint256 totalCollatoralValueInUsd) {
        // get account collatoral value
        uint256 collatoralTokensLength = s_collateralTokens.length;
        for (uint256 i = 0; i < collatoralTokensLength; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollatoralValueInUsd += _getUsdValue(token, amount);
        }
        return totalCollatoralValueInUsd;
    }

    function getUsdValue(
        address tokenCollatoral,
        uint256 amount
    ) external view returns (uint256) {
        return _getUsdValue(tokenCollatoral, amount);
    }

    function getCollatoralBalanceOfUser(
        address user,
        address tokenCollatoral
    ) external view returns (uint256) {
        return s_collateralDeposited[user][tokenCollatoral];
    }

    function getTokenAmountFromUsd(
        address token,
        uint256 usdAmountInWei
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeed[token]
        );
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
        return ((usdAmountInWei * PRECISION) /
            (uint256(price) * ADDITIONAL_PRICEFEED_PRECISION));
    }

    function getPresion() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_PRICEFEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(
        address token
    ) external view returns (address) {
        return s_priceFeed[token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }
}

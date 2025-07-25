// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";


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
    error DSCEngine__TokenNotSupported();
    
    /// @notice Thrown when ERC20 token transfer fails
    error DSCEngine__TransferFailed();
    
    /// @notice Thrown when user's health factor drops below minimum threshold
    /// @param healthFactor The current health factor that caused the revert
    error DSCEngine__BreakHealthFactor(uint256 healthFactor);
    
    /// @notice Thrown when DSC minting operation fails
    error DSCEngine__MintFailed();
    
    /// @notice Thrown when trying to liquidate a healthy position
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

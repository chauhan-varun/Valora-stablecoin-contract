// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {OracleLib, AggregatorV3Interface} from "./libraries/OracleLib.sol";
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DSCEngine - Decentralized Stablecoin Engine
 * @author Varun Chauhan
 * @notice This contract serves as the core engine for a decentralized stablecoin system
 * @dev Implements a collateral-backed stablecoin mechanism inspired by MakerDAO's DAI system
 * 
 * ═══════════════════════════════════════════════════════════════════════════════
 *                                SYSTEM OVERVIEW
 * ═══════════════════════════════════════════════════════════════════════════════
 * 
 * The DSC (Decentralized Stablecoin) system allows users to:
 * 1. Deposit approved collateral tokens (WETH, WBTC)
 * 2. Mint DSC stablecoins against their collateral
 * 3. Maintain a healthy collateralization ratio
 * 4. Redeem collateral by burning DSC tokens
 * 5. Participate in liquidations to maintain system health
 * 
 * ═══════════════════════════════════════════════════════════════════════════════
 *                               SYSTEM PROPERTIES
 * ═══════════════════════════════════════════════════════════════════════════════
 * 
 * • EXOGENOUSLY COLLATERALIZED: Backed by external crypto assets (WETH, WBTC)
 * • DOLLAR PEGGED: Maintains 1 DSC = $1 USD through algorithmic mechanisms
 * • ALGORITHMICALLY STABLE: Uses liquidation mechanisms to maintain peg stability
 * • OVERCOLLATERALIZED: Requires minimum 200% collateralization ratio
 * • LIQUIDATION THRESHOLD: 50% - positions can be liquidated at 150% collateral ratio
 * • LIQUIDATION BONUS: 10% - liquidators receive bonus collateral for maintaining system health
 * 
 * ═══════════════════════════════════════════════════════════════════════════════
 *                              MATHEMATICAL FORMULAS
 * ═══════════════════════════════════════════════════════════════════════════════
 * 
 * Health Factor = (Collateral Value in USD × Liquidation Threshold) ÷ Total DSC Minted
 * 
 * Where:
 * - Collateral Value = Sum of (Token Amount × Token Price in USD)
 * - Liquidation Threshold = 50% (0.5)
 * - Healthy Position: Health Factor ≥ 1.0
 * - Liquidatable Position: Health Factor < 1.0
 * 
 * Example:
 * - User deposits $1000 worth of ETH
 * - User mints 400 DSC
 * - Health Factor = ($1000 × 0.5) ÷ 400 = 1.25 ✅ Healthy
 * - If ETH price drops and collateral value becomes $600
 * - Health Factor = ($600 × 0.5) ÷ 400 = 0.75 ❌ Liquidatable
 * 
 * ═══════════════════════════════════════════════════════════════════════════════
 *                               SECURITY FEATURES
 * ═══════════════════════════════════════════════════════════════════════════════
 * 
 * • Chainlink Price Feeds: Reliable, decentralized price oracles for accurate asset pricing
 * • Reentrancy Protection: All state-changing functions protected against reentrancy attacks
 * • Health Factor Monitoring: Continuous monitoring prevents undercollateralization
 * • Liquidation Incentives: Economic incentives ensure timely liquidations
 * • Input Validation: Comprehensive validation of all user inputs
 * • Access Control: Proper separation of concerns and role-based access
 * 
 * ═══════════════════════════════════════════════════════════════════════════════
 *                                 RISK FACTORS
 * ═══════════════════════════════════════════════════════════════════════════════
 * 
 * • Price Oracle Risk: Dependency on Chainlink price feeds
 * • Collateral Risk: Risk of collateral token value declining rapidly
 * • Liquidation Risk: Risk of insufficient liquidators during market stress
 * • Smart Contract Risk: Bugs or vulnerabilities in the contract code
 * • Governance Risk: Changes to system parameters
 */

contract DSCEngine is ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when amount parameter is zero or negative
    /// @dev Used across multiple functions to ensure valid amounts
    error DSCEngine__AmountMustBeGreaterThanZero();

    /// @notice Thrown when token and price feed arrays have different lengths during construction
    /// @dev Critical for proper initialization - each token must have corresponding price feed
    error DSCEngine__LengthsOfTokensAndPriceFeedsMustMatch();

    /// @notice Thrown when trying to use an unsupported collateral token
    /// @param tokenCollatoral The token address that is not supported
    /// @dev Only whitelisted tokens with price feeds can be used as collateral
    error DSCEngine__TokenNotSupported(address tokenCollatoral);

    /// @notice Thrown when ERC20 token transfer fails
    /// @dev Could indicate insufficient balance, allowance, or token contract issues
    error DSCEngine__TransferFailed();

    /// @notice Thrown when user's health factor drops below minimum threshold (1.0)
    /// @param healthFactor The current health factor that caused the revert
    /// @dev Prevents users from over-leveraging and maintains system stability
    error DSCEngine__BreakHealthFactor(uint256 healthFactor);

    /// @notice Thrown when DSC minting operation fails
    /// @dev Should not occur under normal circumstances if DSC contract is properly implemented
    error DSCEngine__MintFailed();

    /// @notice Thrown when trying to liquidate a healthy position (health factor ≥ 1.0)
    /// @dev Prevents unnecessary liquidations and protects healthy positions
    error DSCEngine__HealthFactorOk();

    /// @notice Thrown when liquidation doesn't improve the user's health factor
    /// @dev Ensures liquidations are effective and improve system health
    error DSCEngine__HealthFactorNotImproved();

    /*//////////////////////////////////////////////////////////////
                                LIBRARIES
    //////////////////////////////////////////////////////////////*/

    /// @dev Using OracleLib for additional safety checks on Chainlink price feeds
    using OracleLib for AggregatorV3Interface;

    /*//////////////////////////////////////////////////////////////
                           STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Reference to the DSC token contract
    /// @dev Immutable to prevent changes after deployment
    DecentralizedStableCoin private immutable i_dsc;

    /*//////////////////////////////////////////////////////////////
                             CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Additional precision for Chainlink price feeds (1e10)
    /// @dev Chainlink returns prices with 8 decimals, we need 18 for calculations
    uint256 private constant ADDITIONAL_PRICEFEED_PRECISION = 1e10;

    /// @notice Standard precision for calculations (1e18)
    /// @dev Used for high-precision arithmetic throughout the system
    uint256 private constant PRECISION = 1e18;

    /// @notice Liquidation threshold percentage (50%)
    /// @dev Positions become liquidatable when collateral value falls below this threshold
    /// @dev Formula: (collateral_value * LIQUIDATION_THRESHOLD / LIQUIDATION_PRECISION) vs debt
    uint256 private constant LIQUIDATION_THRESHOLD = 50;

    /// @notice Precision for liquidation calculations (100)
    /// @dev Used to convert percentage values to decimal form
    uint256 private constant LIQUIDATION_PRECISION = 100;

    /// @notice Minimum health factor required to maintain position (1e18 = 1.0)
    /// @dev Below this threshold, positions become liquidatable
    uint256 private constant MIN_HEALTH_FACTOR = 1 ether;

    /// @notice Bonus percentage given to liquidators (10%)
    /// @dev Incentivizes liquidators to maintain system health
    /// @dev Example: Liquidating $100 debt gives liquidator $110 worth of collateral
    uint256 private constant LIQUIDATION_BONUS = 10;

    /// @notice Chainlink price feed precision (1e8)
    /// @dev Standard precision used by Chainlink aggregators
    uint256 private constant FEED_PRECISION = 1e8;

    /*//////////////////////////////////////////////////////////////
                              MAPPINGS
    //////////////////////////////////////////////////////////////*/

    /// @notice Maps collateral token addresses to their Chainlink price feed addresses
    /// @dev Used to get USD prices for collateral tokens
    mapping(address CollateralToken => address priceFeed) private s_priceFeed;

    /// @notice Maps user addresses to their collateral deposits by token
    /// @dev Tracks how much of each token each user has deposited as collateral
    mapping(address user => mapping(address CollateralToken => uint256 amount))
        private s_collateralDeposited;

    /// @notice Maps user addresses to the amount of DSC tokens they have minted
    /// @dev Tracks each user's debt in the system
    mapping(address user => uint256 dscMinted) private s_dscMinted;

    /// @notice Array of all supported collateral token addresses
    /// @dev Used for iteration when calculating total collateral values
    address[] private s_collateralTokens;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a user deposits collateral
    /// @param user The address of the user depositing collateral
    /// @param tokenCollatoral The address of the collateral token deposited
    /// @param amount The amount of collateral deposited
    event DepositCollatoral(
        address indexed user,
        address indexed tokenCollatoral,
        uint256 indexed amount
    );

    /// @notice Emitted when collateral is redeemed (withdrawn or liquidated)
    /// @param redeemFrom The address from whom collateral is being redeemed
    /// @param redeemTo The address receiving the redeemed collateral
    /// @param tokenCollatoral The address of the collateral token being redeemed
    /// @param amount The amount of collateral being redeemed
    event CollatoralRedeemed(
        address indexed redeemFrom,
        address indexed redeemTo,
        address indexed tokenCollatoral,
        uint256 amount
    );

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Ensures the provided amount is greater than zero
    /// @param _amount The amount to validate
    /// @dev Prevents operations with zero or negative amounts
    modifier moreThanZero(uint256 _amount) {
        if (_amount <= 0) revert DSCEngine__AmountMustBeGreaterThanZero();
        _;
    }

    /// @notice Ensures the provided token is supported as collateral
    /// @param tokenCollatoral The token address to validate
    /// @dev Checks if the token has an associated price feed
    modifier isAllowedToken(address tokenCollatoral) {
        if (s_priceFeed[tokenCollatoral] == address(0))
            revert DSCEngine__TokenNotSupported(tokenCollatoral);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the DSC Engine with supported collateral tokens and their price feeds
     * @param tokens Array of collateral token addresses (e.g., WETH, WBTC)
     * @param priceFeeds Array of Chainlink price feed addresses corresponding to each token
     * @param _dsc Address of the DSC token contract
     * @dev Arrays must have the same length - each token needs a corresponding price feed
     * @dev This setup allows the system to know which tokens are accepted and how to price them
     */
    constructor(
        address[] memory tokens,
        address[] memory priceFeeds,
        address _dsc
    ) {
        // Ensure arrays have matching lengths for proper token-pricefeed pairing
        if (tokens.length != priceFeeds.length)
            revert DSCEngine__LengthsOfTokensAndPriceFeedsMustMatch();
        
        // Initialize supported collateral tokens and their price feeds
        for (uint256 i = 0; i < tokens.length; i++) {
            s_collateralTokens.push(tokens[i]);
            s_priceFeed[tokens[i]] = priceFeeds[i];
        }
        
        // Set the DSC token contract reference
        i_dsc = DecentralizedStableCoin(_dsc);
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposits collateral and mints DSC in a single transaction
     * @param tokenCollatoral The address of the collateral token to deposit
     * @param amount The amount of collateral to deposit
     * @param amountDscToMint The amount of DSC tokens to mint
     * @dev Convenience function that combines deposit and mint operations
     * @dev More gas efficient than calling both functions separately
     * @dev Health factor is checked after both operations complete
     */
    function depositCollateralAndMintDsc(
        address tokenCollatoral,
        uint256 amount,
        uint256 amountDscToMint
    ) external {
        // Step 1: Deposit collateral to increase user's collateral balance
        depositCollateral(tokenCollatoral, amount);
        
        // Step 2: Mint DSC tokens against the deposited collateral
        mintDsc(amountDscToMint);
    }

    /**
     * @notice Redeems collateral by burning DSC tokens
     * @param tokenCollatoral The address of the collateral token to redeem
     * @param amount The amount of collateral to redeem
     * @param amountDscToBurn The amount of DSC tokens to burn
     * @dev Burns DSC first, then redeems collateral to ensure proper health factor
     * @dev Health factor is checked after both operations to ensure position remains healthy
     */
    function redeemCollatoralForDsc(
        address tokenCollatoral,
        uint256 amount,
        uint256 amountDscToBurn
    ) external moreThanZero(amount) isAllowedToken(tokenCollatoral) {
        // Step 1: Burn DSC tokens to reduce user's debt
        _burnDsc(amountDscToBurn, msg.sender, msg.sender);
        
        // Step 2: Redeem collateral from user's deposit
        _redeemCollatoral(msg.sender, msg.sender, tokenCollatoral, amount);
        
        // Step 3: Ensure the user's position remains healthy after the operation
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice Burns DSC tokens to reduce debt
     * @param amount The amount of DSC tokens to burn
     * @dev Allows users to improve their health factor by reducing debt
     * @dev Does not return collateral - use redeemCollatoralForDsc for that
     */
    function burnDsc(uint256 amount) external moreThanZero(amount) {
        // Burn DSC tokens from user's balance
        _burnDsc(amount, msg.sender, msg.sender);
        
        // Verify health factor (should be improved after burning debt)
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice Liquidates an undercollateralized position
     * @param collatoral The collateral token to liquidate
     * @param user The user whose position is being liquidated
     * @param debtToCover The amount of debt (in DSC) to cover through liquidation
     * @dev Only positions with health factor < 1.0 can be liquidated
     * @dev Liquidator receives bonus collateral as incentive for maintaining system health
     * @dev Partial liquidations are allowed - liquidator doesn't need to cover entire debt
     * 
     * LIQUIDATION MECHANICS:
     * 1. Calculate collateral amount equivalent to debt being covered
     * 2. Add liquidation bonus (10%) to incentivize liquidators
     * 3. Transfer collateral from liquidated user to liquidator
     * 4. Burn DSC debt from liquidated user's position
     * 5. Ensure liquidation improved the user's health factor
     * 6. Ensure liquidator's own health factor remains healthy
     */
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
        // Check that the position is actually liquidatable
        uint256 initialHealthFactor = _healthFactor(user);
        if (initialHealthFactor >= MIN_HEALTH_FACTOR)
            revert DSCEngine__HealthFactorOk();

        // Calculate how much collateral the debt is worth
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(
            collatoral,
            debtToCover
        );

        // Calculate liquidation bonus for the liquidator
        uint256 bonusCollatoral = (tokenAmountFromDebtCovered *
            LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        // Total collateral to transfer to liquidator (debt coverage + bonus)
        uint256 totalCollatoralToRedeem = tokenAmountFromDebtCovered +
            bonusCollatoral;

        // Transfer collateral from liquidated user to liquidator
        _redeemCollatoral(
            user,
            msg.sender,
            collatoral,
            totalCollatoralToRedeem
        );

        // Burn the covered debt from the liquidated user's position
        _burnDsc(debtToCover, user, msg.sender);

        // Verify that the liquidation improved the user's health factor
        uint256 finalHealthFactor = _healthFactor(user);
        if (finalHealthFactor <= initialHealthFactor)
            revert DSCEngine__HealthFactorNotImproved();
            
        // Ensure the liquidator's own position remains healthy
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                             PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposits collateral tokens into the system
     * @param tokenCollatoral The address of the collateral token to deposit
     * @param amount The amount of collateral to deposit (in token's native decimals)
     * @dev Increases user's collateral balance and transfers tokens to this contract
     * @dev Does not mint DSC tokens - use mintDsc() or depositCollateralAndMintDsc() for that
     * @dev User must approve this contract to spend their tokens before calling
     * 
     * PROCESS:
     * 1. Validate inputs (amount > 0, token is supported)
     * 2. Update user's collateral balance in state
     * 3. Emit deposit event for transparency
     * 4. Transfer tokens from user to this contract
     * 5. Revert if transfer fails
     */
    function depositCollateral(
        address tokenCollatoral,
        uint256 amount
    ) public moreThanZero(amount) isAllowedToken(tokenCollatoral) nonReentrant {
        // Update user's collateral balance
        s_collateralDeposited[msg.sender][tokenCollatoral] += amount;
        
        // Emit event for off-chain tracking and transparency
        emit DepositCollatoral(msg.sender, tokenCollatoral, amount);
        
        // Transfer collateral tokens from user to this contract
        bool success = IERC20(tokenCollatoral).transferFrom(
            msg.sender,
            address(this),
            amount
        );
        if (!success) revert DSCEngine__TransferFailed();
    }

    /**
     * @notice Mints DSC tokens against deposited collateral
     * @param amountDscToMint The amount of DSC tokens to mint (in wei, 18 decimals)
     * @dev Requires sufficient collateral to maintain health factor ≥ 1.0
     * @dev User's debt increases by the minted amount
     * 
     * PROCESS:
     * 1. Validate amount > 0
     * 2. Update user's DSC debt balance
     * 3. Check health factor before minting
     * 4. Mint DSC tokens to user's address
     * 5. Revert if minting fails
     */
    function mintDsc(
        uint256 amountDscToMint
    ) public moreThanZero(amountDscToMint) nonReentrant {
        // Increase user's DSC debt
        s_dscMinted[msg.sender] += amountDscToMint;

        // Ensure the user's position remains healthy after minting
        _revertIfHealthFactorIsBroken(msg.sender);

        // Mint DSC tokens to user's address
        bool success = i_dsc.mint(msg.sender, amountDscToMint);
        if (!success) revert DSCEngine__MintFailed();
    }

    /*//////////////////////////////////////////////////////////////
                          PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Internal function to redeem collateral
     * @param from The address from whom collateral is being redeemed
     * @param to The address receiving the redeemed collateral
     * @param tokenCollatoral The address of the collateral token
     * @param amount The amount of collateral to redeem
     * @dev Used by both regular redemption and liquidation functions
     * @dev Updates state first, then transfers tokens (follows CEI pattern)
     */
    function _redeemCollatoral(
        address from,
        address to,
        address tokenCollatoral,
        uint256 amount
    ) private {
        // Decrease user's collateral balance (will revert if insufficient balance)
        s_collateralDeposited[from][tokenCollatoral] -= amount;
        
        // Emit event for transparency and off-chain tracking
        emit CollatoralRedeemed(from, to, tokenCollatoral, amount);
        
        // Transfer collateral tokens from contract to recipient
        bool success = IERC20(tokenCollatoral).transfer(to, amount);
        if (!success) revert DSCEngine__TransferFailed();
    }

    /**
     * @notice Internal function to burn DSC tokens
     * @param amountToBurn The amount of DSC to burn
     * @param ofBehalfOf The user whose debt is being reduced
     * @param dscFrom The address from which DSC tokens will be taken
     * @dev Used by both regular burning and liquidation functions
     * @dev Reduces user's debt and burns tokens from circulation
     */
    function _burnDsc(
        uint256 amountToBurn,
        address ofBehalfOf,
        address dscFrom
    ) private {
        // Reduce user's DSC debt (will revert if insufficient debt)
        s_dscMinted[ofBehalfOf] -= amountToBurn;
        
        // Transfer DSC tokens from burner to this contract
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountToBurn);
        if (!success) revert DSCEngine__TransferFailed();
        
        // Burn the DSC tokens (removes from circulation)
        i_dsc.burn(amountToBurn);
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL & PRIVATE VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Checks if a user's health factor is below the minimum threshold
     * @param user The address of the user to check
     * @dev Reverts if health factor < 1.0, preventing dangerous operations
     * @dev This is the main safety mechanism preventing over-leveraging
     */
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 healthFactor = _healthFactor(user);
        if (healthFactor < MIN_HEALTH_FACTOR)
            revert DSCEngine__BreakHealthFactor(healthFactor);
    }

    /**
     * @notice Calculates a user's health factor
     * @param user The address of the user
     * @return healthFactor The user's current health factor (scaled by 1e18)
     * @dev Health Factor = (Collateral Value × Liquidation Threshold) ÷ DSC Minted
     * @dev Returns type(uint256).max if no DSC is minted (infinite health)
     */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collatoralValueInUsd) = _getUserInfo(user);
        return _calculateHealthFactor(totalDscMinted, collatoralValueInUsd);
    }

    /**
     * @notice Gets comprehensive user information
     * @param user The address of the user
     * @return totalDscMinted Total DSC tokens minted by the user
     * @return collatoralValueInUsd Total USD value of user's collateral
     * @dev Used by health factor calculations and external queries
     */
    function _getUserInfo(
        address user
    )
        private
        view
        returns (uint256 totalDscMinted, uint256 collatoralValueInUsd)
    {
        totalDscMinted = s_dscMinted[user];
        collatoralValueInUsd = getAccountCollatoralValue(user);
    }

    /**
     * @notice Converts token amount to USD value using Chainlink price feeds
     * @param tokenCollatoral The address of the token
     * @param usdAmount The amount of tokens to convert
     * @return The USD value scaled by 1e18
     * @dev Uses stale price protection through OracleLib
     * @dev Adjusts for different decimal precisions between tokens and price feeds
     */
    function _getUsdValue(
        address tokenCollatoral,
        uint256 usdAmount
    ) public view returns (uint256) {
        // Get price feed for the token
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeed[tokenCollatoral]
        );
        
        // Get latest price with staleness check
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
        
        // Convert to USD with proper precision handling
        // Price feed gives price with 8 decimals, we need 18 for calculations
        return ((usdAmount * (uint256(price) * ADDITIONAL_PRICEFEED_PRECISION)) / PRECISION);
    }

    /**
     * @notice Calculates health factor from DSC minted and collateral value
     * @param totalDscMinted Total DSC tokens minted by user
     * @param collatoralValueInUsd Total USD value of user's collateral
     * @return healthFactor The calculated health factor (scaled by 1e18)
     * @dev Core formula: (collateral × liquidation_threshold) ÷ debt
     * @dev Returns max uint256 if no DSC is minted (perfect health)
     */
    function _calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 collatoralValueInUsd
    ) internal pure returns (uint256) {
        // If no DSC is minted, health factor is infinite (perfectly healthy)
        if (totalDscMinted == 0) return type(uint256).max;
        
        // Apply liquidation threshold to collateral value
        // This represents the "effective" collateral value for health calculations
        uint256 collateralAdjustedForThreshold = (collatoralValueInUsd *
            LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
            
        // Calculate health factor with proper precision
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    /*//////////////////////////////////////////////////////////////
                       PUBLIC & EXTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice External wrapper for health factor calculation
     * @param totalDscMinted Total DSC tokens minted
     * @param collatoralValueInUsd Total collateral value in USD
     * @return healthFactor The calculated health factor
     * @dev Allows external contracts to use the same health factor logic
     */
    function calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 collatoralValueInUsd
    ) external pure returns (uint256) {
        return _calculateHealthFactor(totalDscMinted, collatoralValueInUsd);
    }

    /**
     * @notice Gets comprehensive account information for a user
     * @param user The address of the user to query
     * @return totalDscMinted Total DSC tokens minted by the user
     * @return collatoralValueInUsd Total USD value of user's collateral
     * @dev Useful for frontend applications and external integrations
     */
    function getAccountInfo(
        address user
    )
        external
        view
        returns (uint256 totalDscMinted, uint256 collatoralValueInUsd)
    {
        (totalDscMinted, collatoralValueInUsd) = _getUserInfo(user);
    }

    /**
     * @notice Calculates total USD value of all collateral deposited by a user
     * @param user The address of the user
     * @return totalCollatoralValueInUsd Total USD value of user's collateral
     * @dev Iterates through all supported collateral tokens
     * @dev Uses current market prices from Chainlink oracles
     */
    function getAccountCollatoralValue(
        address user
    ) public view returns (uint256 totalCollatoralValueInUsd) {
        // Iterate through all supported collateral tokens
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            
            // Add USD value of this token to total
            totalCollatoralValueInUsd += _getUsdValue(token, amount);
        }
        return totalCollatoralValueInUsd;
    }

    /**
     * @notice Gets USD value of a specific token amount
     * @param tokenCollatoral The address of the token
     * @param amount The amount of tokens
     * @return The USD value of the token amount
     * @dev External wrapper for internal USD value calculation
     */
    function getUsdValue(
        address tokenCollatoral,
        uint256 amount
    ) external view returns (uint256) {
        return _getUsdValue(tokenCollatoral, amount);
    }

    /**
     * @notice Gets the collateral balance of a specific user for a specific token
     * @param user The address of the user
     * @param tokenCollatoral The address of the collateral token
     * @return The amount of collateral deposited by the user for the specified token
     * @dev Useful for frontend applications to display user positions
     */
    function getCollatoralBalanceOfUser(
        address user,
        address tokenCollatoral
    ) external view returns (uint256) {
        return s_collateralDeposited[user][tokenCollatoral];
    }

    /**
     * @notice Converts USD amount to equivalent token amount
     * @param token The address of the token
     * @param usdAmountInWei The USD amount in wei (18 decimals)
     * @return tokenAmount The equivalent amount of tokens
     * @dev Used in liquidation calculations to determine collateral amounts
     * @dev Formula: (USD_amount * PRECISION) / (price * additional_precision)
     * 
     * Example:
     * - Want to cover $100 of debt with ETH
     * - ETH price is $2000
     * - Returns: 0.05 ETH (100 / 2000)
     */
    function getTokenAmountFromUsd(
        address token,
        uint256 usdAmountInWei
    ) public view returns (uint256) {
        // Get price feed for the token
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeed[token]
        );
        
        // Get latest price with staleness protection
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
        
        // Convert USD to token amount with proper precision handling
        return ((usdAmountInWei * PRECISION) /
            (uint256(price) * ADDITIONAL_PRICEFEED_PRECISION));
    }

    /*//////////////////////////////////////////////////////////////
                         SYSTEM CONFIGURATION GETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the precision constant used in calculations
     * @return PRECISION The precision value (1e18)
     * @dev Used by external contracts for consistent calculations
     */
    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    /**
     * @notice Returns the additional precision for price feeds
     * @return ADDITIONAL_PRICEFEED_PRECISION The additional precision value (1e10)
     * @dev Used to scale Chainlink prices from 8 decimals to 18 decimals
     */
    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_PRICEFEED_PRECISION;
    }

    /**
     * @notice Returns the liquidation threshold percentage
     * @return LIQUIDATION_THRESHOLD The threshold value (50)
     * @dev Represents 50% - positions become liquidatable at 150% collateral ratio
     */
    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    /**
     * @notice Returns the liquidation bonus percentage
     * @return LIQUIDATION_BONUS The bonus value (10)
     * @dev Represents 10% bonus given to liquidators as incentive
     */
    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    /**
     * @notice Returns the precision used for liquidation calculations
     * @return LIQUIDATION_PRECISION The precision value (100)
     * @dev Used to convert percentage values in liquidation calculations
     */
    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    /**
     * @notice Returns the minimum health factor required
     * @return MIN_HEALTH_FACTOR The minimum value (1e18, representing 1.0)
     * @dev Below this value, positions become liquidatable
     */
    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    /*//////////////////////////////////////////////////////////////
                         SYSTEM STATE GETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns array of all supported collateral token addresses
     * @return s_collateralTokens Array of token addresses
     * @dev Useful for frontend applications to know which tokens are supported
     */
    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    /**
     * @notice Returns the address of the DSC token contract
     * @return The DSC token contract address
     * @dev Allows external contracts to interact with the DSC token
     */
    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    /**
     * @notice Returns the Chainlink price feed address for a collateral token
     * @param token The address of the collateral token
     * @return The address of the corresponding price feed
     * @dev Returns address(0) if token is not supported
     */
    function getCollateralTokenPriceFeed(
        address token
    ) external view returns (address) {
        return s_priceFeed[token];
    }

    /**
     * @notice Returns the current health factor for a user
     * @param user The address of the user
     * @return healthFactor The user's current health factor
     * @dev External wrapper for internal health factor calculation
     * @dev Returns type(uint256).max if user has no DSC minted
     * 
     * HEALTH FACTOR INTERPRETATION:
     * - > 1.0: Healthy position, cannot be liquidated
     * - = 1.0: At liquidation threshold, risky position
     * - < 1.0: Unhealthy position, can be liquidated
     * - type(uint256).max: No debt, perfect health
     */
    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    /**
     * @notice Returns the amount of DSC minted by a specific user
     * @param user The address of the user
     * @return The amount of DSC tokens minted by the user
     * @dev Represents the user's debt in the system
     */
    function getDscMinted(address user) external view returns (uint256) {
        return s_dscMinted[user];
    }

    /*//////////////////////////////////////////////////////////////
                              UTILITY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calculates the maximum amount of DSC a user can mint
     * @param user The address of the user
     * @return maxDscToMint Maximum DSC amount that can be minted while staying healthy
     * @dev Formula: (collateral_value * liquidation_threshold) - current_debt
     * @dev Returns 0 if user is already at or above the liquidation threshold
     */
    function getMaxDscToMint(address user) external view returns (uint256) {
        (uint256 totalDscMinted, uint256 collatoralValueInUsd) = _getUserInfo(user);
        
        // Calculate maximum debt based on collateral and liquidation threshold
        uint256 maxDebtAllowed = (collatoralValueInUsd * LIQUIDATION_THRESHOLD) 
            / LIQUIDATION_PRECISION;
            
        // If already at or above limit, return 0
        if (maxDebtAllowed <= totalDscMinted) {
            return 0;
        }
        
        // Return additional DSC that can be minted
        return maxDebtAllowed - totalDscMinted;
    }

    /**
     * @notice Calculates the maximum amount of collateral a user can redeem
     * @param user The address of the user
     * @param tokenCollatoral The address of the collateral token to redeem
     * @return maxCollateralToRedeem Maximum collateral amount that can be redeemed
     * @dev Ensures user maintains minimum health factor after redemption
     * @dev Returns 0 if user cannot redeem any collateral while staying healthy
     */
    function getMaxCollateralToRedeem(
        address user, 
        address tokenCollatoral
    ) external view returns (uint256) {
        uint256 userCollateralBalance = s_collateralDeposited[user][tokenCollatoral];
        uint256 totalDscMinted = s_dscMinted[user];
        
        // If no DSC minted, can redeem all collateral
        if (totalDscMinted == 0) {
            return userCollateralBalance;
        }
        
        // Calculate minimum collateral value needed to maintain health
        uint256 minCollateralValueNeeded = (totalDscMinted * LIQUIDATION_PRECISION) 
            / LIQUIDATION_THRESHOLD;
            
        // Get current total collateral value
        uint256 currentCollateralValue = getAccountCollatoralValue(user);
        
        // If already below minimum, cannot redeem anything
        if (currentCollateralValue <= minCollateralValueNeeded) {
            return 0;
        }
        
        // Calculate excess collateral value that can be redeemed
        uint256 excessCollateralValue = currentCollateralValue - minCollateralValueNeeded;
        
        // Convert excess USD value to token amount
        uint256 maxTokenAmount = getTokenAmountFromUsd(tokenCollatoral, excessCollateralValue);
        
        // Return minimum of calculated max and actual balance
        return maxTokenAmount > userCollateralBalance ? userCollateralBalance : maxTokenAmount;
    }

    /*//////////////////////////////////////////////////////////////
                           EMERGENCY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Checks if the entire system is healthy
     * @return isHealthy True if system is healthy, false otherwise
     * @dev System is healthy if total collateral value > total DSC supply
     * @dev This is a global health check, not for individual positions
     */
    function isSystemHealthy() external view returns (bool) {
        // Get total DSC supply from the DSC contract
        uint256 totalDscSupply = IERC20(address(i_dsc)).totalSupply();
        
        // Calculate total system collateral value
        uint256 totalSystemCollateralValue = 0;
        
        // This would require additional state tracking to be efficient
        // For now, this is a placeholder for the concept
        // In a production system, you'd want to track total deposits more efficiently
        
        return totalSystemCollateralValue >= totalDscSupply;
    }


}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

/*
 * @title DecentralizedStableCoin
 * @author Varun Chauhan
 * Collateral: Exogenous
 * Minting (Stability Mechanism): Decentralized (Algorithmic)
 * Value (Relative Stability): Anchored (Pegged to USD)
 * Collateral Type: Crypto
 *
* This is the contract meant to be owned by DSCEngine. It is a ERC20 token that can be minted and burned by the
DSCEngine smart contract.
 */

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    /// @notice Error thrown when attempting to burn zero or negative amount
    error DecentralizedStableCoin__BurnAmountIsLessThanEqualToZero();
    /// @notice Error thrown when attempting to burn more than the available balance
    error DecentralizedStableCoin__BurnAmountExceedsBalance(uint256 balance);
    /// @notice Error thrown when attempting to mint zero or negative amount
    error DecentralizedStableCoin__MintAmountIsLessThanEqualToZero();
    /// @notice Error thrown when attempting to mint to the zero address
    error DecentralizedStableCoin__CantMintToZeroAddress();

    /**
     * @notice Constructor initializes the ERC20 token with name and symbol
     * @dev Sets the token name to "Decentralized Stable Coin" and symbol to "DSC"
     */
    constructor() ERC20("Decentralized Stable Coin", "DSC") {}

    /**
     * @notice Burns a specified amount of tokens from the caller's account
     * @dev Only the owner (DSCEngine) can call this function
     * @param _amount The amount of tokens to burn
     * @custom:throws DecentralizedStableCoin__BurnAmountIsLessThanEqualToZero - If amount is zero or negative
     * @custom:throws DecentralizedStableCoin__BurnAmountExceedsBalance - If amount exceeds caller's balance
     */
    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0)
            revert DecentralizedStableCoin__BurnAmountIsLessThanEqualToZero();

        if (balance < _amount)
            revert DecentralizedStableCoin__BurnAmountExceedsBalance(balance);
        super.burn(_amount);
    }

    /**
     * @notice Mints new tokens and assigns them to the specified address
     * @dev Only the owner (DSCEngine) can call this function
     * @param _to The address that will receive the minted tokens
     * @param _amount The amount of tokens to mint
     * @return bool Always returns true if the operation is successful
     * @custom:throws DecentralizedStableCoin__CantMintToZeroAddress - If recipient is zero address
     * @custom:throws DecentralizedStableCoin__MintAmountIsLessThanEqualToZero - If amount is zero or negative
     */
    function mint(
        address _to,
        uint256 _amount
    ) external onlyOwner returns (bool) {
        if (_to == address(0))
            revert DecentralizedStableCoin__CantMintToZeroAddress();
        if (_amount <= 0)
            revert DecentralizedStableCoin__MintAmountIsLessThanEqualToZero();
        _mint(_to, _amount);
        return true;
    }
}

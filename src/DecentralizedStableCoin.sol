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
    error DecentralizedStableCoin__BurnAmountExceedsBalance(uint256 balance);
    error DecentralizedStableCoin__BurnAmountIsLessThanEqualToZero();
    error DecentralizedStableCoin__MintAmountIsLessThanEqualToZero();
    error DecentralizedStableCoin__CantMintToZeroAddress();

    constructor() ERC20("Decentralized Stable Coin", "DSC") {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0)
            revert DecentralizedStableCoin__BurnAmountIsLessThanEqualToZero();

        if (balance < _amount)
            revert DecentralizedStableCoin__BurnAmountExceedsBalance(balance);
        super.burn(_amount);
    }

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

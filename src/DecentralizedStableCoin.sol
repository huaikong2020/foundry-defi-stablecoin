// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {ERC20, ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DecentralizedStableCoin__MustBeMoreThanZero();
    error DecentralizedStableCoin__MustBeLessThanBalance();
    error DecentralizedStableCoin__NotZeroAddress();

    constructor() ERC20("DecentralizedStableCoin", "DSC") Ownable(address(msg.sender)) {}

    function burn(uint256 amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (amount <= 0) {
            revert DecentralizedStableCoin__MustBeMoreThanZero();
        }
        if (amount > balance) {
            revert DecentralizedStableCoin__MustBeLessThanBalance();
        }
        super.burn(amount);
    }

    function mint(address to, uint256 amount) external onlyOwner returns (bool) {
        if (to == address(0)) {
            revert DecentralizedStableCoin__NotZeroAddress();
        }
        if (amount <= 0) {
            revert DecentralizedStableCoin__MustBeMoreThanZero();
        }
        _mint(to, amount);
        return true;
    }
}

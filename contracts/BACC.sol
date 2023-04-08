//SPDX-License-Identifier: Unlicense

pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface FeeReceiver {
    function receiveToken(address token, uint256 amount) external;
}

contract BACC is ERC20, ERC20Burnable, Ownable {
    address public feeReceiver;
    mapping(address => bool) public pairs;

    constructor() ERC20("BACC", "BACC") {
        _mint(msg.sender, 1_000_000_000e18);
    }

    function setPair(address _pair, bool result) external onlyOwner {
        pairs[_pair] = result;
    }

    function setFeeReceiver(address _feeReceiver) external onlyOwner {
        feeReceiver = _feeReceiver;
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        if (pairs[from] || pairs[to]) {
            uint256 feeAmount = (amount * 5) / 100;
            super._transfer(from, address(this), feeAmount);
            super._approve(address(this), feeReceiver, feeAmount);
            FeeReceiver(feeReceiver).receiveToken(address(this), feeAmount);
            amount -= feeAmount;
        }
        super._transfer(from, to, amount);
    }
}

//SPDX-License-Identifier: Unlicense

pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract USDT is ERC20 {
    constructor() ERC20("USDT-TEST", "USDT") {}

    //Test
    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

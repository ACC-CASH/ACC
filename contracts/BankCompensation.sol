// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract BankCompensation is AccessControlEnumerable {
    using SafeERC20 for IERC20;
    bytes32 public constant BANK_ROLE = keccak256("BANK_ROLE");

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function transferToken(
        address token,
        address account,
        uint256 amount
    ) external onlyRole(BANK_ROLE) {
        IERC20(token).safeTransfer(account, amount);
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";

contract BankAccount is AccessControlEnumerable {
    bytes32 public constant BANK_ROLE = keccak256("BANK_ROLE");
    bytes32 public constant UPGRADE_ROLE = keccak256("UPGRADE_ROLE");

    struct Account {
        address parent;
        uint8 level;
    }

    mapping(address => Account) public accounts;

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(UPGRADE_ROLE, _msgSender());
    }

    function register(address addr, address parent) external onlyRole(UPGRADE_ROLE) {
        accounts[addr].parent = parent;
    }

    function upgrade(address addr, uint8 level) external onlyRole(UPGRADE_ROLE) {
        accounts[addr].level = level;
    }

    function reset(address[] calldata addrs, uint8 level) external onlyRole(UPGRADE_ROLE) {
        for (uint256 i = 0; i < addrs.length; i++) {
            accounts[addrs[i]].level = level;
        }
    }

    function info(address addr) external view returns (address parent, uint8 level) {
        parent = accounts[addr].parent;
        level = accounts[addr].level;
    }
}

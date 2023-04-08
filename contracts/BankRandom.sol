// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";

contract BankRandom is AccessControlEnumerable {
    bytes32 public constant BANK_ROLE = keccak256("BANK_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    uint8[] public final8 = [0, 3, 4, 5, 6, 7, 15, 30, 30, 50, 60, 60, 60, 60, 50, 50, 110, 200, 200];
    uint8[][] public withdraw = [
        [0, 0, 0, 0, 0, 0, 23, 20, 17, 15, 25],
        [0, 0, 0, 0, 0, 23, 20, 17, 15, 25, 0],
        [0, 0, 0, 0, 32, 25, 15, 12, 16, 0, 0],
        [0, 0, 0, 45, 23, 17, 15, 0, 0, 0, 0],
        [0, 0, 0, 65, 30, 5, 0, 0, 0, 0, 0]
    ];

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(BANK_ROLE, _msgSender());
    }

    function listFinal() external view onlyRole(OPERATOR_ROLE) returns (uint8[] memory) {
        return final8;
    }

    function setFinal(uint8 idx, uint8 random) external onlyRole(OPERATOR_ROLE) {
        final8[idx] = random;
    }

    function listWithdraw() external view onlyRole(OPERATOR_ROLE) returns (uint8[][] memory) {
        return withdraw;
    }

    function setWithdraw(
        uint8 x,
        uint8 y,
        uint8 random
    ) external onlyRole(OPERATOR_ROLE) {
        withdraw[x][y] = random;
    }

    function finalDays(uint256 k, bool first) external view onlyRole(BANK_ROLE) returns (uint256 days_) {
        if (first) {
            return finalDaysRandom(14);
        }
        if (k <= 400) {
            days_ = finalDaysRandom(11);
        } else if (k < 2000) {
            days_ = finalDaysRandom(15);
        } else {
            days_ = finalDaysRandom(18);
        }
    }

    function withdrawDays(uint256 k) external view onlyRole(BANK_ROLE) returns (uint256 days_) {
        if (k < 150) {
            days_ = withdrawDaysRandom(0);
        } else if (k < 500) {
            days_ = withdrawDaysRandom(1);
        } else if (k < 1000) {
            days_ = withdrawDaysRandom(2);
        } else if (k < 1500) {
            days_ = withdrawDaysRandom(3);
        } else {
            days_ = withdrawDaysRandom(4);
        }
    }

    function finalDaysRandom(uint256 end) private view returns (uint256 days_) {
        uint256 sum;
        for (uint256 i = 0; i <= end; i++) {
            sum += final8[i];
        }
        uint256 random = createRandom(sum);
        sum = 0;
        for (uint256 i = 0; i <= end; i++) {
            sum += final8[i];
            //TODO
            if (random <= sum) {
                days_ = i;
                break;
            }
        }
    }

    function withdrawDaysRandom(uint256 x) private view returns (uint256 days_) {
        uint256 sum;
        for (uint256 i = 0; i <= 10; i++) {
            sum += withdraw[x][i];
        }
        uint256 random = createRandom(sum);
        sum = 0;
        for (uint256 i = 0; i <= 10; i++) {
            sum += withdraw[x][i];
            if (random <= sum) {
                days_ = i;
                break;
            }
        }
    }

    function createRandom(uint256 max) private view returns (uint256) {
        return uint256(keccak256(abi.encodePacked(block.timestamp, block.coinbase, gasleft()))) % max;
    }
}

//SPDX-License-Identifier: Unlicense

pragma solidity ^0.8.9;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";

interface IAccount {
    function info(address addr) external view returns (address parent, uint8 level);
}

contract Donate is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    address public constant USDB = 0x8C292da7Bc345B86a00C94B64786f5F6b8D951Cb;
    address public constant ACCOUNT = 0x49821Ff0909C70f879da77B739bF3ffceBE3946A;

    enum RewardType {
        DONATE,
        INVITE
    }
    struct DonateInfo {
        uint256 donateAmount;
        uint256 totalAmount;
        uint16 rewardPercent;
        uint16 invitePercent;
        bool status;
    }
    DonateInfo[] donateInfo;
    mapping(address => mapping(uint256 => uint256)) donateAmounts;
    mapping(RewardType => uint256) public totalShare;
    mapping(address => mapping(RewardType => uint256)) rewardShare;
    mapping(address => mapping(RewardType => uint256)) rewardAcc;
    mapping(address => mapping(address => mapping(RewardType => uint256))) rewardDebts;
    mapping(address => mapping(address => mapping(RewardType => uint256))) withdrawAmounts;
    EnumerableSetUpgradeable.AddressSet rewardTokens;

    function initialize() public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function addRewardToken(address token) external onlyRole(OPERATOR_ROLE) {
        rewardTokens.add(token);
    }

    function getRewardTokens() public view returns (address[] memory) {
        return rewardTokens.values();
    }

    function addDonateInfo(uint256 donateAmount, uint16 rewardPercent, uint16 invitePercent, bool status) external onlyRole(OPERATOR_ROLE) {
        donateInfo.push(DonateInfo({donateAmount: donateAmount, totalAmount: 0, rewardPercent: rewardPercent, invitePercent: invitePercent, status: status}));
    }

    function updateDonateInfo(uint256 pid, uint256 donateAmount, uint16 rewardPercent, uint16 invitePercent) external onlyRole(OPERATOR_ROLE) {
        DonateInfo storage info = donateInfo[pid];
        info.donateAmount = donateAmount;
        info.rewardPercent = rewardPercent;
        info.invitePercent = invitePercent;
    }

    function setDonateStatus(uint256 pid, bool status) external onlyRole(OPERATOR_ROLE) {
        donateInfo[pid].status = status;
    }

    function donate(uint256 pid) external {
        _donate(pid, msg.sender);
        IERC20Upgradeable(USDB).safeTransferFrom(msg.sender, address(this), donateInfo[pid].donateAmount);
    }

    function _donate(uint256 pid, address addr) internal {
        require(rewardShare[addr][RewardType.DONATE] == 0, "duplicate donate");
        DonateInfo storage info = donateInfo[pid];
        require(info.status, "donate status limited");
        uint256 amount = info.donateAmount;
        uint256 share = (amount * info.rewardPercent) / 1e18;
        info.totalAmount += amount;
        donateAmounts[addr][pid] += amount;
        totalShare[RewardType.DONATE] += share;
        rewardShare[addr][RewardType.DONATE] += share;
        address[] memory tokens = rewardTokens.values();
        for (uint256 i = 0; i < tokens.length; i++) {
            rewardDebts[addr][tokens[i]][RewardType.DONATE] += (share * rewardAcc[tokens[i]][RewardType.DONATE]) / 1e18;
        }

        (address parent, ) = IAccount(ACCOUNT).info(addr);
        if (parent != address(0)) {
            share = (amount * info.invitePercent) / 1e18;
            totalShare[RewardType.INVITE] += share;
            rewardShare[parent][RewardType.INVITE] += share;
            for (uint256 i = 0; i < tokens.length; i++) {
                rewardDebts[parent][tokens[i]][RewardType.INVITE] += (share * rewardAcc[tokens[i]][RewardType.INVITE]) / 1e18;
            }
        }
    }

    function pening(address addr, address token, RewardType rewardType) public view returns (uint256) {
        uint256 debtAmount = rewardDebts[addr][token][rewardType];
        uint256 rewardAmount = (rewardShare[addr][rewardType] * rewardAcc[token][rewardType]) / 1e18;
        return rewardAmount - debtAmount;
    }

    function withdrawReward(address token, RewardType rewardType) external {
        uint256 amount = pening(msg.sender, token, rewardType);
        if (amount > 0) {
            rewardDebts[msg.sender][token][rewardType] += amount;
            withdrawAmounts[msg.sender][token][rewardType] += amount;
            IERC20Upgradeable(token).safeTransfer(msg.sender, amount);
        }
    }

    function withdraw(address token, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IERC20Upgradeable(token).safeTransfer(msg.sender, amount);
    }

    function getDonateInfos() external view returns (DonateInfo[] memory) {
        return donateInfo;
    }

    function getDonateAmount(address addr, uint256 pid) external view returns (uint256) {
        return donateAmounts[addr][pid];
    }

    function getRewardShare(address addr, RewardType rewardType) external view returns (uint256) {
        return rewardShare[addr][rewardType];
    }

    function getWithdrawAmount(address addr, address token, RewardType rewardType) external view returns (uint256) {
        return withdrawAmounts[addr][token][rewardType];
    }

    function receiveToken(address token, uint256 amount) external {
        require(rewardTokens.contains(token), "unsupported token");
        IERC20Upgradeable(token).safeTransferFrom(msg.sender, address(this), amount);
        if (totalShare[RewardType.DONATE] > 0) {
            rewardAcc[token][RewardType.DONATE] += (amount * 8 * 1e18) / (10 * totalShare[RewardType.DONATE]);
        }
        if (totalShare[RewardType.INVITE] > 0) {
            rewardAcc[token][RewardType.INVITE] += (amount * 2 * 1e18) / (10 * totalShare[RewardType.INVITE]);
        }
    }
}

//SPDX-License-Identifier: Unlicense

pragma solidity ^0.8.9;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

interface IAcc {
    function mint(address to, uint256 amount) external;

    function burnFrom(address account, uint256 amount) external;
}

contract AccExchange is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    address public constant ACC = 0x1Ded506170D2471070aE1Ba149EC37613D600b3E;
    uint256 public lastPrice;
    uint256 public totalUAmount;
    mapping(address => mapping(uint8 => uint256)) public scales;
    mapping(address => bool) tokens;

    function initialize() public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function setScale(address addr, uint8 method, uint256 scale) external onlyRole(OPERATOR_ROLE) {
        scales[addr][method] = scale;
    }

    function setToken(address token, bool status) external onlyRole(OPERATOR_ROLE) {
        tokens[token] = status;
    }

    function initSupply(address token, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(lastPrice == 0, "AccExchange: duplicate init");
        uint256 mintAmount = (amount * 1e18) / 1e17;
        _mint(token, amount, msg.sender, mintAmount);
    }

    function _mint(address token, uint256 amount, address to, uint256 mintAmount) private {
        IERC20Upgradeable(token).safeTransferFrom(msg.sender, address(this), amount);
        IAcc(ACC).mint(to, mintAmount);
        totalUAmount += amount;
        lastPrice = (totalUAmount * 1e18) / IERC20Upgradeable(ACC).totalSupply();
    }

    function deposit(address token, uint8 method, uint256 amount, address to) external returns (uint256 mintAmount) {
        require(scales[msg.sender][method] != 0, "AccExchange: unsupported sender");
        require(tokens[token], "AccExchange: unsupported token");
        mintAmount = ((amount * scales[msg.sender][method]) / lastPrice);
        _mint(token, amount, to, mintAmount);
    }

    function withdraw(address token, uint256 amount) external {
        require(tokens[token], "AccExchange: unsupported token");
        uint256 exchangeAmount = (amount * totalUAmount) / IERC20Upgradeable(ACC).totalSupply();
        totalUAmount -= exchangeAmount;
        IERC20Upgradeable(token).safeTransfer(msg.sender, exchangeAmount);
        IAcc(ACC).burnFrom(msg.sender, amount);
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

interface IPancakePair {
    function token0() external view returns (address);

    function token1() external view returns (address);

    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface IPancakeFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IAccExchange {
    function lastPrice() external view returns (uint256);
}

contract PriceOracle is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    IPancakeFactory public constant PANCAKE_FACTORY = IPancakeFactory(0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73);
    address public constant ACC = 0x1Ded506170D2471070aE1Ba149EC37613D600b3E;
    address public constant ACC_EXCHANGE = 0xC2A56c674c424759A641831f77E5491D8ACc3d70;
    mapping(address => uint256) tokenPrice;

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function initialize() public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    function updatePrice(address token, uint256 price) external onlyRole(OPERATOR_ROLE) {
        tokenPrice[token] = price;
    }

    function updatePriceFromPair(address token0, address token1) external onlyRole(OPERATOR_ROLE) {
        IPancakePair pair = IPancakePair(PANCAKE_FACTORY.getPair(token0, token1));
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        address _token0 = pair.token0();
        if (token0 == _token0) {
            tokenPrice[token0] = (uint256(reserve1) * 1e18) / reserve0;
        } else {
            tokenPrice[token0] = (uint256(reserve0) * 1e18) / reserve1;
        }
    }

    function getPrice(address token) external view returns (uint256) {
        if (token == ACC) {
            return IAccExchange(ACC_EXCHANGE).lastPrice();
        } else {
            return tokenPrice[token];
        }
    }
}

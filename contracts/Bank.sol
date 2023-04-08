// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

interface IRandom {
    function finalDays(uint256 k, bool first) external view returns (uint256 days_);

    function withdrawDays(uint256 k) external view returns (uint256 days_);
}

interface IAccount {
    function info(address addr) external view returns (address parent_, uint8 level_);
}

interface IBankCompensation {
    function transferToken(
        address token,
        address account,
        uint256 amount
    ) external;
}

interface IUniswapV2Router01 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface IPriceOracle {
    function getPrice(address token) external view returns (uint256);
}

contract Bank is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    uint32 public constant INTERVAL = 2 * 60;
    address public constant usdt = 0xeB92E36da598b851195924835cfCc29832Bd93A3;
    address public constant token = 0x227Fa75e1c6EB45d812E618550A50790d8992630;
    address public constant router = 0xD99D1c33F9fC3444f8101754aBC46c52416550D1;
    address public constant feeReceiver = 0x913710bcE6F17b81256676475cd1bBE5800A0d95; //白名单手续费地址
    IPriceOracle public constant priceOracle = IPriceOracle(0x2f256eDA79Ea29Db266948fbA10C61dA000719dF); //价格源
    IBankCompensation public constant bankCompensation = IBankCompensation(0x63F49aae9A2f57fd3D9b88551dda838437977e3C); //重启补偿池
    IRandom private iRandom;
    IAccount private iAccount;
    uint32[] versions; //历史版本
    uint32 versionTimes; //当前版本index
    uint256 public flowInTotal; //总金额
    uint256 public depositTotal; //储蓄金额
    uint256 public preTotal; //待支付尾款金额
    uint256 public withdrawTotal; //待取款总额
    uint8[] public bonusPercents; //级差
    uint8 public topBonusPercent; //最高级平级奖
    uint8 public baseRate; //静态
    uint256 public baseLmt; //预约总额基数
    uint256 public blackListFee; //移除黑名单费用

    uint256[] public depositEach; //各级单笔存款限额
    uint32[] public depositInterval; //各级存款间隔;

    struct Broker {
        uint32 currentVersion; //版本
        uint256 depositTotal; //总存款
        uint256 depositCurrent; //当前存款
        uint256 bonusCalc; //累计经纪人收益
        uint256 bonusMax; //最大可提经纪人收益
        uint256 bonusDrawed; //已提经纪人收益
        uint256 punishTimes; //违约订单次数
        int256 profitAmount; //总利润
    }

    mapping(address => Broker) public brokers; //经纪人收益
    mapping(uint32 => uint256) public depositAmountDays;
    mapping(address => uint256) public accountFlowIns;

    struct Deposit {
        uint256 amount; //订单金额
        uint256 preAmount; //预付款金额
        uint256 finalAmount; //尾款金额
        uint256 withdrawAmount; //到期可提金额
        uint8 ratePercent; //静态收益率
        uint32 createTimestamp; //创建时间
        uint32 startFinalPayTimestamp; //尾款开始时间
        uint32 endFinalPayTimestamp; //尾款截止时间
        uint32 drawableTimestamp; // 可取款时间
        uint8 status; // 0:初始化状态;10:交定金=>等待付尾款(等时间戳到);20:已付尾款,等待取款;30:已完成;40:超时交尾款;50:已经触发重启
    }

    mapping(address => Deposit[]) private deposits;

    struct LossInfo {
        uint256 lossAmount; //损失u数量
        uint256 tokenAmount; //补偿token数量
        uint256 withdrawAmount; //已提取数量
        uint32 timestamp; //补偿时间
    }

    mapping(address => mapping(uint32 => LossInfo)) public losses;

    uint256 public restartBalance;
    uint256 public restartTimes; //累计触发重启次数大于10次重启
    uint256 public restartRate; //储蓄合约取款额度/可取款额度>重启比例（设定为9）时，用户可触发重启功能
    uint256 public restartWaitingTime; //订单的创建时间+29天大于等于时才能触发
    bool public restartStatus;
    uint256 public restartSubmitTimes;
    uint256 public restartUntil;

    function initialize() public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);

        versions.push(uint32(block.timestamp));
        iAccount = IAccount(0xD65CCE3C70D56857367c7f7CEc6754bE061c7fF3); //账号合约
        iRandom = IRandom(0x8f57c0D4aa05eC4f8F3B0C7456Ab89c15e943DEA); //随机数合约

        bonusPercents = [0, 3, 4, 5, 7, 8, 9, 11, 13, 15]; //极差
        topBonusPercent = 1; //最高级平级奖
        baseRate = 13; //静态
        baseLmt = 20000e18; //预约总额基数
        blackListFee = 1000e18; //移除黑名单费用
        depositEach = [1000e18, 1000e18, 1000e18, 3000e18, 3000e18, 5000e18, 5000e18, 7000e18, 7000e18, 10000e18]; //各级单笔存款限额
        depositInterval = [7 * INTERVAL, 7 * INTERVAL, 7 * INTERVAL, 5 * INTERVAL, 5 * INTERVAL, 3 * INTERVAL, 3 * INTERVAL, 2 * INTERVAL, 2 * INTERVAL, 1 * INTERVAL]; //各级存款间隔

        restartTimes = 10;
        restartRate = 9;
        restartWaitingTime = 29;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function baseInit(address account, address random) external onlyRole(OPERATOR_ROLE) {
        iAccount = IAccount(account);
        iRandom = IRandom(random);
    }

    function restartInit(
        uint256 times,
        uint256 rate,
        uint256 waitingTime
    ) external onlyRole(OPERATOR_ROLE) {
        restartTimes = times;
        restartRate = rate;
        restartWaitingTime = waitingTime;
    }

    function setDepositInterval(uint8 idx, uint32 interval) external onlyRole(OPERATOR_ROLE) {
        depositInterval[idx] = interval;
    }

    function setDepositEach(uint8 idx, uint256 amount) external onlyRole(OPERATOR_ROLE) {
        depositEach[idx] = amount;
    }

    function setBaseRate(uint8 base, uint8 topBonus) external onlyRole(OPERATOR_ROLE) {
        baseRate = base;
        topBonusPercent = topBonus;
    }

    function setBonus(uint8 idx, uint8 amount) external onlyRole(OPERATOR_ROLE) {
        bonusPercents[idx] = amount;
    }

    //查询所有版本
    function versionList() external view returns (uint32[] memory) {
        return versions;
    }

    //首付款
    function preDeposit(uint256 amount) external {
        _lossClaim(msg.sender);
        require(amount >= 100e18, "ACC: amount must greater than 100.");
        require(amount % 1e18 == 0, "ACC: amount must be an integer.");
        require(!restartStatus, "ACC: system on restart.");
        require(depositRemainToday() > 0, "ACC: insufficient remain today.");
        (address parent, uint8 level) = iAccount.info(msg.sender);
        require(parent != address(0), "ACC: account is not active.");
        require(amount <= depositEach[level], "ACC: amount limit of your level.");
        require(
            deposits[msg.sender].length == 0 || block.timestamp - deposits[msg.sender][deposits[msg.sender].length - 1].createTimestamp >= depositInterval[level],
            "ACC: deposit interval limit of your level."
        );
        require(!checkBlacklist(msg.sender), "ACC: you are in blacklist"); //黑名单
        uint256 preAmount = amount / 10; //首付款10%
        Deposit storage deposit = deposits[msg.sender].push();
        deposit.amount = amount;
        deposit.preAmount = preAmount;
        deposit.finalAmount = amount - preAmount;
        deposit.ratePercent = baseRate;
        deposit.withdrawAmount = amount + (amount * baseRate) / 100;
        deposit.createTimestamp = uint32(block.timestamp);

        uint256 days_ = iRandom.finalDays(depositWithdrawRate(), brokers[msg.sender].depositTotal == 0);
        deposit.startFinalPayTimestamp = uint32(block.timestamp + days_ * INTERVAL);
        deposit.endFinalPayTimestamp = uint32(block.timestamp + (days_ + 2) * INTERVAL);
        deposit.status = 10;

        preTotal += deposit.finalAmount; //待进尾款
        brokers[msg.sender].depositTotal += preAmount;
        brokers[msg.sender].depositCurrent += preAmount;
        brokers[msg.sender].bonusMax += preAmount * 3; //最大3倍收益
        brokers[msg.sender].profitAmount -= int256(preAmount);
        depositAmountDays[today()] += amount;
        accountFlowIns[msg.sender] += preAmount;
        flowInTotal += preAmount;
        IERC20Upgradeable(usdt).safeTransferFrom(msg.sender, address(this), preAmount);
        allocAmount(preAmount);
    }

    //尾款
    function finalDeposit(uint256 idx) external {
        _lossClaim(msg.sender);
        require(!restartStatus, "ACC: system on restart status");
        Deposit storage deposit = deposits[msg.sender][idx];
        require(deposit.status == 10 || deposit.status == 40, "ACC: deposit status error.");
        require(block.timestamp >= deposit.startFinalPayTimestamp, "ACC: deposit not allow final pay.");
        require(block.timestamp < deposit.endFinalPayTimestamp || deposit.status == 40, "ACC: deposit is overtime.");

        uint256 finalAmount = deposit.finalAmount;
        deposit.status = 20;

        uint256 days_ = iRandom.withdrawDays(depositWithdrawRate());
        deposit.drawableTimestamp = uint32(block.timestamp + days_ * INTERVAL);
        preTotal -= finalAmount;
        withdrawTotal += deposit.withdrawAmount;
        brokers[msg.sender].depositTotal += finalAmount;
        brokers[msg.sender].depositCurrent += finalAmount;
        brokers[msg.sender].bonusMax += finalAmount * 3;
        brokers[msg.sender].profitAmount -= int256(finalAmount);
        accountFlowIns[msg.sender] += finalAmount;
        flowInTotal += finalAmount;
        IERC20Upgradeable(usdt).safeTransferFrom(msg.sender, address(this), finalAmount);
        allocAmount(finalAmount);
    }

    //取款
    function withdraw(uint256 idx) external {
        _lossClaim(msg.sender);
        require(!restartStatus, "ACC: system on restart status");
        require(!checkBlacklist(msg.sender), "ACC: you are in blacklist");
        Deposit memory deposit = deposits[msg.sender][idx];
        require(deposit.status == 20 || deposit.status == 50, "ACC: deposit can`t withdraw");
        require(deposit.drawableTimestamp <= block.timestamp, "ACC: withdraw time have not yet.");
        withdrawTotal -= deposit.withdrawAmount;
        depositTotal -= deposit.withdrawAmount;
        brokers[msg.sender].depositCurrent -= deposit.amount;
        brokers[msg.sender].profitAmount += int256(deposit.withdrawAmount);
        if (deposit.status == 50) {
            restartSubmitTimes -= 1;
        }
        deposits[msg.sender][idx].status = 30;
        IERC20Upgradeable(usdt).safeTransfer(msg.sender, deposit.withdrawAmount);
    }

    function allocAmount(uint256 alloc) private {
        uint256 brokerAmount = (alloc * 16) / 100; //经纪人将 16%
        restartBalance += (alloc * 6) / 1000; //启动池0.6%
        depositTotal += (alloc * 784) / 1000; //沉淀
        processBonus(msg.sender, brokerAmount);
        burnToken((alloc * 5) / 100); //代币销毁
    }

    function processBonus(address addr, uint256 amount) private {
        uint8 level = 0;
        uint256 _amount = amount;
        (address parent, ) = iAccount.info(addr);
        for (uint256 i = 0; i < 30; i++) {
            if (parent == address(0)) {
                break;
            }
            (address _parent, uint8 parentLevel) = iAccount.info(parent);
            if (parentLevel == level && level == 9) {
                uint256 bonus = verifyBonus(parent, _amount, topBonusPercent);
                amount -= bonus;
                break;
            } else if (bonusPercents[parentLevel] > bonusPercents[level]) {
                uint8 diffPercent = bonusPercents[parentLevel] - bonusPercents[level];
                uint256 bonus = verifyBonus(parent, _amount, diffPercent);
                amount -= bonus;
                level = parentLevel;
            }
            parent = _parent;
        }
        if (amount > 0) {
            depositTotal += amount;
        }
    }

    function verifyBonus(
        address addr,
        uint256 amount,
        uint8 bonusPercent
    ) private returns (uint256) {
        if (versions[versionTimes] != brokers[addr].currentVersion) {
            return 0;
        }
        if (brokers[addr].depositCurrent < amount) {
            amount = brokers[addr].depositCurrent;
        }
        uint256 bonus = (amount * bonusPercent) / 16;
        brokers[addr].bonusCalc += bonus;
        return bonus;
    }

    //提取经济人奖
    function bonusWithdraw() external {
        require(brokers[msg.sender].depositCurrent > 0, "you current deposit is empty.");
        require(!checkBlacklist(msg.sender), "ACC: you are in blacklist");
        uint256 amount = bonusDrawable(msg.sender);
        if (amount > 0) {
            brokers[msg.sender].bonusMax -= amount;
            brokers[msg.sender].bonusDrawed += amount;
            brokers[msg.sender].profitAmount += int256(amount);
            IERC20Upgradeable(usdt).safeTransfer(msg.sender, amount);
        }
    }

    //查询经纪人奖
    function bonusDrawable(address addr) public view returns (uint256 amount) {
        if (brokers[addr].bonusMax > 0 && brokers[addr].bonusCalc > brokers[addr].bonusDrawed) {
            amount = brokers[addr].bonusCalc - brokers[addr].bonusDrawed;
            if (amount > brokers[addr].bonusMax) {
                amount = brokers[addr].bonusMax;
            }
        }
    }

    //检查黑名单
    function checkBlacklist(address addr) public view returns (bool result) {
        Deposit[] storage _deposits = deposits[addr];
        for (uint256 i = 0; i < _deposits.length; i++) {
            if (_deposits[i].status == 10 && block.timestamp > _deposits[i].endFinalPayTimestamp) {
                return true;
            }
        }
    }

    //移除白名单
    function dealBlacklist(uint256 index) external {
        Deposit storage deposit = deposits[msg.sender][index];
        require(deposit.status == 10, "deposit status error.");
        require(block.timestamp > deposit.endFinalPayTimestamp, "deposit have no overtime");
        brokers[msg.sender].punishTimes += 1;
        require(block.timestamp >= deposit.endFinalPayTimestamp + INTERVAL * brokers[msg.sender].punishTimes, "deposit in punish time");
        deposit.status = 40;
        IERC20Upgradeable(token).safeTransferFrom(msg.sender, feeReceiver, blackListFee * brokers[msg.sender].punishTimes);
    }

    //查询存款订单个数
    function depositLength(address addr) external view returns (uint256) {
        return deposits[addr].length;
    }

    //查询存款订单
    function depositList(
        address addr,
        uint256 offset,
        uint256 size
    ) external view returns (Deposit[] memory results) {
        require(offset + size <= deposits[addr].length);
        results = new Deposit[](size);
        for (uint256 i = 0; i < size; i++) {
            results[i] = deposits[addr][i + offset];
        }
    }

    //K
    function depositWithdrawRate() private view returns (uint256) {
        if (withdrawTotal != 0) {
            return ((depositTotal + preTotal) * 100) / withdrawTotal;
        } else {
            return 600;
        }
    }

    //触发重启
    function restart(uint256 depositIndex) external {
        require(deposits[msg.sender][depositIndex].status == 20, "ACC: deposit status error.");
        require(block.timestamp > deposits[msg.sender][depositIndex].createTimestamp + restartWaitingTime * INTERVAL, "ACC: this deposit not satisfy to restart.");
        require(withdrawTotal / depositTotal >= restartRate, "ACC: bank no need to restart.");
        restartSubmitTimes += 1;
        if (restartSubmitTimes > restartTimes) {
            restartStatus = true;
            restartUntil = block.timestamp + 2 * INTERVAL;
            restartSubmitTimes = 0;
        }
        deposits[msg.sender][depositIndex].status = 50;
    }

    //重启
    function start() external {
        require(restartStatus, "ACC: not in restart status.");
        require(block.timestamp > restartUntil, "ACC: in restart time.");
        restartStatus = false;
        versions.push(uint32(block.timestamp));
        versionTimes += 1;
        depositTotal += restartBalance;
        delete restartBalance;
        delete preTotal;
        delete withdrawTotal;
        delete flowInTotal;
    }

    function lossClaim() external {
        _lossClaim(msg.sender);
    }

    function _lossClaim(address addr) private {
        if (versions[versionTimes] != brokers[addr].currentVersion) {
            //profitAmount 小于0为亏损
            if (brokers[addr].profitAmount < 0) {
                LossInfo storage lossInfo = losses[addr][brokers[addr].currentVersion];
                uint256 lossAmount = uint256(-brokers[addr].profitAmount);
                lossInfo.lossAmount = lossAmount;
                lossInfo.timestamp = uint32(block.timestamp);
                lossInfo.tokenAmount = (lossAmount * 1e18) / priceOracle.getPrice(token);
            }
            delete brokers[addr];
            delete deposits[addr];
            brokers[addr].currentVersion = versions[versionTimes];
        }
    }

    //重启补偿提取
    function lossWithdraw(uint32 version) external {
        LossInfo storage lossInfo = losses[msg.sender][version];
        uint256 amount = pendingLoss(msg.sender, version);
        require(amount > 0, "ACC: no loss compensation");
        lossInfo.withdrawAmount += amount;
        //发放补偿
        bankCompensation.transferToken(token, msg.sender, amount);
    }

    //查询重启补偿金额，30天线性释放
    function pendingLoss(address addr, uint32 version) public view returns (uint256 amount) {
        LossInfo memory lossInfo = losses[addr][version];
        if (lossInfo.tokenAmount > lossInfo.withdrawAmount) {
            uint32 timeElapsed = uint32(block.timestamp) - lossInfo.timestamp;
            if (timeElapsed > 30 * INTERVAL) timeElapsed = 30 * INTERVAL;
            amount = (lossInfo.tokenAmount * timeElapsed) / (30 * INTERVAL) - lossInfo.withdrawAmount;
        }
    }

    //查询重启补偿
    function getlossInfo(address addr, uint32 version) external view returns (LossInfo memory) {
        return losses[addr][version];
    }

    function setDayLmt(uint256 base) external onlyRole(OPERATOR_ROLE) {
        baseLmt = base;
    }

    //当天剩余存款金额
    function depositRemainToday() public view returns (uint256) {
        uint32 travelDays = ((uint32(block.timestamp) - versions[versionTimes])) / INTERVAL;
        if (travelDays > 70) {
            travelDays = 70;
        }
        //TODO 倍数
        return (baseLmt * 6**travelDays) / 5**travelDays - depositAmountDays[today()];
    }

    function today() public view returns (uint32) {
        return uint32(block.timestamp - (block.timestamp % INTERVAL));
    }

    function burnToken(uint256 amount) internal {
        address[] memory path = new address[](2);
        path[0] = address(usdt);
        path[1] = address(token);
        IERC20Upgradeable(usdt).safeApprove(router, amount);
        IUniswapV2Router01(router).swapExactTokensForTokens(amount, 0, path, address(this), block.timestamp + 30);
        uint256 tokenAmount = IERC20Upgradeable(token).balanceOf(address(this));
        if (tokenAmount > 0) {
            ERC20BurnableUpgradeable(token).burn(tokenAmount);
        }
    }
}

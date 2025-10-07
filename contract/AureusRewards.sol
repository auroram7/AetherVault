// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/*
  AureusRewards.sol
  Single-file, Remix-ready reward contract (drop-in replacement).
  - Use your NATO token address as the _rewardToken constructor arg.
  - Default "Based" daily claim = 10 tokens (10 * 1e18).
*/

interface IERC20 {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

library SafeERC20 {
    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        (bool success, bytes memory returndata) = address(token).call(data);
        require(success, "Low-level call failed");
        if (returndata.length > 0) {
            require(abi.decode(returndata, (bool)), "ERC20 op did not succeed");
        }
    }
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transfer.selector, to, value));
    }
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
    }
}

/* Ownable + two-step ownership */
abstract contract Context { function _msgSender() internal view virtual returns (address) { return msg.sender; } }

contract Ownable is Context {
    address private _owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    constructor() { _owner = _msgSender(); emit OwnershipTransferred(address(0), _owner); }
    modifier onlyOwner() { require(_owner == _msgSender(), "Ownable: caller"); _; }
    function owner() public view returns (address) { return _owner; }
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner zero");
        _transferOwnership(newOwner);
    }
    function _transferOwnership(address newOwner) internal virtual {
        address old = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(old, newOwner);
    }
}

contract Ownable2Step is Ownable {
    address private _pendingOwner;
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    function pendingOwner() public view returns (address) { return _pendingOwner; }
    // override to set pending
    function transferOwnership(address newOwner) public virtual override onlyOwner {
        _pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner(), newOwner);
    }
    // accept ownership
    function acceptOwnership() public {
        require(_pendingOwner == _msgSender(), "Ownable2Step: not pending");
        _transferOwnership(msg.sender);
        _pendingOwner = address(0);
    }
}

/* Reentrancy guard */
abstract contract ReentrancyGuard {
    uint256 private _status;
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;
    constructor() { _status = NOT_ENTERED; }
    modifier nonReentrant() {
        require(_status != ENTERED, "ReentrancyGuard: reentrant");
        _status = ENTERED;
        _;
        _status = NOT_ENTERED;
    }
}

/* Pausable */
abstract contract Pausable is Context {
    bool private _paused;
    event Paused(address account);
    event Unpaused(address account);
    modifier whenNotPaused() { require(!_paused, "paused"); _; }
    modifier whenPaused() { require(_paused, "not paused"); _; }
    function paused() public view returns (bool) { return _paused; }
    function _pause() internal whenNotPaused { _paused = true; emit Paused(_msgSender()); }
    function _unpause() internal whenPaused { _paused = false; emit Unpaused(_msgSender()); }
}

/* Main contract */
contract AureusRewards is ReentrancyGuard, Pausable, Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant DAILY_CLAIM_COOLDOWN = 24 hours;
    uint256 public constant RESERVE_FUND_PERCENTAGE = 10;

    enum MembershipLevel { Based, SuperBased, Legendary }
    struct LevelConfig { uint96 dailyClaimYield; uint160 upgradeRequirement; }
    struct UserAccount {
        uint40 lastDailyClaimTime;
        uint40 accountCreatedAt;
        uint32 totalDailyClaims;
        uint96 totalYieldClaimed;
        MembershipLevel membershipLevel;
        bool exists;
    }

    IERC20 public immutable rewardToken;
    address public trustedRelayer;
    address public upgradeTokenRecipient;
    bool public emergencyMode;

    mapping(address => UserAccount) public userAccounts;
    mapping(MembershipLevel => LevelConfig) public levelConfigs;

    // Events
    event AccountCreated(address indexed user, uint256 timestamp);
    event DailyClaimCompleted(address indexed user, uint256 amount, uint256 timestamp);
    event MembershipUpgraded(address indexed user, MembershipLevel from, MembershipLevel to, uint256 amount);
    event YieldDistributed(address indexed user, uint256 amount, string reason);
    event RelayerUpdated(address newRelayer);
    event UpgradeTokenRecipientUpdated(address newRecipient);
    event TokensWithdrawn(address to, uint256 amount);
    event ERC20Recovered(address token, uint256 amount);
    event EmergencyModeActivated(address by);
    event EmergencyModeDeactivated(address by);
    event LevelConfigUpdated(MembershipLevel level, uint96 dailyYield, uint160 upgradeReq);

    modifier onlyRelayer() { require(msg.sender == trustedRelayer, "OnlyRelayer"); _; }
    modifier accountExists(address user) { require(userAccounts[user].exists, "AccountDoesNotExist"); _; }
    modifier validAmount(uint256 amount) { require(amount > 0, "InvalidAmount"); _; }
    modifier notInEmergencyMode() { require(!emergencyMode, "EmergencyModeActive"); _; }
    modifier onlyInEmergencyMode() { require(emergencyMode, "NotInEmergency"); _; }
    modifier enforceReserve(uint256 amount) {
        uint256 reserve = (rewardToken.balanceOf(address(this)) * RESERVE_FUND_PERCENTAGE) / 100;
        require((rewardToken.balanceOf(address(this)) - amount) >= reserve, "InsufficientReserveFunds");
        _;
    }

    constructor(address _rewardToken, address _upgradeRecipient, address _trustedRelayer) {
        require(_rewardToken != address(0) && _upgradeRecipient != address(0) && _trustedRelayer != address(0), "InvalidInit");
        rewardToken = IERC20(_rewardToken);
        upgradeTokenRecipient = _upgradeRecipient;
        trustedRelayer = _trustedRelayer;

        // defaults: Based = 10 tokens, SuperBased = 15, Legendary = 20 (units: 1e18)
        levelConfigs[MembershipLevel.Based] = LevelConfig({ dailyClaimYield: uint96(10 ether), upgradeRequirement: uint160(0) });
        levelConfigs[MembershipLevel.SuperBased] = LevelConfig({ dailyClaimYield: uint96(15 ether), upgradeRequirement: uint160(30000 ether) });
        levelConfigs[MembershipLevel.Legendary] = LevelConfig({ dailyClaimYield: uint96(20 ether), upgradeRequirement: uint160(60000 ether) });
    }

    /* ========== USER ACTIONS ========== */
    function createAccount() external nonReentrant whenNotPaused notInEmergencyMode {
        require(!userAccounts[msg.sender].exists, "AccountAlreadyExists");
        userAccounts[msg.sender] = UserAccount({
            lastDailyClaimTime: 0,
            accountCreatedAt: uint40(block.timestamp),
            totalDailyClaims: 0,
            totalYieldClaimed: 0,
            membershipLevel: MembershipLevel.Based,
            exists: true
        });
        emit AccountCreated(msg.sender, block.timestamp);
    }

    function dailyClaim(address user) external onlyRelayer nonReentrant whenNotPaused notInEmergencyMode accountExists(user) {
        _doDailyClaim(user);
    }

    function batchDailyClaim(address[] calldata users) external onlyRelayer nonReentrant whenNotPaused notInEmergencyMode {
        for (uint256 i = 0; i < users.length; ++i) {
            try this._doDailyClaimExternal(users[i]) {
                // success - events emitted inside
            } catch {
                // skip failing user (cooldown / insufficient balance)
            }
        }
    }

    function _doDailyClaim(address user) internal accountExists(user) {
        UserAccount storage account = userAccounts[user];
        require(block.timestamp >= uint256(account.lastDailyClaimTime) + DAILY_CLAIM_COOLDOWN, "DailyClaimOnCooldown");
        uint256 yieldAmount = levelConfigs[account.membershipLevel].dailyClaimYield;
        require(rewardToken.balanceOf(address(this)) >= yieldAmount, "InsufficientContractBalance");
        account.lastDailyClaimTime = uint40(block.timestamp);
        account.totalDailyClaims += 1;
        account.totalYieldClaimed += uint96(yieldAmount);
        SafeERC20.safeTransfer(rewardToken, user, yieldAmount);
        emit DailyClaimCompleted(user, yieldAmount, block.timestamp);
        emit YieldDistributed(user, yieldAmount, "daily_claim");
    }

    // external wrapper so try/catch in batch works
    function _doDailyClaimExternal(address user) external {
        require(msg.sender == address(this), "only this");
        _doDailyClaim(user);
    }

    function upgradeMembership(address user, MembershipLevel targetLevel) external onlyRelayer nonReentrant whenNotPaused notInEmergencyMode accountExists(user) {
        UserAccount storage account = userAccounts[user];
        MembershipLevel currentLevel = account.membershipLevel;
        require(uint8(targetLevel) > uint8(currentLevel), "InvalidMembershipLevel");
        require(uint8(targetLevel) <= uint8(currentLevel) + 1, "CannotSkipLevels");
        require(currentLevel != MembershipLevel.Legendary, "AlreadyAtMaxLevel");
        uint256 cost = levelConfigs[targetLevel].upgradeRequirement;
        require(rewardToken.balanceOf(user) >= cost, "InsufficientTokensForUpgrade");
        require(rewardToken.allowance(user, address(this)) >= cost, "InsufficientAllowance");
        account.membershipLevel = targetLevel;
        SafeERC20.safeTransferFrom(rewardToken, user, upgradeTokenRecipient, cost);
        emit MembershipUpgraded(user, currentLevel, targetLevel, cost);
    }

    /* ========== OWNER / ADMIN ========== */
    function updateRelayer(address newRelayer) external onlyOwner {
        require(newRelayer != address(0), "InvalidRecipient");
        trustedRelayer = newRelayer;
        emit RelayerUpdated(newRelayer);
    }

    function updateUpgradeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "InvalidRecipient");
        upgradeTokenRecipient = newRecipient;
        emit UpgradeTokenRecipientUpdated(newRecipient);
    }

    function setLevelConfig(MembershipLevel level, uint96 dailyYield, uint160 upgradeRequirement) external onlyOwner {
        levelConfigs[level] = LevelConfig({ dailyClaimYield: dailyYield, upgradeRequirement: upgradeRequirement });
        emit LevelConfigUpdated(level, dailyYield, upgradeRequirement);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function withdrawTokens(address to, uint256 amount) external onlyOwner enforceReserve(amount) nonReentrant validAmount(amount) {
        SafeERC20.safeTransfer(rewardToken, to, amount);
        emit TokensWithdrawn(to, amount);
    }

    function recoverERC20(address token, uint256 amount) external onlyOwner onlyInEmergencyMode {
        require(token != address(rewardToken), "Cannot recover primary token");
        IERC20(token).transfer(owner(), amount);
        emit ERC20Recovered(token, amount);
    }

    function activateEmergencyMode() external onlyOwner { emergencyMode = true; emit EmergencyModeActivated(msg.sender); }
    function deactivateEmergencyMode() external onlyOwner { emergencyMode = false; emit EmergencyModeDeactivated(msg.sender); }

    /* ========== VIEWS ========== */
    function getUser(address who) external view returns (UserAccount memory) { return userAccounts[who]; }
    function getLevelConfig(MembershipLevel level) external view returns (LevelConfig memory) { return levelConfigs[level]; }
}

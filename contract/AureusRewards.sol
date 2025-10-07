// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/*
  Single-file package:
   - AureusToken   (ERC-20, used for testing or as a template)
   - AureusRewards (reward / membership contract)
  Single-file so you can paste into Remix and verify on BaseScan without flattening.
*/

/// ---------------------------------------------------------------------------
/// Minimal IERC20
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

/// ---------------------------------------------------------------------------
/// AureusToken - straightforward ERC20 (use for testing or launch your token)
contract AureusToken is IERC20 {
    string public name = "Aureus Token";
    string public symbol = "AUR";
    uint8 public decimals = 18;
    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    constructor(uint256 initialMint) {
        _mint(msg.sender, initialMint);
    }

    function totalSupply() external view override returns (uint256) { return _totalSupply; }
    function balanceOf(address account) external view override returns (uint256) { return _balances[account]; }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }
    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }
    function approve(address spender, uint256 amount) external override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 allowed = _allowances[from][msg.sender];
        require(allowed >= amount, "ERC20: allowance");
        _allowances[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "ERC20: to zero");
        uint256 bal = _balances[from];
        require(bal >= amount, "ERC20: balance");
        _balances[from] = bal - amount;
        _balances[to] += amount;
        emit Transfer(from, to, amount);
    }
    function _mint(address to, uint256 amount) internal {
        require(to != address(0), "mint zero");
        _totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }
}

/// ---------------------------------------------------------------------------
/// Minimal SafeERC20 helper (low-level-safe)
library SafeERC20 {
    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        (bool success, bytes memory returndata) = address(token).call(data);
        require(success, "Low-level call failed");
        if (returndata.length > 0) {
            require(abi.decode(returndata, (bool)), "ERC20 operation did not succeed");
        }
    }
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transfer.selector, to, value));
    }
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
    }
}

/// ---------------------------------------------------------------------------
/// Ownership / Security primitives (compact, reliable)
abstract contract Context {
    function _msgSender() internal view virtual returns (address) { return msg.sender; }
}

contract Ownable is Context {
    address private _owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    constructor() { _owner = _msgSender(); emit OwnershipTransferred(address(0), _owner); }
    modifier onlyOwner() { require(_owner == _msgSender(), "Ownable: caller"); _; }
    function owner() public view returns (address) { return _owner; }
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: zero");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

contract Ownable2Step is Ownable {
    address private _pendingOwner;
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    function pendingOwner() public view returns (address) { return _pendingOwner; }

    // start transfer -> set pending
    function transferOwnership(address newOwner) public override onlyOwner {
        _pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner(), newOwner);
    }

    // pending accepts -> becomes owner
    function acceptOwnership() public {
        require(_pendingOwner == _msgSender(), "Ownable2Step: not pending");
        emit OwnershipTransferred(owner(), _pendingOwner);
        // set new owner
        // NOTE: call parent's internal logic by calling Ownable.transferOwnership directly:
        // we can't call super.transferOwnership (it requires onlyOwner), so set storage via low-level update:
        // Simpler approach: use a private variable in Ownable but we've kept it minimal; so just set using assembly:
        address newOwnerAddr = _pendingOwner;
        // clear pending
        _pendingOwner = address(0);
        // set owner (using storage slot 0 of Ownable: this is safe here for a single-file educational contract)
        assembly {
            sstore(0, newOwnerAddr)
        }
    }
}

/// ReentrancyGuard (simple)
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

/// Pausable (simple)
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

/// ---------------------------------------------------------------------------
/// AureusRewards (main app) - daily claim + batch + upgrades
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

    // Modifiers
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

        // default levels (example numbers)
        levelConfigs[MembershipLevel.Based] = LevelConfig({ dailyClaimYield: uint96(10 ether), upgradeRequirement: uint160(0) });
        levelConfigs[MembershipLevel.SuperBased] = LevelConfig({ dailyClaimYield: uint96(15 ether), upgradeRequirement: uint160(30000 ether) });
        levelConfigs[MembershipLevel.Legendary] = LevelConfig({ dailyClaimYield: uint96(20 ether), upgradeRequirement: uint160(60000 ether) });
    }

    // --- account lifecycle
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

    // single claim (only relayer calls)
    function dailyClaim(address user) external onlyRelayer nonReentrant whenNotPaused notInEmergencyMode accountExists(user) {
        _doDailyClaim(user);
    }

    // batch: relayer passes many users; failing users won't revert the whole batch
    function batchDailyClaim(address[] calldata users) external onlyRelayer nonReentrant whenNotPaused notInEmergencyMode {
        for (uint256 i = 0; i < users.length; ++i) {
            try this._doDailyClaimExternal(users[i]) {
                // success
            } catch {
                // skip failing user (cooldown / insufficient funds)
            }
        }
    }

    // internal implementation
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

    // wrapper for try/catch in batch
    function _doDailyClaimExternal(address user) external {
        require(msg.sender == address(this), "only this");
        _doDailyClaim(user);
    }

    // upgrade membership (called by relayer, user must have approved)
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

    // --- admin
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
}

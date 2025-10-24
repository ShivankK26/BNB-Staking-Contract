// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
  AccessStakeBNB (fixed-threshold, no oracle)

  - Users escrow native BNB.
  - Access is active iff escrowed wei >= minStakeWei.
  - Default minStakeWei = 0.005 BNB = 5e15 wei (≈ $5 at ~$1000/BNB). Adjustable by owner.
  - No price feeds. No auto-repricing. No rewards.
*/

contract AccessStakeBNB {
    // --- admin ---
    address public owner;
    bool public paused;
    uint256 public minStakeWei = 5_000_000_000_000_000; // 0.005 BNB

    // --- state ---
    mapping(address => uint256) public balance;  // escrowed wei per user
    uint256 public totalEscrowed;

    // --- reentrancy guard ---
    uint256 private _unlocked = 1;
    modifier lock() { require(_unlocked == 1, "LOCKED"); _unlocked = 0; _; _unlocked = 1; }

    // --- events ---
    event Deposit(address indexed user, uint256 amountWei);
    event Withdraw(address indexed user, uint256 amountWei);
    event Activated(address indexed user);
    event Deactivated(address indexed user);
    event OwnerUpdated(address indexed newOwner);
    event MinStakeUpdated(uint256 newMinStakeWei);
    event Paused(bool state);

    // --- errors ---
    error OwnerOnly();
    error PausedErr();
    error Zero();
    error Insufficient();

    modifier onlyOwner() { if (msg.sender != owner) revert OwnerOnly(); _; }
    modifier notPaused() { if (paused) revert PausedErr(); _; }

    constructor() { owner = msg.sender; }

    // --- admin ops ---
    function setOwner(address n) external onlyOwner { owner = n; emit OwnerUpdated(n); }
    function setPaused(bool p) external onlyOwner { paused = p; emit Paused(p); }
    function setMinStakeWei(uint256 w) external onlyOwner { minStakeWei = w; emit MinStakeUpdated(w); }

    // --- views ---
    function isActive(address u) public view returns (bool) {
        return balance[u] >= minStakeWei;
    }

    /// Convenience for frontends.
    function minBnbWeiRequired() external view returns (uint256) {
        return minStakeWei;
    }

    /// One-call snapshot for backend polling.
    function accountSnapshot(address u) external view returns (
        uint256 balanceWei,
        uint256 minWeiRequired,
        bool active
    ) {
        balanceWei = balance[u];
        minWeiRequired = minStakeWei;
        active = balanceWei >= minWeiRequired;
    }

    // --- user ---
    function deposit() external payable notPaused lock {
        if (msg.value == 0) revert Zero();
        bool wasActive = isActive(msg.sender);

        balance[msg.sender] += msg.value;
        totalEscrowed += msg.value;
        emit Deposit(msg.sender, msg.value);

        bool nowActive = isActive(msg.sender);
        if (nowActive && !wasActive) emit Activated(msg.sender);
        else if (!nowActive && wasActive) emit Deactivated(msg.sender); // unlikely on deposit, kept symmetrical
    }

    function withdraw(uint256 amountWei) public lock {
        if (amountWei == 0) revert Zero();
        uint256 b = balance[msg.sender];
        if (b < amountWei) revert Insufficient();

        bool wasActive = isActive(msg.sender);

        balance[msg.sender] = b - amountWei;
        totalEscrowed -= amountWei;

        (bool ok, ) = msg.sender.call{value: amountWei}("");
        require(ok, "SEND_FAIL");
        emit Withdraw(msg.sender, amountWei);

        bool nowActive = isActive(msg.sender);
        if (nowActive && !wasActive) emit Activated(msg.sender);
        else if (!nowActive && wasActive) emit Deactivated(msg.sender);
    }

    function exit() external { withdraw(balance[msg.sender]); }

    // enforce funnel via deposit()
    receive() external payable { revert("USE_DEPOSIT"); }
    fallback() external payable { revert("NO_FALLBACK"); }
}

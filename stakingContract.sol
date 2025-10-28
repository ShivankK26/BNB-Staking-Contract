// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/*
  AccessStakeBNB (fixed-threshold, no oracle) — OZ-integrated

  - Users escrow native BNB.
  - Access is active iff escrowedWei[account] >= minStakeWei.
  - Default minStakeWei = 0.005 BNB = 5e15 wei. Adjustable by owner.
  - No price feeds. No rewards.
  - Uses Ownable2Step for safer ownership transfer, Pausable for circuit-breaker, ReentrancyGuard for safety.
  - Emergency withdrawal allows accounts to pull all escrowed funds even when paused.
*/

contract AccessStakeBNB is Ownable2Step, ReentrancyGuard, Pausable {
    // --- configuration ---
    uint256 public minStakeWei = 5_000_000_000_000_000; // 0.005 BNB

    // --- state ---
    mapping(address => uint256) public escrowedWei; // escrowed wei per account
    uint256 public totalEscrowedWei;

    // --- events ---
    event Deposit(address indexed account, uint256 amountWei);
    event Withdraw(address indexed account, uint256 amountWei);
    event EmergencyWithdraw(address indexed account, uint256 amountWei);
    event Activated(address indexed account);
    event Deactivated(address indexed account);
    event MinStakeUpdated(uint256 newMinStakeWei);

    // --- errors ---
    error ZeroAmount();
    error InsufficientEscrow();

    // --- constructor ---
    constructor(address initialOwner) {
        _transferOwnership(initialOwner);
    }

    // --- admin ---
    function setMinStakeWei(uint256 newMinStakeWei) external onlyOwner {
        minStakeWei = newMinStakeWei;
        emit MinStakeUpdated(newMinStakeWei);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // --- views ---
    function isActive(address account) public view returns (bool) {
        return escrowedWei[account] >= minStakeWei;
    }

    /// Convenience for frontends.
    function minBnbWeiRequired() external view returns (uint256) {
        return minStakeWei;
    }

    /// One-call snapshot for backend polling.
    function accountSnapshot(address account) external view returns (
        uint256 balanceWei,
        uint256 requiredMinStakeWei,
        bool active
    ) {
        balanceWei = escrowedWei[account];
        requiredMinStakeWei = minStakeWei;
        active = balanceWei >= requiredMinStakeWei;
    }

    // --- user actions ---
    function deposit() external payable whenNotPaused nonReentrant {
        if (msg.value == 0) revert ZeroAmount();

        bool wasActive = isActive(msg.sender);

        escrowedWei[msg.sender] += msg.value;
        totalEscrowedWei += msg.value;
        emit Deposit(msg.sender, msg.value);

        bool nowActive = isActive(msg.sender);
        if (nowActive && !wasActive) emit Activated(msg.sender);
        // deposit cannot deactivate; no else branch
    }

    function withdraw(uint256 withdrawAmountWei) public whenNotPaused nonReentrant {
        if (withdrawAmountWei == 0) revert ZeroAmount();

        uint256 previousBalanceWei = escrowedWei[msg.sender];
        if (previousBalanceWei < withdrawAmountWei) revert InsufficientEscrow();

        bool wasActive = previousBalanceWei >= minStakeWei;

        escrowedWei[msg.sender] = previousBalanceWei - withdrawAmountWei;
        totalEscrowedWei -= withdrawAmountWei;

        (bool ok, ) = msg.sender.call{value: withdrawAmountWei}("");
        require(ok, "SEND_FAIL");
        emit Withdraw(msg.sender, withdrawAmountWei);

        bool nowActive = isActive(msg.sender);
        if (!nowActive && wasActive) emit Deactivated(msg.sender);
    }

    function withdrawAll() external { withdraw(escrowedWei[msg.sender]); }

    /// Emergency path: always available, ignores pause state, no reentrancy into state before transfer.
    function emergencyWithdraw() external nonReentrant {
        uint256 balanceWei = escrowedWei[msg.sender];
        if (balanceWei == 0) revert InsufficientEscrow();

        bool wasActive = balanceWei >= minStakeWei;

        escrowedWei[msg.sender] = 0;
        totalEscrowedWei -= balanceWei;

        (bool ok, ) = msg.sender.call{value: balanceWei}("");
        require(ok, "SEND_FAIL");
        emit EmergencyWithdraw(msg.sender, balanceWei);

        if (wasActive) emit Deactivated(msg.sender);
    }

    // --- receive guards ---
    receive() external payable { revert("USE_DEPOSIT"); }
    fallback() external payable { revert("NO_FALLBACK"); }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract AccessStakeBNB is Ownable2Step, ReentrancyGuard, Pausable {
    uint256 public minStakeWei = 5_000_000_000_000_000; // 0.005 BNB
    mapping(address => uint256) public escrowedWei;
    uint256 public totalEscrowedWei;

    event Deposit(address indexed account, uint256 amountWei);
    event Withdraw(address indexed account, uint256 amountWei);
    event EmergencyWithdraw(address indexed account, uint256 amountWei);
    event Activated(address indexed account);
    event Deactivated(address indexed account);
    event MinStakeUpdated(uint256 newMinStakeWei);

    error ZeroAmount();
    error InsufficientEscrow();

    constructor() Ownable(msg.sender) {}

    function setMinStakeWei(uint256 newMinStakeWei) external onlyOwner {
        minStakeWei = newMinStakeWei;
        emit MinStakeUpdated(newMinStakeWei);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function isActive(address account) public view returns (bool) {
        return escrowedWei[account] >= minStakeWei;
    }

    function minBnbWeiRequired() external view returns (uint256) {
        return minStakeWei;
    }

    function accountSnapshot(address account)
        external
        view
        returns (uint256 balanceWei, uint256 requiredMinStakeWei, bool active)
    {
        balanceWei = escrowedWei[account];
        requiredMinStakeWei = minStakeWei;
        active = balanceWei >= requiredMinStakeWei;
    }

    function deposit() external payable whenNotPaused nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        bool wasActive = isActive(msg.sender);

        escrowedWei[msg.sender] += msg.value;
        totalEscrowedWei += msg.value;
        emit Deposit(msg.sender, msg.value);

        bool nowActive = isActive(msg.sender);
        if (nowActive && !wasActive) emit Activated(msg.sender);
    }

    function withdraw(uint256 withdrawAmountWei) public whenNotPaused nonReentrant {
        if (withdrawAmountWei == 0) revert ZeroAmount();
        uint256 prev = escrowedWei[msg.sender];
        if (prev < withdrawAmountWei) revert InsufficientEscrow();
        bool wasActive = prev >= minStakeWei;

        escrowedWei[msg.sender] = prev - withdrawAmountWei;
        totalEscrowedWei -= withdrawAmountWei;

        (bool ok, ) = msg.sender.call{value: withdrawAmountWei}("");
        require(ok, "SEND_FAIL");
        emit Withdraw(msg.sender, withdrawAmountWei);

        bool nowActive = isActive(msg.sender);
        if (!nowActive && wasActive) emit Deactivated(msg.sender);
    }

    function withdrawAll() external { withdraw(escrowedWei[msg.sender]); }

    function emergencyWithdraw() external nonReentrant {
        uint256 bal = escrowedWei[msg.sender];
        if (bal == 0) revert InsufficientEscrow();
        bool wasActive = bal >= minStakeWei;

        escrowedWei[msg.sender] = 0;
        totalEscrowedWei -= bal;

        (bool ok, ) = msg.sender.call{value: bal}("");
        require(ok, "SEND_FAIL");
        emit EmergencyWithdraw(msg.sender, bal);

        if (wasActive) emit Deactivated(msg.sender);
    }

    receive() external payable { revert("USE_DEPOSIT"); }
    fallback() external payable { revert("NO_FALLBACK"); }
}

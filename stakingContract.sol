// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/*
  SimpleBNBStaking (self-custodied, owner emergency)
  - Users deposit arbitrary amounts of native BNB.
  - Contract records per-user deposited amount.
  - BNB stays in this contract; no forwarding to other contracts.
  - Users can withdraw normally when not paused.
  - Only the owner can perform an emergency withdrawal to recover all contract funds.
*/

contract SimpleBNBStaking is Ownable2Step, ReentrancyGuard, Pausable {
    // --- state ---
    mapping(address => uint256) public depositedWei; // user -> deposited BNB (wei)
    uint256 public totalDepositedWei;

    // --- events ---
    event Deposit(address indexed account, uint256 amountWei);
    event Withdraw(address indexed account, uint256 amountWei);
    event EmergencyOwnerWithdraw(address indexed to, uint256 amountWei);

    // --- errors ---
    error ZeroAmount();
    error InsufficientBalance();
    error NoFunds();

    constructor() Ownable(msg.sender) {}

    // --- admin ---
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // --- views ---
    function getDeposited(address account) external view returns (uint256) {
        return depositedWei[account];
    }

    function accountSnapshot(address account)
        external
        view
        returns (uint256 balanceWei)
    {
        balanceWei = depositedWei[account];
    }

    // --- user actions ---
    function deposit() external payable whenNotPaused nonReentrant {
        if (msg.value == 0) revert ZeroAmount();

        depositedWei[msg.sender] += msg.value;
        totalDepositedWei += msg.value;

        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 withdrawAmountWei) public whenNotPaused nonReentrant {
        if (withdrawAmountWei == 0) revert ZeroAmount();

        uint256 currentBalance = depositedWei[msg.sender];
        if (currentBalance < withdrawAmountWei) revert InsufficientBalance();

        depositedWei[msg.sender] = currentBalance - withdrawAmountWei;
        totalDepositedWei -= withdrawAmountWei;

        (bool ok, ) = msg.sender.call{value: withdrawAmountWei}("");
        require(ok, "SEND_FAIL");

        emit Withdraw(msg.sender, withdrawAmountWei);
    }

    function withdrawAll() external {
        withdraw(depositedWei[msg.sender]);
    }

    // --- owner emergency recovery ---
    function emergencyWithdraw(address payable to) external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        if (balance == 0) revert NoFunds();

        // reset accounting
        totalDepositedWei = 0;

        (bool ok, ) = to.call{value: balance}("");
        require(ok, "SEND_FAIL");

        emit EmergencyOwnerWithdraw(to, balance);
    }

    // --- receive guards ---
    receive() external payable { revert("USE_DEPOSIT"); }
    fallback() external payable { revert("NO_FALLBACK"); }
}

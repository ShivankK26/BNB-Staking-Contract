// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
  AccessStakeBNB (Mainnet)

  - Users escrow native BNB to pass a USD threshold (default $5).
  - Chainlink BNB/USD PROXY (BSC mainnet): 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE
  - Backend: index Deposit/Withdraw/ThresholdUpdated/PriceFeedUpdated to track balances,
    and periodically read accountSnapshot() to reconcile status when price moves.
*/

interface IAggregatorV3 {
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
    function decimals() external view returns (uint8);
}

contract AccessStakeBNB {
    // --- admin ---
    address public owner;
    IAggregatorV3 public priceFeed;               // BNB/USD proxy
    uint256 public minUsd1e8 = 5 * 1e8;          // $5 in 1e8 units
    uint256 public maxPriceAge = 2 hours;        // staleness guard
    bool public paused;

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
    event ThresholdUpdated(uint256 newMinUsd1e8);
    event PriceFeedUpdated(address feed);
    event MaxPriceAgeUpdated(uint256 secondsAge);
    event Paused(bool state);

    // --- errors ---
    error OwnerOnly();
    error PausedErr();
    error BadPrice();
    error StalePrice();
    error Zero();
    error Insufficient();

    modifier onlyOwner() { if (msg.sender != owner) revert OwnerOnly(); _; }
    modifier notPaused() { if (paused) revert PausedErr(); _; }

    // --- constructor: mainnet feed hardcoded ---
    constructor() {
        owner = msg.sender;
        priceFeed = IAggregatorV3(0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE);
    }

    // --- admin ops ---
    function setOwner(address n) external onlyOwner { owner = n; emit OwnerUpdated(n); }
    function setMinUsd1e8(uint256 v) external onlyOwner { minUsd1e8 = v; emit ThresholdUpdated(v); }
    function setMaxPriceAge(uint256 s) external onlyOwner { maxPriceAge = s; emit MaxPriceAgeUpdated(s); }
    function setPaused(bool p) external onlyOwner { paused = p; emit Paused(p); }
    function setPriceFeed(address a) external onlyOwner { priceFeed = IAggregatorV3(a); emit PriceFeedUpdated(a); }

    // --- price ---
    function _bnbUsd1e8_raw() internal view returns (uint256 px1e8, uint256 updatedAt) {
        (, int256 ans,, uint256 upAt,) = priceFeed.latestRoundData();
        if (ans <= 0) revert BadPrice();
        uint256 px = uint256(ans);
        uint8 dec = priceFeed.decimals();
        px1e8 = dec == 8 ? px : (dec > 8 ? px / (10 ** (dec - 8)) : px * (10 ** (8 - dec)));
        updatedAt = upAt;
    }

    function currentPrice1e8() public view returns (uint256 px1e8, uint256 updatedAt) {
        (px1e8, updatedAt) = _bnbUsd1e8_raw();
        if (block.timestamp - updatedAt > maxPriceAge) revert StalePrice();
    }

    // --- views ---
    function isActive(address u) public view returns (bool) {
        (uint256 px1e8, uint256 upAt) = _bnbUsd1e8_raw();
        if (block.timestamp - upAt > maxPriceAge) revert StalePrice();
        uint256 usd1e8 = (balance[u] * px1e8) / 1e18;
        return usd1e8 >= minUsd1e8;
    }

    function minBnbWeiRequired() public view returns (uint256) {
        (uint256 px1e8, uint256 upAt) = _bnbUsd1e8_raw();
        if (block.timestamp - upAt > maxPriceAge) revert StalePrice();
        uint256 num = minUsd1e8 * 1e18;
        return (num + px1e8 - 1) / px1e8; // ceilDiv
    }

    /// One-call snapshot for backend polling.
    function accountSnapshot(address u) external view returns (
        uint256 balanceWei,
        uint256 px1e8,
        uint256 priceUpdatedAt,
        uint256 usd1e8,
        bool active,
        uint256 minWeiRequired
    ) {
        balanceWei = balance[u];
        (px1e8, priceUpdatedAt) = _bnbUsd1e8_raw();
        usd1e8 = (balanceWei * px1e8) / 1e18;
        active = (usd1e8 >= minUsd1e8) && (block.timestamp - priceUpdatedAt <= maxPriceAge);
        // compute required min at same px without re-checking staleness
        uint256 num = minUsd1e8 * 1e18;
        minWeiRequired = (num + px1e8 - 1) / px1e8;
    }

    // --- user ---
    function deposit() external payable notPaused lock {
        if (msg.value == 0) revert Zero();
        bool beforeActive = _activeFlag(msg.sender);
        balance[msg.sender] += msg.value;
        totalEscrowed += msg.value;
        emit Deposit(msg.sender, msg.value);
        _maybeFlip(msg.sender, beforeActive);
    }

    function withdraw(uint256 amountWei) public lock {
        if (amountWei == 0) revert Zero();
        uint256 b = balance[msg.sender];
        if (b < amountWei) revert Insufficient();

        bool beforeActive = _activeFlag(msg.sender);
        balance[msg.sender] = b - amountWei;
        totalEscrowed -= amountWei;

        (bool ok, ) = msg.sender.call{value: amountWei}("");
        require(ok, "SEND_FAIL");
        emit Withdraw(msg.sender, amountWei);
        _maybeFlip(msg.sender, beforeActive);
    }

    function exit() external { withdraw(balance[msg.sender]); }

    // --- helpers ---
    function _activeFlag(address u) internal view returns (bool) {
        (uint256 px1e8, uint256 upAt) = _bnbUsd1e8_raw();
        if (block.timestamp - upAt > maxPriceAge) return false;
        return ((balance[u] * px1e8) / 1e18) >= minUsd1e8;
    }

    function _maybeFlip(address u, bool before) internal {
        bool afterF = _activeFlag(u);
        if (afterF && !before) emit Activated(u);
        else if (!afterF && before) emit Deactivated(u);
    }

    receive() external payable { revert("USE_DEPOSIT"); }
    fallback() external payable { revert("NO_FALLBACK"); }
}

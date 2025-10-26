// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/**
 * @title KipuBank
 * @notice Base contract skeleton for a multi-asset vault. This block sets roles, storage,
 *         naming conventions, modifiers, events and errors required.
 * @dev Next blocks add: Chainlink pricing (USD6), deposits/withdrawals (CEI + call()),
 *      and README/deploy/verify instructions.
 */

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";


// Optional forward import for next block (Chainlink)
// import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract KipuBank is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ========= Roles =========
    /// @notice Admin role for managing caps, feeds and pause.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // ========= Constants / Immutables =========
    /// @notice Accounting will use USD with 6 decimals in next block.
    uint8 public constant USD_DECIMALS = 6;

    /// @notice ETH/USD price feed (immutable). If address(0), ETH deposits are disabled.
    AggregatorV3Interface public immutable ETH_USD_FEED;

    /// @notice Max staleness policy (applied in next block). 0 = not enforced.
    uint256 public constant MAX_STALE_SECONDS = 0;

    // ========= Custom Errors =========
    error AmountZero();
    error UnknownFeed(address token);
    error StalePrice(address token);
    error NegativePrice(address token);
    error BankCapExceeded(uint256 attemptedUsd6, uint256 capUsd6);
    error ExceedsPerTxCap(uint256 attemptedUsd6, uint256 perTxCapUsd6);
    error ZeroAddress();
    error PausedError();

    // ========= Events =========
    event BankCapUpdated(uint256 oldCapUsd6, uint256 newCapUsd6);
    event PerTxCapUpdated(uint256 oldCapUsd6, uint256 newCapUsd6);
    event FeedSet(address indexed token, address indexed feed);
    event ContractPaused(address indexed by);
    event ContractUnpaused(address indexed by);

    /// @notice Emitted when a user deposits ETH or an ERC20 token.
    event Deposited(address indexed user, address indexed token, uint256 tokenAmount, uint256 usd6Amount);

    /// @notice Emitted when a user withdraws ETH or an ERC20 token.
    event Withdrawn(address indexed user, address indexed token, uint256 tokenAmount, uint256 usd6Amount);


    // ========= Storage =========

    /// @notice Global cap in USD6 (applied on deposits in next block).
    uint256 public bankCapUsd6;

    /// @notice Per-transaction withdraw cap in USD6 (applied in next blocks).
    uint256 public withdrawPerTxCapUsd6;

    /// @notice Total TVL in USD6 (updated on deposits/withdrawals in next blocks).
    uint256 public totalBankUsd6;

    /// @notice user => token => balance (token units). address(0) will be ETH.
    mapping(address => mapping(address => uint256)) public balanceOf;

    /// @notice token => total (token units)
    mapping(address => uint256) public totalPerToken;

    /// @notice token => Chainlink token/USD feed. For ETH use token = address(0) and ETH_USD_FEED.
    mapping(address => AggregatorV3Interface) public tokenUsdFeed;

    /// @notice Global pause flag
    bool public isPaused;

    // ========= Constructor =========

    /**
     * @param admin           Admin address (gets DEFAULT_ADMIN_ROLE & ADMIN_ROLE)
     * @param bankCapUsd6_    Global cap in USD6
     * @param perTxCapUsd6_   Per-tx withdraw cap in USD6
     */
    constructor(
        address admin,
        uint256 bankCapUsd6_,
        uint256 perTxCapUsd6_,
        address ethUsdFeed
    ) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);

        bankCapUsd6 = bankCapUsd6_;
        withdrawPerTxCapUsd6 = perTxCapUsd6_;

 // Initialize ETH/USD feed (optional). If address(0), ETH deposits are disabled.
    ETH_USD_FEED = ethUsdFeed == address(0)
        ? AggregatorV3Interface(address(0))
        : AggregatorV3Interface(ethUsdFeed);   
    }

    // ========= Modifiers =========

    /// @notice Reverts if contract is paused
    modifier onlyWhenNotPaused() {
        if (isPaused) revert PausedError();
        _;
    }

    // ========= Admin (minimal, safe-writes, one state write each) =========

    /**
     * @notice Set global bank cap (USD6)
     * @param newCap New cap in USD6
     */
    function setBankCapUsd6(uint256 newCap) external onlyRole(ADMIN_ROLE) {
        uint256 oldCap = bankCapUsd6; // read once
        bankCapUsd6 = newCap;         // write once
        emit BankCapUpdated(oldCap, newCap);
    }
    /**
    * @notice Deposit native ETH.
    * @dev Uses CEI pattern and USD6 accounting via Chainlink.
    * Reverts if paused or if the ETH/USD feed is not set.
    */
    function depositETH() external payable onlyWhenNotPaused nonReentrant {
        uint256 amount = msg.value;
        if (amount == 0) revert AmountZero();

        uint256 usd6 = _toUsd6(address(0), amount);

    // ---- Checks ----
    uint256 totalBankLocal = totalBankUsd6;
    uint256 newTotal = totalBankLocal + usd6;
    uint256 bankCapLocal = bankCapUsd6;
    if (newTotal > bankCapLocal) revert BankCapExceeded(newTotal, bankCapLocal);

    // ---- Effects ----
    balanceOf[msg.sender][address(0)] += amount;
    totalPerToken[address(0)] += amount;
    totalBankUsd6 = newTotal;

    // ---- Interactions ---- (none)
    emit Deposited(msg.sender, address(0), amount, usd6);
}

    /** 
        * @notice Deposit an ERC20 token.
        * @dev Requires prior approval from the token contract.
    */
        function depositERC20(address token, uint256 amount) external onlyWhenNotPaused nonReentrant {
            if (token == address(0)) revert ZeroAddress();
            if (amount == 0) revert AmountZero();

        uint256 usd6 = _toUsd6(token, amount);

    // ---- Checks ----
    uint256 totalBankLocal = totalBankUsd6;
    uint256 newTotal = totalBankLocal + usd6;
    uint256 bankCapLocal = bankCapUsd6;
    if (newTotal > bankCapLocal) revert BankCapExceeded(newTotal, bankCapLocal);

    // ---- Effects ----
    balanceOf[msg.sender][token] += amount;
    totalPerToken[token] += amount;
    totalBankUsd6 = newTotal;

    // ---- Interactions ----
    IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

    emit Deposited(msg.sender, token, amount, usd6);
}

    /**
 * @notice Withdraw native ETH.
 * @dev Uses CEI pattern, price conversion, and `call()` for ETH transfers.
 */
function withdrawETH(uint256 amount) external onlyWhenNotPaused nonReentrant {
    if (amount == 0) revert AmountZero();

    uint256 userBal = balanceOf[msg.sender][address(0)];
    require(userBal >= amount, "Insufficient balance");

    uint256 usd6 = _toUsd6(address(0), amount);
    if (usd6 > withdrawPerTxCapUsd6) revert ExceedsPerTxCap(usd6, withdrawPerTxCapUsd6);

    // ---- Effects ----
    balanceOf[msg.sender][address(0)] = userBal - amount;
    totalPerToken[address(0)] -= amount;
    totalBankUsd6 -= usd6;

    // ---- Interactions ----
    (bool ok, ) = msg.sender.call{value: amount}("");
    require(ok, "ETH transfer failed");

    emit Withdrawn(msg.sender, address(0), amount, usd6);
}

/**
 * @notice Withdraw an ERC20 token.
 */
function withdrawERC20(address token, uint256 amount) external onlyWhenNotPaused nonReentrant {
    if (token == address(0)) revert ZeroAddress();
    if (amount == 0) revert AmountZero();

    uint256 userBal = balanceOf[msg.sender][token];
    require(userBal >= amount, "Insufficient balance");

    uint256 usd6 = _toUsd6(token, amount);
    if (usd6 > withdrawPerTxCapUsd6) revert ExceedsPerTxCap(usd6, withdrawPerTxCapUsd6);

    // ---- Effects ----
    balanceOf[msg.sender][token] = userBal - amount;
    totalPerToken[token] -= amount;
    totalBankUsd6 -= usd6;

    // ---- Interactions ----
    IERC20(token).safeTransfer(msg.sender, amount);

    emit Withdrawn(msg.sender, token, amount, usd6);
}

    /**
     * @notice Set per-transaction withdraw cap (USD6)
     * @param newCap New cap in USD6
     */
    function setWithdrawPerTxCapUsd6(uint256 newCap) external onlyRole(ADMIN_ROLE) {
        uint256 oldCap = withdrawPerTxCapUsd6; // read once
        withdrawPerTxCapUsd6 = newCap;         // write once
        emit PerTxCapUpdated(oldCap, newCap);
    }

    /**
     * @notice Pause contract operations
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        isPaused = true; // write once
        emit ContractPaused(_msgSender());
    }

    /**
     * @notice Unpause contract operations
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        isPaused = false; // write once
        emit ContractUnpaused(_msgSender());
    }

    /**
     * @notice Sets or updates the Chainlink price feed for a given ERC-20 token.
     * @param token The ERC-20 token address (not address(0)).
     * @param feed  The corresponding Chainlink token/USD feed address.
     */
    function setTokenUsdFeed(address token, address feed) external onlyRole(ADMIN_ROLE) {
    if (token == address(0)) revert ZeroAddress();
    tokenUsdFeed[token] = AggregatorV3Interface(feed);
    emit FeedSet(token, feed);
}


    // ========= Fallback =========

    receive() external payable {
        // We require accounted deposits via dedicated functions (next blocks).
        revert("Use dedicated deposit function");
    }

    // ======== Views / Helpers ========

/// @notice Converts a token amount to USD6 using Chainlink price feeds.
/// @param token address(0) for ETH or the ERC-20 token address.
/// @param amount Token amount.
/// @return usd6 Amount in USD with 6 decimals.
function toUsd6(address token, uint256 amount) external view returns (uint256 usd6) {
    return _toUsd6(token, amount);
}

/// @dev Returns the decimals of a token (18 by default if not implemented).
function _decimals(address token) internal view returns (uint8) {
    if (token == address(0)) return 18; // ETH default
    try IERC20Metadata(token).decimals() returns (uint8 d) {
        return d;
    } catch {
        return 18;
    }
}

/// @dev Converts token amounts into USD6 using the latest Chainlink price data.
function _toUsd6(address token, uint256 amount) internal view returns (uint256) {
    if (amount == 0) return 0;

    int256 price;
    uint8 priceDecimals;
    uint256 updatedAt;

    if (token == address(0)) {
        AggregatorV3Interface feed = ETH_USD_FEED;
        if (address(feed) == address(0)) revert UnknownFeed(token);
        (, price,, updatedAt,) = feed.latestRoundData();
        priceDecimals = feed.decimals();
    } else {
        AggregatorV3Interface feed = tokenUsdFeed[token];
        if (address(feed) == address(0)) revert UnknownFeed(token);
        (, price,, updatedAt,) = feed.latestRoundData();
        priceDecimals = feed.decimals();
    }

    if (price <= 0) revert NegativePrice(token);
    if (MAX_STALE_SECONDS != 0 && updatedAt + MAX_STALE_SECONDS < block.timestamp) {
        revert StalePrice(token);
    }

    uint8 tokenDec = _decimals(token);

    // usd6 = amount * price * 10^USD_DECIMALS / 10^tokenDec / 10^priceDecimals
    uint256 a = amount;
    uint256 p = uint256(price);

    if (tokenDec > 0) a = a / (10 ** tokenDec);
    if (priceDecimals > 0) p = p / (10 ** priceDecimals);

    unchecked {
        uint256 num = a * p;
        if (USD_DECIMALS > 0) num = num * (10 ** USD_DECIMALS);
        return num;
    }
}

}
























































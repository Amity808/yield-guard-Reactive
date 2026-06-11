// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @title MockYieldVault
/// @notice A minimal ERC4626-like vault that simulates earning yield on deposited tokens.
///         Used in place of Aave for local testing without needing a mainnet fork.
/// @dev Deposits ERC20 tokens and mints 1:1 share tokens. A `simulateYield` function
///      allows tests to inject yield, increasing the exchange rate.
contract MockYieldVault {
    ERC20 public immutable asset;

    /// @notice Total shares outstanding
    uint256 public totalShares;
    /// @notice Total assets held (increases when yield is simulated)
    uint256 public totalAssets;

    /// @notice Shares held by each depositor
    mapping(address => uint256) public sharesOf;

    event Deposit(address indexed caller, uint256 assets, uint256 shares);
    event Withdraw(address indexed caller, uint256 assets, uint256 shares);
    event YieldSimulated(uint256 amount);

    constructor(address _asset) {
        asset = ERC20(_asset);
    }

    /// @notice Deposit `assets` amount of the underlying token and receive shares
    /// @param assets The amount of underlying tokens to deposit
    /// @param receiver The address that will receive the shares
    /// @return shares The amount of shares minted
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        require(assets > 0, "MockYieldVault: zero deposit");

        // Calculate shares: if totalShares == 0, 1:1. Otherwise proportional.
        if (totalShares == 0) {
            shares = assets;
        } else {
            shares = (assets * totalShares) / totalAssets;
        }

        require(shares > 0, "MockYieldVault: zero shares");

        // Transfer tokens in
        asset.transferFrom(msg.sender, address(this), assets);

        totalShares += shares;
        totalAssets += assets;
        sharesOf[receiver] += shares;

        emit Deposit(msg.sender, assets, shares);
    }

    /// @notice Withdraw underlying tokens by burning shares
    /// @param shares The amount of shares to redeem
    /// @param receiver The address that receives the underlying tokens
    /// @return assets The amount of underlying tokens returned
    function redeem(uint256 shares, address receiver) external returns (uint256 assets) {
        require(shares > 0, "MockYieldVault: zero shares");
        require(sharesOf[msg.sender] >= shares, "MockYieldVault: insufficient shares");

        // Calculate assets to return
        assets = (shares * totalAssets) / totalShares;

        sharesOf[msg.sender] -= shares;
        totalShares -= shares;
        totalAssets -= assets;

        asset.transfer(receiver, assets);

        emit Withdraw(msg.sender, assets, shares);
    }

    /// @notice Preview how many assets a given amount of shares is worth
    /// @param shares The number of shares to preview
    /// @return assets The equivalent underlying token amount
    function previewRedeem(uint256 shares) external view returns (uint256 assets) {
        if (totalShares == 0) return 0;
        assets = (shares * totalAssets) / totalShares;
    }

    /// @notice Preview how many shares a given deposit amount would mint
    /// @param assets The amount of underlying tokens
    /// @return shares The number of shares that would be minted
    function previewDeposit(uint256 assets) external view returns (uint256 shares) {
        if (totalShares == 0) return assets;
        shares = (assets * totalShares) / totalAssets;
    }

    /// @notice Simulate yield accrual by minting additional underlying tokens into the vault.
    ///         This increases the exchange rate so that each share is worth more assets.
    /// @dev Only for testing — in production this would come from Aave's aToken rebasing.
    /// @param amount The amount of yield to inject
    function simulateYield(uint256 amount) external {
        // The caller must have already transferred `amount` tokens to this contract,
        // or this can be called after a direct token transfer.
        totalAssets += amount;
        emit YieldSimulated(amount);
    }

    /// @notice Get the total underlying balance held by this vault
    function totalBalance() external view returns (uint256) {
        return asset.balanceOf(address(this));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Minimal read/write surface of StakingverseVault (LUKSO mainnet, chain 42).
/// Proxy: 0x9F49a95b0c3c9e2A6c77a16C177928294c0F6F04
/// Implementation: 0x1711b2e1b64f38ca33e51b717cfd27acd1bd2e2d
/// Provenance: github.com/Stakingverse/pool-contracts src/StakingverseVault.sol (BUSL-1.1);
///   Blockscout LUKSO verification reports name "StakingverseVault", is_verified = true.
interface IStakingverseVault {
    // --- writes (share / staking lifecycle) ---
    function deposit(address beneficiary) external payable;
    function withdraw(uint256 amount, address beneficiary) external;
    function claim(uint256 amount, address beneficiary) external;

    // --- share accounting views ---
    function sharesOf(address account) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function pendingBalanceOf(address account) external view returns (uint256);
    function claimableBalanceOf(address account) external view returns (uint256);

    // --- global accounting views ---
    function totalShares() external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function totalStaked() external view returns (uint256);
    function totalUnstaked() external view returns (uint256);
    function totalClaimable() external view returns (uint256);
    function totalPendingWithdrawal() external view returns (uint256);

    // --- config / roles ---
    function depositLimit() external view returns (uint256);
    function fee() external view returns (uint32);
    function feeRecipient() external view returns (address);
    function operator() external view returns (address);
    function owner() external view returns (address);
    function paused() external view returns (bool);
    function restricted() external view returns (bool);
}

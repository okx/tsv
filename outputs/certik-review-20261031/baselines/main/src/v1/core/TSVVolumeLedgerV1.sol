// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";

/// @notice Per-security daily volume limits in legal-share WAD, using fixed EST (UTC-5).
contract TSVVolumeLedgerV1 is Initializable, UUPSUpgradeable, Multicall {
    error Unauthorized();
    error InvalidInput();
    error InvalidConfig();
    error QuotaExceeded(bytes32 securityId, uint256 ESTDay);

    bytes32 public constant VOLUME_ORACLE_ROLE = keccak256("VOLUME_ORACLE_ROLE");
    bytes32 public constant UPGRADE_ADMIN_ROLE = keccak256("UPGRADE_ADMIN_ROLE");

    struct DailyQuota {
        uint256 ESTDay;
        uint256 amount;
    }

    TSVRegistryV1 public registry;

    /// @dev The quota applies to each EST day until changed. Amounts are legal-share WAD.
    mapping(bytes32 securityId => uint256 amount) public Quota;
    mapping(bytes32 securityId => mapping(uint256 ESTDay => uint256 amount)) public usedWad;

    event QuotaSet(bytes32 indexed securityId, uint256 amount, bytes32 reasonCode);
    event UsedWadSet(bytes32 indexed securityId, uint256 indexed ESTDay, uint256 amount, bytes32 reasonCode);
    event VolumeUsed(bytes32 indexed securityId, bytes32 indexed poolId, uint256 indexed ESTDay, uint256 amount);

    constructor() {
        _disableInitializers();
    }

    function initialize(address registry_) external initializer {
        if (registry_.code.length == 0) revert InvalidInput();
        registry = TSVRegistryV1(registry_);
    }

    /// @notice Sets daily quotas without resetting volume already used.
    function setQuota(bytes32 securityId, uint256 amount, bytes32 reasonCode) external {
        if (reasonCode == 0) revert InvalidConfig();
        if (!registry.hasRole(VOLUME_ORACLE_ROLE, msg.sender)) revert Unauthorized();
        if (securityId == bytes32(0)) revert InvalidInput();
        Quota[securityId] = amount;
        emit QuotaSet(securityId, amount, reasonCode);
    }

    /// @notice Overwrites daily used volume without changing quotas.
    /// @dev Uses legal-share WAD; zero and values above quota are allowed. Subsequent swaps enforce the quota.
    function setUsedWad(bytes32 securityId, DailyQuota[] calldata values, bytes32 reasonCode) external {
        if (reasonCode == 0) revert InvalidConfig();
        if (!registry.hasRole(VOLUME_ORACLE_ROLE, msg.sender)) revert Unauthorized();
        if (securityId == bytes32(0)) revert InvalidInput();
        for (uint256 i; i < values.length; ++i) {
            usedWad[securityId][values[i].ESTDay] = values[i].amount;
            emit UsedWadSet(securityId, values[i].ESTDay, values[i].amount, reasonCode);
        }
    }

    /// @notice EST midnight is 05:00 UTC; block.timestamp is already in seconds.
    /// @dev Uses fixed UTC-5 throughout the year, without daylight saving time.
    function currentESTDay() public view returns (uint256) {
        return (block.timestamp - 5 hours) / 1 days;
    }

    /// @notice Called by Hook.afterSwap; exactly one leg must have positive legal-share volume.
    function recordSwap(bytes32 poolId, int128 delta0, int128 delta1, uint256 legalShares0, uint256 legalShares1)
        external
    {
        if (msg.sender != registry.hook()) revert Unauthorized();
        if (delta0 == 0 || delta1 == 0 || (delta0 < 0) == (delta1 < 0)) revert InvalidInput();
        if (legalShares0 == 0 && legalShares1 == 0) revert InvalidInput();
        if (legalShares0 > 0 && legalShares1 > 0) revert InvalidInput();
        bytes32 securityId = registry.getPool(poolId).securityId;
        uint256 swapVolume = legalShares0 == 0 ? legalShares1 : legalShares0;
        if (securityId == bytes32(0)) revert InvalidInput();

        uint256 ESTDay = currentESTDay();
        uint256 quota = Quota[securityId];
        usedWad[securityId][ESTDay] += swapVolume;
        if (usedWad[securityId][ESTDay] > quota) revert QuotaExceeded(securityId, ESTDay);
        emit VolumeUsed(securityId, poolId, ESTDay, swapVolume);
    }

    function _authorizeUpgrade(address) internal view override {
        if (!registry.hasRole(UPGRADE_ADMIN_ROLE, msg.sender)) revert Unauthorized();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";

/// @notice Per-security daily volume limits in legal-share WAD, using fixed EST (UTC-5).
contract TSVVolumeLedgerV1 is Initializable, UUPSUpgradeable {
    error Unauthorized();
    error InvalidInput();
    error QuotaExceeded(bytes32 securityId, uint256 ESTDay);

    bytes32 public constant VOLUME_ORACLE_ROLE = keccak256("VOLUME_ORACLE_ROLE");
    bytes32 public constant UPGRADE_ADMIN_ROLE = keccak256("UPGRADE_ADMIN_ROLE");

    struct DailyADTV {
        uint256 ESTDay;
        uint256 amount;
    }

    TSVRegistryV1 public registry;

    /// @dev ESTDay is an epoch day number, not YYYYMMDD. Amounts are daily quotas in WAD.
    mapping(bytes32 securityId => mapping(uint256 ESTDay => uint256 amount)) public ADTV;
    mapping(bytes32 securityId => mapping(uint256 ESTDay => uint256 amount)) public usedWad;

    event ADTVSet(bytes32 indexed securityId, uint256 indexed ESTDay, uint256 amount);
    event VolumeUsed(bytes32 indexed securityId, uint256 indexed ESTDay, uint256 amount);

    constructor() {
        _disableInitializers();
    }

    function initialize(address registry_) external initializer {
        if (registry_.code.length == 0) revert InvalidInput();
        registry = TSVRegistryV1(registry_);
    }

    /// @notice Sets daily quotas without resetting volume already used.
    function setADTV(bytes32 securityId, DailyADTV[] calldata values) external {
        if (!registry.hasRole(VOLUME_ORACLE_ROLE, msg.sender)) revert Unauthorized();
        if (securityId == bytes32(0)) revert InvalidInput();
        for (uint256 i; i < values.length; ++i) {
            ADTV[securityId][values[i].ESTDay] = values[i].amount;
            emit ADTVSet(securityId, values[i].ESTDay, values[i].amount);
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
        uint256 swapVolume = legalShares0 + legalShares1;
        if (securityId == bytes32(0)) revert InvalidInput();

        uint256 ESTDay = currentESTDay();
        uint256 quota = ADTV[securityId][ESTDay];
        usedWad[securityId][ESTDay] += swapVolume;
        if (usedWad[securityId][ESTDay] > quota) revert QuotaExceeded(securityId, ESTDay);
        emit VolumeUsed(securityId, ESTDay, swapVolume);
    }

    function _authorizeUpgrade(address) internal view override {
        if (!registry.hasRole(UPGRADE_ADMIN_ROLE, msg.sender)) revert Unauthorized();
    }
}

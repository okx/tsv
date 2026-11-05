// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {
    UnderlyingRecord,
    QuoteTokenRecord,
    TierPolicyRecord,
    SecurityRecord,
    PermissionedRegisterParam
} from "tsv-v1/types/TSVTypes.sol";
import {IPermissionsAdapterFactory} from "tsv-v1/vendor/permissionedPools/interfaces/IPermissionsAdapterFactory.sol";
import {IDirectLegalShareAdapter} from "tsv-v1/interfaces/IDirectLegalShareAdapter.sol";

/// @notice Registers a list of W/U/security bindings; each item has its own reason code.
/// @dev U is derived from the Registry's Factory-verified W and checked against the configured expected U.
contract RegisterStocks is Script {
    uint256 private constant XLAYER_MAINNET_CHAIN_ID = 196;

    function run() external {
        require(block.chainid == XLAYER_MAINNET_CHAIN_ID, "wrong chain: expected XLayer mainnet 196");

        uint256 privateKey = vm.envUint("XLAYER_PRIVATE_KEY");
        address admin = vm.addr(privateKey);
        TSVRegistryV1 registry = TSVRegistryV1(vm.envAddress("TSV_REGISTRY"));
        uint256 count = vm.envUint("TSV_STOCK_COUNT");

        require(address(registry).code.length != 0, "TSV_REGISTRY has no code");
        require(count != 0, "TSV_STOCK_COUNT is zero");
        require(registry.hasRole(registry.SYMBOL_ADMIN_ROLE(), admin), "signer lacks SYMBOL_ADMIN_ROLE");

        IPermissionsAdapterFactory factory = IPermissionsAdapterFactory(registry.permissionsAdapterFactory());
        require(address(factory).code.length != 0, "Registry Factory has no code");

        address[] memory wrappers = new address[](count);
        address[] memory underlyings = new address[](count);
        bytes32[] memory securityIds = new bytes32[](count);
        address[] memory adapters = new address[](count);
        uint8[] memory tierIds = new uint8[](count);
        bytes32[] memory reasons = new bytes32[](count);

        for (uint256 i; i < count; ++i) {
            string memory suffix = vm.toString(i);
            address wrapped = vm.envAddress(string.concat("TSV_STOCK_WRAPPED_", suffix));
            address expectedUnderlying = vm.envAddress(string.concat("TSV_STOCK_UNDERLYING_", suffix));
            bytes32 securityId = vm.envBytes32(string.concat("TSV_STOCK_SECURITY_ID_", suffix));
            address legalShareAdapter = vm.envAddress(string.concat("TSV_STOCK_LEGAL_SHARE_ADAPTER_", suffix));
            uint256 tierRaw = vm.envUint(string.concat("TSV_STOCK_TIER_ID_", suffix));
            bytes32 reasonCode = vm.envBytes32(string.concat("TSV_STOCK_REASON_", suffix));

            require(wrapped.code.length != 0, "stock wrapper has no code");
            require(expectedUnderlying.code.length != 0, "expected underlying has no code");
            require(legalShareAdapter.code.length != 0, "legal-share adapter has no code");
            require(securityId != bytes32(0), "security ID must be nonzero");
            require(tierRaw > 0 && tierRaw <= type(uint8).max, "tier ID must be 1..255");
            // forge-lint: disable-next-line(unsafe-typecast)
            uint8 tierId = uint8(tierRaw);
            require(reasonCode != bytes32(0), "stock reason code must be nonzero");
            require(registry.getCurrencyUnderlying(wrapped) == address(0), "stock wrapper is already registered");

            address underlying = factory.verifiedPermissionsAdapterOf(wrapped);
            require(underlying != address(0) && underlying.code.length != 0, "stock wrapper is not Factory-verified");
            require(underlying == expectedUnderlying, "configured U does not match Factory-derived U");
            require(underlying != legalShareAdapter && wrapped != legalShareAdapter, "adapter aliases an asset");
            require(!registry.getQuoteToken(underlying).registered, "underlying is an active quote token");
            require(registry.getCurrencyUnderlying(underlying) == address(0), "underlying is a registered wrapper");

            SecurityRecord memory security = registry.getSecurity(securityId);
            if (security.securityId != bytes32(0)) {
                require(security.listed, "existing security is delisted");
                require(security.tierId == tierId, "existing security tier mismatch");
            }

            UnderlyingRecord memory underlyingRecord = registry.getUnderlying(underlying);
            if (underlyingRecord.securityId != bytes32(0)) {
                require(underlyingRecord.securityId == securityId, "underlying belongs to another security");
                require(underlyingRecord.legalShareAdapter == legalShareAdapter, "canonical adapter mismatch");
            }

            IDirectLegalShareAdapter converter = IDirectLegalShareAdapter(legalShareAdapter);
            require(converter.poolCurrency() == underlying, "legal-share adapter is bound to another U");
            require(converter.currentMultiplier(underlying) != 0, "legal-share multiplier is zero");

            for (uint256 j; j < i; ++j) {
                require(wrappers[j] != wrapped, "duplicate W in registration list");
                if (underlyings[j] == underlying) {
                    require(securityIds[j] == securityId, "same U assigned to multiple securities");
                    require(adapters[j] == legalShareAdapter, "same U assigned multiple adapters");
                }
                if (securityIds[j] == securityId) {
                    require(tierIds[j] == tierId, "same security assigned multiple tiers");
                }
            }

            wrappers[i] = wrapped;
            underlyings[i] = underlying;
            securityIds[i] = securityId;
            adapters[i] = legalShareAdapter;
            tierIds[i] = tierId;
            reasons[i] = reasonCode;

            console2.log("W:", wrapped);
            console2.log("U:", underlying);
            console2.log("Security ID:");
            console2.logBytes32(securityId);
            console2.log("Legal-share adapter:", legalShareAdapter);
            console2.log("Tier ID:", tierRaw);
            console2.log("Operation reason:");
            console2.logBytes32(reasonCode);
        }

        _checkTierCapacity(registry, securityIds, tierIds);

        console2.log("XLayer chainId:", block.chainid);
        console2.log("Registry:", address(registry));
        console2.log("Admin:", admin);
        vm.startBroadcast(privateKey);
        for (uint256 i; i < count; ++i) {
            registry.registerPermissionedCurrency(
                PermissionedRegisterParam({
                    currency: wrappers[i], securityId: securityIds[i], legalShareAdapter: adapters[i]
                }),
                tierIds[i],
                reasons[i]
            );
        }
        vm.stopBroadcast();
    }

    function _checkTierCapacity(TSVRegistryV1 registry, bytes32[] memory securityIds, uint8[] memory tierIds)
        private
        view
    {
        for (uint256 i; i < securityIds.length; ++i) {
            if (registry.getSecurity(securityIds[i]).securityId != bytes32(0)) continue;
            bool firstForSecurity = true;
            for (uint256 j; j < i; ++j) {
                if (securityIds[j] == securityIds[i]) firstForSecurity = false;
            }
            if (!firstForSecurity) continue;

            uint256 newSecuritiesInTier;
            for (uint256 j; j < securityIds.length; ++j) {
                if (tierIds[j] != tierIds[i]) continue;
                if (registry.getSecurity(securityIds[j]).securityId != bytes32(0)) continue;
                bool firstForCandidate = true;
                for (uint256 k; k < j; ++k) {
                    if (securityIds[k] == securityIds[j]) firstForCandidate = false;
                }
                if (firstForCandidate) newSecuritiesInTier++;
            }

            TierPolicyRecord memory tier = registry.getTierPolicy(tierIds[i]);
            require(tier.maxListed >= tier.listedCount + newSecuritiesInTier, "tier lacks listing capacity");
        }
    }
}

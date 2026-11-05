// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {ERC8056DirectLegalShareAdapter} from "tsv-v1/adapters/ERC8056DirectLegalShareAdapter.sol";
import {IDirectLegalShareAdapter} from "tsv-v1/interfaces/IDirectLegalShareAdapter.sol";
import {IPermissionsAdapter} from "tsv-v1/vendor/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {PermissionedRegisterParam} from "tsv-v1/types/TSVTypes.sol";

contract TSVMultiplierAdmissionTest is FoundationFixture {
    bytes32 private constant NEW_SECURITY = keccak256("OTA01_NEW_SECURITY");

    function testAdmissionRejectsZeroLiveMultiplierAndRollsBackListing() public {
        (PermissionedRegisterParam memory admission, address u) = _newAdmission();
        bytes32 beforeState = _admissionState(u);
        vm.mockCall(admission.legalShareAdapter, _multiplierCall(u), abi.encode(uint256(0)));

        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.registerPermissionedCurrency(admission, 1, bytes32("TEST"));
        _assertAdmissionUnchanged(admission, u, beforeState);
    }

    function testAdmissionRejectsUnavailableLiveMultiplierAndRollsBackListing() public {
        (PermissionedRegisterParam memory admission, address u) = _newAdmission();
        bytes32 beforeState = _admissionState(u);
        bytes memory reason = abi.encodeWithSignature("MultiplierUnavailable()");
        vm.mockCallRevert(admission.legalShareAdapter, _multiplierCall(u), reason);

        vm.expectRevert(reason);
        registry.registerPermissionedCurrency(admission, 1, bytes32("TEST"));
        _assertAdmissionUnchanged(admission, u, beforeState);
    }

    function testAdmissionRejectsMalformedLiveMultiplierAndRollsBackListing() public {
        (PermissionedRegisterParam memory admission, address u) = _newAdmission();
        bytes32 beforeState = _admissionState(u);
        uint256[3] memory lengths = [uint256(0), 1, 31];
        for (uint256 i; i < lengths.length; ++i) {
            vm.mockCall(admission.legalShareAdapter, _multiplierCall(u), new bytes(lengths[i]));
            vm.expectRevert(TSVRegistryV1.InvalidPermissionedConfig.selector);
            registry.registerPermissionedCurrency(admission, 1, bytes32("TEST"));
            _assertAdmissionUnchanged(admission, u, beforeState);
            vm.clearMockedCalls();
        }
    }

    function testReplacementRejectsZeroLiveMultiplierAndPreservesAdapterAndUsage() public {
        ERC8056DirectLegalShareAdapter replacement = new ERC8056DirectLegalShareAdapter(address(stockToken));
        vm.mockCall(address(replacement), _multiplierCall(address(stockToken)), abi.encode(uint256(0)));
        _submitQuota(100e18);
        _charge(1e18);
        bytes32 beforeState = keccak256(abi.encode(registry.getUnderlying(address(stockToken))));

        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.replaceUnderlyingLegalShareAdapter(address(stockToken), address(replacement), bytes32("TEST"));
        assertEq(keccak256(abi.encode(registry.getUnderlying(address(stockToken)))), beforeState);
        assertEq(ledger.usedWad(SECURITY, DAY), 1e18);
    }

    function testReplacementRejectsUnavailableLiveMultiplierAndPreservesAdapter() public {
        ERC8056DirectLegalShareAdapter replacement = new ERC8056DirectLegalShareAdapter(address(stockToken));
        bytes memory reason = abi.encodeWithSignature("MultiplierUnavailable()");
        vm.mockCallRevert(address(replacement), _multiplierCall(address(stockToken)), reason);

        vm.expectRevert(reason);
        registry.replaceUnderlyingLegalShareAdapter(address(stockToken), address(replacement), bytes32("TEST"));
        assertEq(registry.getUnderlying(address(stockToken)).legalShareAdapter, address(stockAdapter));
    }

    function testReplacementRejectsMalformedLiveMultiplierAndPreservesAdapter() public {
        ERC8056DirectLegalShareAdapter replacement = new ERC8056DirectLegalShareAdapter(address(stockToken));
        uint256[3] memory lengths = [uint256(0), 1, 31];
        for (uint256 i; i < lengths.length; ++i) {
            vm.mockCall(address(replacement), _multiplierCall(address(stockToken)), new bytes(lengths[i]));
            vm.expectRevert(TSVRegistryV1.InvalidPermissionedConfig.selector);
            registry.replaceUnderlyingLegalShareAdapter(address(stockToken), address(replacement), bytes32("TEST"));
            assertEq(registry.getUnderlying(address(stockToken)).legalShareAdapter, address(stockAdapter));
            vm.clearMockedCalls();
        }
    }

    function testAdmissionAcceptsSmallPositiveMultiplierWithoutTestingDustConversion() public {
        (PermissionedRegisterParam memory admission, address u) = _newAdmission();
        vm.mockCall(u, abi.encodeWithSignature("uiMultiplier()"), abi.encode(uint256(1)));
        registry.registerPermissionedCurrency(admission, 1, bytes32("TEST"));

        assertEq(registry.getCurrencyUnderlying(admission.currency), u);
        assertEq(IDirectLegalShareAdapter(admission.legalShareAdapter).currentMultiplier(u), 1);
    }

    function testAdmissionDoesNotCacheMultiplierOrPreventLaterValidChanges() public {
        (PermissionedRegisterParam memory admission, address u) = _newAdmission();
        registry.registerPermissionedCurrency(admission, 1, bytes32("TEST"));
        vm.mockCall(u, abi.encodeWithSignature("uiMultiplier()"), abi.encode(uint256(2e18)));

        address boundAdapter = registry.getUnderlying(u).legalShareAdapter;
        assertEq(boundAdapter, admission.legalShareAdapter);
        assertEq(IDirectLegalShareAdapter(boundAdapter).currentMultiplier(u), 2e18);
    }

    function _newAdmission() private returns (PermissionedRegisterParam memory admission, address u) {
        admission = _newStockConfig(NEW_SECURITY);
        u = address(IPermissionsAdapter(admission.currency).PERMISSIONED_TOKEN());
    }

    function _multiplierCall(address u) private pure returns (bytes memory) {
        return abi.encodeCall(IDirectLegalShareAdapter.currentMultiplier, (u));
    }

    function _admissionState(address u) private view returns (bytes32) {
        return
            keccak256(
                abi.encode(registry.getSecurity(NEW_SECURITY), registry.getUnderlying(u), registry.getTierPolicy(1))
            );
    }

    function _assertAdmissionUnchanged(PermissionedRegisterParam memory admission, address u, bytes32 beforeState)
        private
        view
    {
        assertEq(registry.getCurrencyUnderlying(admission.currency), address(0));
        assertEq(_admissionState(u), beforeState);
    }
}

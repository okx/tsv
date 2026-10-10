// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVDataInboxV1} from "tsv-v1/core/TSVDataInboxV1.sol";
import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";
import {V1PermissionedComponent} from "../../../helpers/v1/PermissionedMocks.sol";

contract TSVOperationsBindingsTest is FoundationFixture {
    function testLedgerAndInboxInitializationRejectZeroDependenciesAndInvalidOffsets() public {
        address ledgerImpl = address(new TSVVolumeLedgerV1());
        address inboxImpl = address(new TSVDataInboxV1());
        vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
        new ERC1967Proxy(ledgerImpl, abi.encodeCall(TSVVolumeLedgerV1.initialize, (address(0), 14400)));
        vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
        new ERC1967Proxy(ledgerImpl, abi.encodeCall(TSVVolumeLedgerV1.initialize, (address(registry), 86400)));
        vm.expectRevert(TSVDataInboxV1.InvalidReport.selector);
        new ERC1967Proxy(inboxImpl, abi.encodeCall(TSVDataInboxV1.initialize, (address(0), address(ledger))));
        vm.expectRevert(TSVDataInboxV1.InvalidReport.selector);
        new ERC1967Proxy(inboxImpl, abi.encodeCall(TSVDataInboxV1.initialize, (address(registry), address(0))));
        TSVVolumeLedgerV1 maxOffset = TSVVolumeLedgerV1(
            address(
                new ERC1967Proxy(ledgerImpl, abi.encodeCall(TSVVolumeLedgerV1.initialize, (address(registry), 86399)))
            )
        );
        assertEq(maxOffset.initialDayStartOffsetSeconds(), 86399);
    }

    function testRegistryBindingIsGovernorOnlyAtomicAndOneTime() public {
        TSVRegistryV1 fresh = TSVRegistryV1(
            address(
                new ERC1967Proxy(
                    address(new TSVRegistryV1()), abi.encodeCall(TSVRegistryV1.initialize, (address(this)))
                )
            )
        );
        V1PermissionedComponent h =
            new V1PermissionedComponent(address(manager), address(fresh), address(permissionsFactory));
        V1PermissionedComponent lp =
            new V1PermissionedComponent(address(manager), address(fresh), address(permissionsFactory));
        V1PermissionedComponent router_ =
            new V1PermissionedComponent(address(manager), address(fresh), address(permissionsFactory));
        h.setLinks(address(router_), address(lp), address(ledger));
        address stranger = makeAddr("binding-outsider");
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bytes32(0))
        );
        vm.prank(stranger);
        fresh.bindComponents(address(h), address(lp), address(inbox), address(permissionsFactory), address(identitySbt));
        for (uint8 slot; slot < 5; ++slot) {
            address[5] memory components =
                [address(h), address(lp), address(inbox), address(permissionsFactory), address(identitySbt)];
            components[slot] = stranger;
            vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
            fresh.bindComponents(components[0], components[1], components[2], components[3], components[4]);
            assertEq(fresh.hook(), address(0));
            assertEq(fresh.lpManager(), address(0));
            assertEq(fresh.dataInbox(), address(0));
            assertEq(address(fresh.participantSbt()), address(0));
        }
        fresh.bindComponents(address(h), address(lp), address(inbox), address(permissionsFactory), address(identitySbt));
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        fresh.bindComponents(address(h), address(lp), address(inbox), address(permissionsFactory), address(identitySbt));
        assertEq(fresh.dataInbox(), address(inbox));
    }

    function testLedgerWriterBindingIsGovernorOnlyAtomicAndOneTime() public {
        TSVVolumeLedgerV1 fresh = TSVVolumeLedgerV1(
            address(
                new ERC1967Proxy(
                    address(new TSVVolumeLedgerV1()),
                    abi.encodeCall(TSVVolumeLedgerV1.initialize, (address(registry), 14400))
                )
            )
        );
        address stranger = makeAddr("writer-outsider");
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bytes32(0))
        );
        vm.prank(stranger);
        fresh.bindWriters(address(this), address(inbox));
        for (uint8 slot; slot < 2; ++slot) {
            vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
            fresh.bindWriters(slot == 0 ? stranger : address(this), slot == 1 ? stranger : address(inbox));
            assertEq(fresh.hook(), address(0));
            assertEq(fresh.dataInbox(), address(0));
        }
        vm.expectEmit(true, true, false, true, address(fresh));
        emit TSVVolumeLedgerV1.WritersBound(address(this), address(inbox));
        fresh.bindWriters(address(this), address(inbox));
        vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
        fresh.bindWriters(address(this), address(inbox));
        assertEq(fresh.hook(), address(this));
        assertEq(fresh.dataInbox(), address(inbox));
    }
}

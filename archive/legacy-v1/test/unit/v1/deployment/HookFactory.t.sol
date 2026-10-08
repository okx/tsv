// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PermissionsAdapterFactory} from "v4-periphery/hooks/permissionedPools/PermissionsAdapterFactory.sol";
import {Test} from "forge-std/Test.sol";

import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";
import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVHookProxyFactoryV1} from "tsv-v1/deployment/TSVHookProxyFactoryV1.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVDataInboxV1} from "tsv-v1/core/TSVDataInboxV1.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {V1LocalSBT} from "../../../helpers/v1/LocalMocks.sol";

/// @dev Exercises CREATE/CREATE2 address prediction and Hook proxy deployment only.
contract TSVHookFactoryTest is Test {
    /// @dev Collects the deployments and dependencies shared by Hook factory tests.
    struct Base {
        /// @dev Governance anchor for the fixture.
        TSVGovernanceAnchor anchor;
        /// @dev Registry proxy used by the core components.
        TSVRegistryV1 registry;
        /// @dev Volume Ledger proxy used by the Hook and Inbox.
        TSVVolumeLedgerV1 ledger;
        /// @dev Data Inbox proxy used for test report submission.
        TSVDataInboxV1 inbox;
        /// @dev Swap Router implementation deployed for the fixture.
        address routerImpl;
        /// @dev LP Manager implementation deployed for the fixture.
        address lpImpl;
        /// @dev Hook implementation deployed for the fixture.
        address hookImpl;
        /// @dev Factory used to deploy the Hook proxy at a V4-compatible address.
        TSVHookProxyFactoryV1 factory;
        /// @dev Swap Router proxy used by the deployed Hook.
        TSVSwapRouterV1 router;
        /// @dev LP Manager proxy used by the deployed Hook.
        TSVLPManagerV1 lp;
        /// @dev Hook proxy deployed for the fixture.
        TSVHookV1 hook;
    }

    /// @dev Verifies proxy rejects empty initialization data.
    function testProxyRejectsEmptyInitializationData() public {
        TSVHookV1 implementation = new TSVHookV1();

        vm.expectRevert(TSVERC1967Proxy.EmptyInitializationData.selector);
        new TSVERC1967Proxy(address(implementation), "");
    }

    /// @dev Verifies mined proxy has V4 permissions and stable implementation getter.
    function testMinedProxyHasV4PermissionsAndStableImplementationGetter() public {
        TSVHookProxyFactoryV1 factory = new TSVHookProxyFactoryV1();
        TSVHookV1 implementation = new TSVHookV1();
        Base memory d = _makeGovernance();
        vm.etch(address(0xBEEF), hex"00");
        vm.etch(address(0xF00D), hex"00");
        bytes memory initData = abi.encodeCall(
            TSVHookV1.initialize,
            (address(d.anchor), address(this), address(this), address(this), address(0xBEEF), address(0xF00D))
        );
        bytes32 salt;
        address predicted;
        for (uint256 i; i < 100_000; ++i) {
            salt = bytes32(i);
            predicted = factory.predict(address(implementation), initData, salt);
            if ((uint160(predicted) & 0x3FFF) == 0x3FFF) break;
        }
        assertEq(uint160(predicted) & 0x3FFF, 0x3FFF);
        address proxy = factory.deploy(address(implementation), initData, salt);
        assertEq(proxy, predicted);
        assertEq(TSVERC1967Proxy(payable(proxy)).tsvImplementation(), address(implementation));
        assertEq(address(TSVHookV1(proxy).governanceAnchor()), address(d.anchor));
        assertTrue(TSVHookV1(proxy).hasRole(0, address(this)));
        vm.expectRevert();
        factory.deploy(address(implementation), initData, salt);
    }

    /// @dev Verifies wrong permission salt reverts.
    function testWrongPermissionSaltReverts() public {
        TSVHookProxyFactoryV1 factory = new TSVHookProxyFactoryV1();
        TSVHookV1 implementation = new TSVHookV1();
        bytes memory initData = abi.encodeCall(
            TSVHookV1.initialize, (address(1), address(4), address(5), address(6), address(7), address(8))
        );
        bytes32 salt;
        while ((uint160(factory.predict(address(implementation), initData, salt)) & 0x3FFF) == 0x3FFF) {
            salt = bytes32(uint256(salt) + 1);
        }
        vm.expectRevert(TSVHookProxyFactoryV1.InvalidHookAddress.selector);
        factory.deploy(address(implementation), initData, salt);
    }

    /// @dev Verifies six proxy deployment uses actual predicted addresses.
    function testSixProxyDeploymentUsesActualPredictedAddresses() public {
        vm.warp(1_800_000_000);
        Base memory d = _deployBase();
        uint64 nextNonce = vm.getNonce(address(this));
        address predictedRouter = vm.computeCreateAddress(address(this), nextNonce);
        address predictedLp = vm.computeCreateAddress(address(this), uint256(nextNonce) + 1);
        bytes memory hookInit = abi.encodeCall(
            TSVHookV1.initialize,
            (address(d.anchor), address(this), address(d.registry), address(d.ledger), predictedRouter, predictedLp)
        );
        bytes32 salt;
        address predictedHook;
        for (uint256 i; i < 100_000; ++i) {
            salt = bytes32(i);
            predictedHook = d.factory.predict(d.hookImpl, hookInit, salt);
            if ((uint160(predictedHook) & 0x3FFF) == 0x3FFF) break;
        }
        assertEq(uint160(predictedHook) & 0x3FFF, 0x3FFF);

        TSVSwapRouterV1 router = _deployRouter(d);
        TSVLPManagerV1 lp = _deployLp(d);
        TSVHookV1 hook = TSVHookV1(d.factory.deploy(d.hookImpl, hookInit, salt));

        assertEq(address(router), predictedRouter);
        assertEq(address(lp), predictedLp);
        assertEq(address(hook), predictedHook);
        assertEq(hook.router(), address(router));
        assertEq(hook.lpManager(), address(lp));
        d.registry
            .bindComponents(
                address(hook),
                address(lp),
                address(d.inbox),
                address(router.PERMISSIONS_ADAPTER_FACTORY()),
                address(new V1LocalSBT())
            );
        d.ledger.bindWriters(address(hook), address(d.inbox));
        assertEq(d.registry.hook(), address(hook));
        assertEq(d.ledger.hook(), address(hook));
        address[6] memory addresses =
            [address(d.registry), address(d.ledger), address(d.inbox), address(hook), address(router), address(lp)];
        address[6] memory wrongAddresses;
        for (uint256 i; i < 6; ++i) {
            wrongAddresses[i] = addresses[i];
        }
        wrongAddresses[5] = address(router);
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        d.anchor.bindProxies(wrongAddresses);
        d.anchor.bindProxies(addresses);
        assertTrue(d.anchor.proxiesBound());
        d.router = router;
        d.lp = lp;
        d.hook = hook;
    }

    /// @dev Deploys the base contracts shared by the Hook factory scenario.
    function _deployBase() private returns (Base memory d) {
        d = _makeGovernance();
        d.registry = TSVRegistryV1(
            address(
                new TSVERC1967Proxy(
                    address(new TSVRegistryV1()), abi.encodeCall(TSVRegistryV1.initialize, (address(d.anchor)))
                )
            )
        );
        d.ledger = TSVVolumeLedgerV1(
            address(
                new TSVERC1967Proxy(
                    address(new TSVVolumeLedgerV1()),
                    abi.encodeCall(TSVVolumeLedgerV1.initialize, (address(d.anchor), address(d.registry), uint32(0)))
                )
            )
        );
        d.inbox = TSVDataInboxV1(
            address(
                new TSVERC1967Proxy(
                    address(new TSVDataInboxV1()),
                    abi.encodeCall(
                        TSVDataInboxV1.initialize, (address(d.anchor), address(d.registry), address(d.ledger))
                    )
                )
            )
        );
        d.routerImpl =
            address(new TSVSwapRouterV1(address(this), address(new PermissionsAdapterFactory(address(this)))));
        d.lpImpl = address(new TSVLPManagerV1());
        d.hookImpl = address(new TSVHookV1());
        d.factory = new TSVHookProxyFactoryV1();
    }

    /// @dev Deploys and initializes the Swap Router proxy for the fixture.
    function _deployRouter(Base memory d) private returns (TSVSwapRouterV1) {
        return TSVSwapRouterV1(
            address(
                new TSVERC1967Proxy(
                    d.routerImpl,
                    abi.encodeCall(TSVSwapRouterV1.initialize, (address(d.anchor), address(this), address(d.registry)))
                )
            )
        );
    }

    /// @dev Deploys and initializes the LP Manager proxy for the fixture.
    function _deployLp(Base memory d) private returns (TSVLPManagerV1) {
        return TSVLPManagerV1(
            address(
                new TSVERC1967Proxy(
                    d.lpImpl,
                    abi.encodeCall(TSVLPManagerV1.initialize, (address(d.anchor), address(this), address(d.registry)))
                )
            )
        );
    }

    /// @dev Deploys and links the governance contracts required by the fixture.
    function _makeGovernance() private returns (Base memory d) {
        d.anchor = new TSVGovernanceAnchor(address(this), makeAddr("guardian"), makeAddr("council"));
    }
}

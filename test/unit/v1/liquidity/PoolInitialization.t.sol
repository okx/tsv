// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TestTokenApproveProxy} from "../../../helpers/TokenApproveMocks.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {
    TSVLPManagerV1,
    IPoolManager,
    IAllowanceTransfer,
    IPositionDescriptor,
    IWETH9,
    IPermissionsAdapterFactory,
    ITSVPermissionedRegistry,
    PoolKey,
    Currency,
    IHooks
} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";

/// @dev A stateful Registry stand-in isolates registration ordering and transaction rollback.
contract PoolRegistrationRecorder {
    using PoolIdLibrary for PoolKey;
    address public lpManager;
    bool public rejectRegistration;
    mapping(bytes32 => bool) public registered;

    function configure(address lp, bool reject) external {
        lpManager = lp;
        rejectRegistration = reject;
    }

    function registerPool(PoolKey calldata key) external returns (bytes32 id) {
        require(msg.sender == lpManager, "not LP manager");
        require(!rejectRegistration, "registration rejected");
        id = PoolId.unwrap(key.toId());
        require(!registered[id], "already registered");
        registered[id] = true;
    }
}

/// @dev Checks the same sender/registration prerequisite as TSV's beforeInitialize.
contract RegisteredPoolInitializationHook {
    using PoolIdLibrary for PoolKey;
    PoolRegistrationRecorder private immutable registry;
    address private immutable manager;

    constructor(PoolRegistrationRecorder registry_, address manager_) {
        registry = registry_;
        manager = manager_;
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external view returns (bytes4) {
        require(msg.sender == manager, "not PoolManager");
        require(sender == registry.lpManager(), "not LP manager");
        require(registry.registered(PoolId.unwrap(key.toId())), "pool unregistered");
        return IHooks.beforeInitialize.selector;
    }
}

contract TSVPoolInitializationTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    TSVLPManagerV1 private lp;
    IPoolManager private manager;
    PoolRegistrationRecorder private registry;
    PoolKey private key;

    function setUp() public {
        registry = new PoolRegistrationRecorder();
        manager = IPoolManager(address(new PoolManager(address(this))));
        TSVGovernanceAnchor anchor = new TSVGovernanceAnchor(address(this), address(0xBEEF), address(0xCAFE));
        TSVLPManagerV1 implementation = new TSVLPManagerV1(
            manager,
            IAllowanceTransfer(address(0)),
            100_000,
            IPositionDescriptor(address(0)),
            IWETH9(address(0)),
            IPermissionsAdapterFactory(address(0)),
            100_000,
            ITSVPermissionedRegistry(address(registry)),
            new TestTokenApproveProxy()
        );
        lp = TSVLPManagerV1(
            payable(address(
                    new TSVERC1967Proxy(
                        address(implementation),
                        abi.encodeCall(
                            TSVLPManagerV1.initialize, (address(anchor), ITSVPermissionedRegistry(address(registry)))
                        )
                    )
                ))
        );
        registry.configure(address(lp), false);
        lp.grantRole(lp.POOL_CREATOR_ROLE(), address(this));

        RegisteredPoolInitializationHook hook = new RegisteredPoolInitializationHook(registry, address(manager));
        address hookAddress = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG));
        vm.etch(hookAddress, address(hook).code);
        key = PoolKey(Currency.wrap(address(0x10000)), Currency.wrap(address(0x20000)), 3000, 60, IHooks(hookAddress));
    }

    function testRegistersBeforeRealPoolInitializationThroughProxy() public {
        int24 tick = lp.initializePool(key, uint160(1 << 96));
        assertEq(tick, 0);
        assertTrue(registry.registered(PoolId.unwrap(key.toId())));
        (uint160 price, int24 storedTick,,) = manager.getSlot0(key.toId());
        assertEq(price, uint160(1 << 96));
        assertEq(storedTick, tick);
        assertEq(lp.nextTokenId(), 1); // Initializing the pool does not mint a position.
    }

    function testUnauthorizedCallerCannotRegisterOrInitialize() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        lp.initializePool(key, uint160(1 << 96));
        _assertAbsent();
    }

    function testInvalidPriceRevertsAndRollsBackRegistration() public {
        vm.expectRevert();
        lp.initializePool(key, 0);
        _assertAbsent();
    }

    function testRegistryRejectionLeavesPoolUninitialized() public {
        registry.configure(address(lp), true);
        vm.expectRevert(bytes("registration rejected"));
        lp.initializePool(key, uint160(1 << 96));
        _assertAbsent();
    }

    function testDuplicateCreationRevertsAndPreservesExistingPool() public {
        lp.initializePool(key, uint160(1 << 96));
        vm.expectRevert(bytes("already registered"));
        lp.initializePool(key, uint160(2 << 96));
        (uint160 price,,,) = manager.getSlot0(key.toId());
        assertEq(price, uint160(1 << 96));
        assertTrue(registry.registered(PoolId.unwrap(key.toId())));
    }

    function testLaterMulticallFailureRollsBackPoolAndRegistration() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(TSVLPManagerV1.initializePool, (key, uint160(1 << 96)));
        calls[1] = abi.encodeWithSignature("missingFunction()");
        vm.expectRevert();
        lp.multicall(calls);
        _assertAbsent();
    }

    function _assertAbsent() private view {
        assertFalse(registry.registered(PoolId.unwrap(key.toId())));
        (uint160 price,,,) = manager.getSlot0(key.toId());
        assertEq(price, 0);
    }
}

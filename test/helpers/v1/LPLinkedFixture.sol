// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {
    TSVLPManagerV1,
    IPoolManager,
    IAllowanceTransfer,
    IPositionDescriptor,
    IWETH9,
    IPermissionsAdapterFactory,
    IPermissionsAdapter,
    PoolKey,
    Currency,
    IHooks,
    Actions
} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {ITSVPermissionedRegistry} from "tsv-v1/interfaces/ITSVPermissionedRegistry.sol";
import {V1LocalERC20} from "./LocalMocks.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {PositionInfo, PositionInfoLibrary} from "v4-periphery/libraries/PositionInfoLibrary.sol";
import {IUnlockCallback} from "lib/v4-periphery/lib/v4-core/src/interfaces/callback/IUnlockCallback.sol";

contract LPLinkedDependencies {
    address public caller;
    address public payer;
    bool public rejectPermit;
    error PermitRejected();

    function setRejectPermit(bool reject) external {
        rejectPermit = reject;
    }

    function permit(address owner, IAllowanceTransfer.PermitSingle calldata, bytes calldata) external {
        if (rejectPermit) revert PermitRejected();
        caller = msg.sender;
        payer = owner;
    }

    function permit(address owner, IAllowanceTransfer.PermitBatch calldata, bytes calldata) external {
        if (rejectPermit) revert PermitRejected();
        caller = msg.sender;
        payer = owner;
    }
}

/// @dev Models callback/claim accounting only; not a substitute for real-PoolManager integration.
contract LPLinkedPoolManager {
    bool public unlocked;
    mapping(address => bool) public rejected;
    mapping(address => mapping(address => bool)) public rejectedCurrency;
    mapping(address => mapping(uint256 => uint256)) public balanceOf;
    mapping(address => mapping(address => uint256)) public delivered;
    bytes32 private constant IS_UNLOCKED_SLOT = 0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23;

    function setRejected(address recipient, bool value) external {
        rejected[recipient] = value;
    }

    function setRejectedCurrency(address recipient, Currency currency, bool value) external {
        rejectedCurrency[recipient][Currency.unwrap(currency)] = value;
    }

    function seedClaim(address owner, uint256 id, uint256 amount) external {
        balanceOf[owner][id] = amount;
    }

    function extsload(bytes32) external pure returns (bytes32) {
        return bytes32(0);
    }

    function exttload(bytes32 slot) external view returns (bytes32) {
        return slot == IS_UNLOCKED_SLOT ? bytes32(uint256(unlocked ? 1 : 0)) : bytes32(uint256(1));
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        require(!unlocked, "LOCKED");
        unlocked = true;
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        unlocked = false;
    }

    function mint(address to, uint256 id, uint256 amount) external {
        balanceOf[to][id] += amount;
    }

    function burn(address from, uint256 id, uint256 amount) external {
        balanceOf[from][id] -= amount;
    }

    function take(Currency currency, address to, uint256 amount) external {
        require(!rejected[to] && !rejectedCurrency[to][Currency.unwrap(currency)], "REJECTED");
        delivered[to][Currency.unwrap(currency)] += amount;
    }

    function transfer(address to, uint256 id, uint256 amount) external returns (bool) {
        balanceOf[msg.sender][id] -= amount;
        balanceOf[to][id] += amount;
        return true;
    }
}

contract LPLinkedSubscriber {
    address public caller;
    uint256 public subscriptions;
    uint256 public unsubscriptions;
    bool public reattach;
    bool public rejectSubscribe;

    function configure(bool reattach_, bool reject_) external {
        reattach = reattach_;
        rejectSubscribe = reject_;
    }

    function notifySubscribe(uint256, bytes calldata) external {
        require(!rejectSubscribe, "SUBSCRIBE_REJECTED");
        caller = msg.sender;
        ++subscriptions;
    }

    function notifyUnsubscribe(uint256 tokenId) external {
        caller = msg.sender;
        ++unsubscriptions;
        if (reattach) TSVLPManagerV1(payable(msg.sender)).subscribe(tokenId, address(this), "");
    }
}

contract LPLinkedHarness is TSVLPManagerV1 {
    constructor(address manager, address factory, address registry_, address dependencies)
        TSVLPManagerV1(
            IPoolManager(manager),
            IAllowanceTransfer(dependencies),
            200_000,
            IPositionDescriptor(address(0)),
            IWETH9(address(0)),
            IPermissionsAdapterFactory(factory),
            500_000
        )
    {}

    function seed(address owner, PoolKey calldata key) external returns (uint256 tokenId) {
        tokenId = nextTokenId++;
        _mint(owner, tokenId);
        PositionInfo info = PositionInfoLibrary.initialize(key, -60, 60);
        positionInfo[tokenId] = info;
        poolKeys[info.poolId()] = key;
    }

    function payForTest(Currency currency, address payer, uint256 amount) external isNotLocked {
        _pay(currency, payer, amount);
    }

    function sweepForTest(Currency currency, address to) external {
        _sweep(currency, to);
    }
}

abstract contract LPLinkedFixture is Test {
    LPLinkedHarness internal lp;
    LPLinkedPoolManager internal manager;
    LPLinkedDependencies internal deps;
    LPLinkedSubscriber internal sub;
    address internal factory;
    address internal registry;
    address internal owner;
    uint256 internal ownerKey;
    address internal underlying;
    V1LocalERC20 internal underlyingToken;
    V1LocalERC20 internal quoteToken;
    PoolKey internal key;
    uint256 internal tokenId;

    function setUp() public virtual {
        (owner, ownerKey) = makeAddrAndKey("lp-owner");
        factory = makeAddr("factory");
        registry = _createRegistry();
        underlyingToken = new V1LocalERC20("underlying");
        quoteToken = new V1LocalERC20("quote");
        underlying = address(underlyingToken);
        vm.etch(factory, hex"00");
        manager = new LPLinkedPoolManager();
        deps = new LPLinkedDependencies();
        sub = new LPLinkedSubscriber();
        LPLinkedHarness implementation = new LPLinkedHarness(address(manager), factory, registry, address(deps));
        lp = LPLinkedHarness(
            payable(address(
                    new TSVERC1967Proxy(
                        address(implementation),
                        abi.encodeCall(TSVLPManagerV1.initialize, (ITSVPermissionedRegistry(registry)))
                    )
                ))
        );
        key = PoolKey(
            Currency.wrap(address(0x1000)), Currency.wrap(address(quoteToken)), 3000, 60, IHooks(address(0x3000))
        );
        vm.etch(Currency.unwrap(key.currency0), address(underlyingToken).code);
        vm.mockCall(
            factory,
            abi.encodeCall(IPermissionsAdapterFactory.verifiedPermissionsAdapterOf, (Currency.unwrap(key.currency0))),
            abi.encode(underlying)
        );
        vm.mockCall(
            factory,
            abi.encodeCall(IPermissionsAdapterFactory.verifiedPermissionsAdapterOf, (Currency.unwrap(key.currency1))),
            abi.encode(address(0))
        );
        vm.mockCall(
            Currency.unwrap(key.currency0),
            abi.encodeWithSelector(IPermissionsAdapter.owner.selector),
            abi.encode(address(this))
        );
        vm.mockCall(
            Currency.unwrap(key.currency0),
            abi.encodeWithSelector(IPermissionsAdapter.isAllowed.selector),
            abi.encode(true)
        );
        vm.mockCall(
            Currency.unwrap(key.currency0), abi.encodeCall(IPermissionsAdapter.wrapToPoolManager, (uint256(9))), ""
        );
        vm.mockCall(registry, abi.encodeCall(ITSVPermissionedRegistry.isPaused, ()), abi.encode(false));
        vm.mockCall(registry, abi.encodeWithSelector(ITSVPermissionedRegistry.isLPAllowed.selector), abi.encode(true));
        vm.mockCall(registry, abi.encodeWithSelector(ITSVPermissionedRegistry.isSbtAllowed.selector), abi.encode(true));
        vm.mockCall(
            registry,
            abi.encodeWithSelector(ITSVPermissionedRegistry.updatePoolTickCount.selector, key, int256(-1)),
            abi.encode(true)
        );
        tokenId = lp.seed(owner, key);
        _grantForceExitRole();
    }

    function _createRegistry() internal virtual returns (address result) {
        result = makeAddr("registry");
        vm.etch(result, hex"00");
    }

    function _grantForceExitRole() internal virtual {
        vm.mockCall(
            registry,
            abi.encodeCall(ITSVPermissionedRegistry.hasRole, (lp.FORCE_EXIT_ADMIN_ROLE(), address(this))),
            abi.encode(true)
        );
    }
}

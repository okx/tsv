// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC721Permit_v4} from "v4-periphery/interfaces/IERC721Permit_v4.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TestTokenApproveProxy} from "../../../helpers/TokenApproveMocks.sol";
import {
    TSVLPManagerV1,
    IPoolManager,
    IAllowanceTransfer,
    IPositionDescriptor,
    IWETH9,
    IPermissionsAdapterFactory,
    ITSVPermissionedRegistry,
    Currency
} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {ITokenApproveProxy} from "tsv-v1/interfaces/ITokenApproveProxy.sol";
import {PermissionsAdapter} from "tsv-v1/vendor/permissionedPools/PermissionsAdapter.sol";
import {BaseAllowlistChecker} from "tsv-v1/vendor/permissionedPools/BaseAllowListChecker.sol";
import {PermissionFlag, PermissionFlags} from "tsv-v1/vendor/permissionedPools/libraries/PermissionFlags.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";

contract PaymentToken is ERC20 {
    constructor() ERC20("Payment token", "PAY") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PaymentAllowlist is BaseAllowlistChecker {
    mapping(address => bool) public allowed;

    function setAllowed(address who, bool value) external {
        allowed[who] = value;
    }

    function checkAllowlist(address who, address) public view override returns (PermissionFlag) {
        return allowed[who] ? PermissionFlags.LIQUIDITY_ALLOWED : PermissionFlags.NONE;
    }
}

contract PaymentFactory {
    mapping(address => address) public verifiedPermissionsAdapterOf;

    function setAdapter(address adapter, address token) external {
        verifiedPermissionsAdapterOf[adapter] = token;
    }
}

/// @dev Exposes only the production payment helper, under the normal caller/reentrancy context.
contract LPTokenApproveHarness is TSVLPManagerV1 {
    constructor(address manager, address factory, address registry_, ITokenApproveProxy approveProxy)
        TSVLPManagerV1(
            IPoolManager(manager),
            IAllowanceTransfer(address(0)),
            100_000,
            IPositionDescriptor(address(0)),
            IWETH9(address(0)),
            IPermissionsAdapterFactory(factory),
            100_000,
            ITSVPermissionedRegistry(registry_),
            approveProxy
        )
    {}

    function pay(Currency currency, address payer, uint256 amount) external isNotLocked {
        _pay(currency, payer, amount);
    }
}

contract TSVTokenApprovePaymentTest is Test {
    LPTokenApproveHarness private lp;
    TestTokenApproveProxy private approveProxy;
    PaymentToken private underlying;
    PaymentToken private quote;
    PaymentAllowlist private checker;
    PermissionsAdapter private adapter;
    address private constant USER = address(0xA11CE);
    address private constant MANAGER = address(0xBEEF);

    function setUp() public {
        underlying = new PaymentToken();
        quote = new PaymentToken();
        checker = new PaymentAllowlist();
        approveProxy = new TestTokenApproveProxy();
        PaymentFactory factory = new PaymentFactory();
        adapter = new PermissionsAdapter(IERC20(address(underlying)), MANAGER, address(this), checker);
        factory.setAdapter(address(adapter), address(underlying));
        TSVGovernanceAnchor anchor = new TSVGovernanceAnchor(address(this), address(0xCAFE), address(0xD00D));
        LPTokenApproveHarness implementation =
            new LPTokenApproveHarness(MANAGER, address(factory), address(quote), approveProxy);
        lp = LPTokenApproveHarness(
            payable(address(
                    new TSVERC1967Proxy(
                        address(implementation),
                        abi.encodeCall(
                            TSVLPManagerV1.initialize, (address(anchor), ITSVPermissionedRegistry(address(quote)))
                        )
                    )
                ))
        );
        approveProxy.setAllowed(address(lp), true);
        adapter.updateAllowedWrapper(address(lp), true);
        checker.setAllowed(USER, true);
        underlying.mint(USER, 100 ether);
        quote.mint(USER, 100 ether);
        vm.startPrank(USER);
        underlying.approve(approveProxy.tokenApprove(), type(uint256).max);
        quote.approve(approveProxy.tokenApprove(), type(uint256).max);
        vm.stopPrank();
    }

    function testUnderlyingUsesSharedApprovalAndWrapsAtAdapter() public {
        vm.prank(USER);
        lp.pay(Currency.wrap(address(adapter)), USER, 7 ether);
        assertEq(underlying.balanceOf(USER), 93 ether);
        assertEq(underlying.balanceOf(address(adapter)), 7 ether);
        assertEq(adapter.balanceOf(MANAGER), 7 ether);
        assertEq(underlying.allowance(USER, address(lp)), 0);
        assertEq(underlying.allowance(USER, address(approveProxy)), 0);
        assertEq(underlying.balanceOf(address(lp)), 0);
        assertEq(address(lp.TOKEN_APPROVE_PROXY()), address(approveProxy));
    }

    function testQuoteUsesSameTokenApproveWithoutPermit2() public {
        vm.prank(USER);
        lp.pay(Currency.wrap(address(quote)), USER, 9 ether);
        assertEq(quote.balanceOf(USER), 91 ether);
        assertEq(quote.balanceOf(MANAGER), 9 ether);
        assertEq(quote.allowance(USER, address(lp)), 0);
    }

    function testRevokedLPProxyCannotPullUserFunds() public {
        approveProxy.setAllowed(address(lp), false);
        vm.prank(USER);
        vm.expectRevert(bytes("ApproveProxy: Access restricted"));
        lp.pay(Currency.wrap(address(adapter)), USER, 7 ether);
        assertEq(underlying.balanceOf(USER), 100 ether);
        assertEq(adapter.totalSupply(), 0);
    }

    function testLPApprovalAloneCannotReplaceTokenApproveApproval() public {
        vm.startPrank(USER);
        underlying.approve(approveProxy.tokenApprove(), 0);
        underlying.approve(address(lp), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, approveProxy.tokenApprove(), 0, 7 ether
            )
        );
        lp.pay(Currency.wrap(address(adapter)), USER, 7 ether);
        vm.stopPrank();
        assertEq(underlying.balanceOf(USER), 100 ether);
        assertEq(adapter.totalSupply(), 0);
    }

    function testLiquidityPermissionStillRequired() public {
        checker.setAllowed(USER, false);
        vm.prank(USER);
        vm.expectRevert(IERC721Permit_v4.Unauthorized.selector);
        lp.pay(Currency.wrap(address(adapter)), USER, 7 ether);
        assertEq(underlying.balanceOf(USER), 100 ether);
        assertEq(adapter.totalSupply(), 0);
    }

    function testLPHeldUnderlyingDoesNotRequireSharedApproval() public {
        underlying.mint(address(lp), 7 ether);
        approveProxy.setAllowed(address(lp), false);
        vm.prank(USER);
        lp.pay(Currency.wrap(address(adapter)), address(lp), 7 ether);
        assertEq(underlying.balanceOf(USER), 100 ether);
        assertEq(underlying.balanceOf(address(lp)), 0);
        assertEq(adapter.balanceOf(MANAGER), 7 ether);
    }

    function testLPHeldQuoteDoesNotRequireSharedApproval() public {
        quote.mint(address(lp), 9 ether);
        approveProxy.setAllowed(address(lp), false);
        vm.prank(USER);
        lp.pay(Currency.wrap(address(quote)), address(lp), 9 ether);
        assertEq(quote.balanceOf(USER), 100 ether);
        assertEq(quote.balanceOf(MANAGER), 9 ether);
    }

    function testPaymentAmountIsNotTruncatedToUint160() public {
        uint256 amount = uint256(type(uint160).max) + 1;
        underlying.mint(USER, amount);
        vm.prank(USER);
        lp.pay(Currency.wrap(address(adapter)), USER, amount);
        assertEq(underlying.balanceOf(address(adapter)), amount);
        assertEq(adapter.balanceOf(MANAGER), amount);
    }
}

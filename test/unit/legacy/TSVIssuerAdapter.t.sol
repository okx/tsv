// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {V1MockIssuerShares, V1MockIssuerWrapped} from "../../helpers/v1/MockIssuerTokens.sol";
import {IssuerShareSettlementAdapter, IActiveAssetOperation} from "tsv-v1/legacy/IssuerShareSettlementAdapter.sol";

contract TSVIssuerAdapterTest is Test, IActiveAssetOperation {
    bytes32 private constant OP = keccak256("operation");
    bytes32 private constant POOL = keccak256("pool");
    V1MockIssuerShares internal underlying;
    V1MockIssuerWrapped internal wrapped;
    IssuerShareSettlementAdapter internal adapter;
    address internal alice;
    bool internal forced;

    function setUp() public {
        alice = makeAddr("alice");
        underlying = new V1MockIssuerShares();
        wrapped = new V1MockIssuerWrapped(underlying);
        adapter = new IssuerShareSettlementAdapter(address(underlying), address(wrapped), address(this), address(this));
        underlying.mintShares(alice, 10e18);
        underlying.setMultiplier(0.9e18, 7);
        vm.prank(alice);
        underlying.approve(address(adapter), type(uint256).max);
    }

    function activeAssetOperation(bytes32 operationId, address currency)
        external
        view
        returns (bytes32 poolId, address owner, address recipient, bool forceExit)
    {
        if (operationId != OP || currency != address(wrapped)) return (0, address(0), address(0), false);
        return (POOL, alice, alice, forced);
    }

    function testWrapThenRedeemExactSharesAndDisplayBounds() public {
        uint256 ownerSharesBefore = underlying.sharesOf(alice);
        uint256 ownerDisplayedBefore = underlying.balanceOf(alice);
        assertEq(adapter.pullAndWrap(alice, address(this), 3e18, 2.7e18, OP), 3e18);
        assertEq(ownerSharesBefore - underlying.sharesOf(alice), 3e18);
        assertEq(ownerDisplayedBefore - underlying.balanceOf(alice), 2.7e18);
        assertEq(underlying.sharesOf(address(wrapped)), 3e18);
        assertEq(wrapped.balanceOf(address(this)), 3e18);

        adapter.prepareReceive(3e18, OP);
        wrapped.transfer(address(adapter), 3e18);
        assertEq(adapter.redeemAndDeliver(alice, 3e18, 2.7e18, OP), 3e18);
        assertEq(underlying.sharesOf(alice), ownerSharesBefore);
        assertEq(underlying.sharesOf(address(wrapped)), 0);
        assertEq(wrapped.totalSupply(), 0);
    }

    function testDisplayedDebitLimitRevertsWithoutMovingShares() public {
        uint256 beforeShares = underlying.sharesOf(alice);
        vm.expectRevert(IssuerShareSettlementAdapter.SlippageExceeded.selector);
        adapter.pullAndWrap(alice, address(this), 3e18, 2.6e18, OP);
        assertEq(underlying.sharesOf(alice), beforeShares);
        assertEq(wrapped.totalSupply(), 0);
    }

    function testForcedDeliveryRefusalRollsBackWholeOperation() public {
        adapter.pullAndWrap(alice, address(this), 3e18, 2.7e18, OP);
        forced = true;
        underlying.setBlocked(alice, true);
        uint256 beforeWrapped = wrapped.balanceOf(address(this));
        uint256 beforeOwnerShares = underlying.sharesOf(alice);
        vm.expectRevert();
        this.redeemAtomically(3e18);
        assertEq(wrapped.balanceOf(address(this)), beforeWrapped);
        assertEq(wrapped.balanceOf(address(adapter)), 0);
        assertEq(underlying.sharesOf(alice), beforeOwnerShares);
        assertEq(underlying.sharesOf(address(wrapped)), 3e18);
    }

    function redeemAtomically(uint256 shares) external {
        adapter.prepareReceive(shares, OP);
        wrapped.transfer(address(adapter), shares);
        adapter.redeemAndDeliver(alice, shares, 0, OP);
    }
}

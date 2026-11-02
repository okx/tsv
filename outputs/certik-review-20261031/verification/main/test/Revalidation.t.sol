// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test, StdStorage, stdStorage} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {ERC8056DirectLegalShareAdapter} from "tsv-v1/adapters/ERC8056DirectLegalShareAdapter.sol";
import {PermissionedValidationLib} from "tsv-v1/libraries/PermissionedValidationLib.sol";
import {PermissionFlag} from "tsv-v1/vendor/permissionedPools/libraries/PermissionFlags.sol";
import {PermissionsAdapter} from "tsv-v1/vendor/permissionedPools/PermissionsAdapter.sol";
import {IERC20 as VendorIERC20} from "tsv-v1/vendor/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {IAllowlistChecker} from "tsv-v1/vendor/permissionedPools/interfaces/IAllowlistChecker.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {SwapRequest} from "tsv-v1/types/TSVTypes.sol";
contract PlainToken is ERC20 { constructor() ERC20("Plain", "PLN") {} function mint(address a,uint256 n) external {_mint(a,n);} }
contract Empty {}
contract Checker { function supportsInterface(bytes4 x) external pure returns(bool) {return x != 0xffffffff;} }
contract Identity { function verify(address,uint256) external pure returns(bool) {return true;} }
contract RevalidationTest is Test {
 using stdStorage for StdStorage;
 bool constant MAIN = true;
 TSVRegistryV1 r;
 function setUp() public {
  r=TSVRegistryV1(address(new ERC1967Proxy(address(new TSVRegistryV1()),abi.encodeCall(TSVRegistryV1.initialize,(address(this))))));
  stdstore.target(address(r)).sig("participantSbt()").checked_write(address(new Identity()));
 }
 function test_OTA03_BoundedActiveSetAndRemoval() public {
  for(uint256 i=1;i<=32;i++) r.setSbtConfig(i,PermissionFlag.wrap(0x0001),bytes32("TEST"));
  vm.expectRevert(TSVRegistryV1.SbtIdentityLimitReached.selector);
  r.setSbtConfig(33,PermissionFlag.wrap(0x0001),bytes32("TEST"));
  r.setSbtConfig(1,PermissionFlag.wrap(0),bytes32("TEST"));
  r.setSbtConfig(33,PermissionFlag.wrap(0x0001),bytes32("TEST"));
  uint256[] memory ids=r.sbtTokenIds(); assertEq(ids.length,32);
  for(uint256 i;i<ids.length;i++) assertTrue(ids[i]!=1);
 }
 function test_OTA02_ReservedMaskStillStored() public {
  r.setSbtConfig(9,PermissionFlag.wrap(0xffff),bytes32("TEST"));
  (,PermissionFlag mask)=r.sbtIdentityConfig(9); assertEq(PermissionFlag.unwrap(mask),bytes2(0xffff));
 }
 function test_OTA01_AdmissionValidatorAcceptsNonFunctionalMultiplier() public {
  PlainToken t=new PlainToken();
  ERC8056DirectLegalShareAdapter a=new ERC8056DirectLegalShareAdapter(address(t));
  PermissionedValidationLib.validateLegalShareAdapter(address(a),address(t));
  vm.expectRevert(); a.currentMultiplier(address(t));
 }
 function test_OTA04_AnotherAllowedWrapperConsumesUnattributedDeposit() public {
  PlainToken t=new PlainToken(); address pm=address(new Empty());
  PermissionsAdapter w=new PermissionsAdapter(VendorIERC20(address(t)),pm,address(this),IAllowlistChecker(address(new Checker())));
  address depositor=address(0xD00); address otherAllowed=address(0xAD);
  w.updateAllowedWrapper(otherAllowed,true);
  t.mint(depositor,100);
  vm.startPrank(depositor); t.approve(address(w),100); w.depositForVerification(100); vm.stopPrank();
  vm.prank(otherAllowed); w.wrapToPoolManager(100);
  assertEq(w.balanceOf(pm),100); assertEq(t.balanceOf(address(w))-w.totalSupply(),0);
 }
 function test_OTA08_DisabledQuoteDirectPathComparison() public {
  address pm=address(new Empty()); address factory=address(new Empty()); address reg=address(new Empty());
  vm.mockCall(factory,abi.encodeWithSignature("POOL_MANAGER()"),abi.encode(pm));
  TSVSwapRouterV1 router=TSVSwapRouterV1(address(new ERC1967Proxy(address(new TSVSwapRouterV1(pm,factory)),abi.encodeCall(TSVSwapRouterV1.initialize,(pm,reg)))));
  vm.mockCall(reg,abi.encodeWithSignature("isPaused()"),abi.encode(false));
  vm.mockCall(reg,abi.encodeWithSignature("hasRole(bytes32,address)"),abi.encode(true));
  router.setAdapterAllowed(address(this),true);
  address w=address(0x100); address q=address(0x200); address hook=address(0x300);
  vm.mockCall(reg,abi.encodeWithSignature("getCurrencyUnderlying(address)",w),abi.encode(address(0x400)));
  vm.mockCall(reg,abi.encodeWithSignature("getCurrencyUnderlying(address)",q),abi.encode(address(0)));
  vm.mockCall(reg,abi.encodeWithSignature("getQuoteToken(address)",q),abi.encode(uint8(6),false));
  vm.mockCall(reg,abi.encodeWithSignature("hook()"),abi.encode(hook));
  bytes memory sentinel=abi.encodeWithSignature("ReachedPoolTradabilityCheck()");
  vm.mockCallRevert(reg,abi.encodeWithSignature("isTradable(bytes32)"),sentinel);
  SwapRequest memory req=SwapRequest(PoolKey(Currency.wrap(w),Currency.wrap(q),3000,60,IHooks(hook)),true,1,1,uint64(block.timestamp+1),1e18);
  if(MAIN) vm.expectRevert(TSVSwapRouterV1.InvalidRequest.selector); else vm.expectRevert(sentinel);
  router.swapExactInputFromContractDirect(req,address(0),address(0x500),address(0x500));
 }
}

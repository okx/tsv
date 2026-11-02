// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {TSVHookProxyMcpBootstrap} from "../src/TSVHookProxyMcpBootstrap.sol";
interface IHookView { function registry() external view returns(address);function poolManager() external view returns(address);function ledger() external view returns(address);function router() external view returns(address);function lpManager() external view returns(address); }
interface IRegistryView {function hasRole(bytes32,address) external view returns(bool);function hook() external view returns(address);}
contract BootstrapForkTest is Test {
 function testActualProductionFactoryAndDependencies() public {
  address factory=address(bytes20(hex"ed28206bf9a16e4dc64b893563a48a1bb1e34c60"));address implementation=address(bytes20(hex"6422ef382cfe42b200aec323236c005c604550f7"));address expected=address(bytes20(hex"F151416e74d6B4Ae00197e8D8E4f4765283B3fff"));
  bytes memory initData=hex"1459457a000000000000000000000000360e68faccca8ca495c1b759fd9eee466db9fb320000000000000000000000005bd7ea82642b49ebdfc3fbc0e656941c165392ea0000000000000000000000009b43d49b1a6d41aa22ac788442eb5cb5bbc543c5000000000000000000000000c58d2bf7ad7cb023760e767e9050be3f15cad6860000000000000000000000009418a8ccb8170814d27c7f3db99e1b9f8c4a7b76";
  TSVHookProxyMcpBootstrap bootstrap=new TSVHookProxyMcpBootstrap(factory,implementation,initData,0x000000000000000000000000000000000000000000000000f332010000000000,expected);
  assertEq(bootstrap.factory(),factory);assertEq(bootstrap.hookProxy(),expected);
  assertGt(expected.code.length,0);assertEq(uint160(expected)&0x3fff,0x3fff);
  assertEq(address(uint160(uint256(vm.load(expected,bytes32(uint256(keccak256("eip1967.proxy.implementation"))-1))))),implementation);
  IHookView hook=IHookView(expected);
  assertEq(hook.registry(),address(bytes20(hex"5bd7ea82642b49ebdfc3fbc0e656941c165392ea")));assertEq(hook.poolManager(),address(bytes20(hex"360e68faccca8ca495c1b759fd9eee466db9fb32")));assertEq(hook.ledger(),address(bytes20(hex"9b43d49b1a6d41aa22ac788442eb5cb5bbc543c5")));assertEq(hook.router(),address(bytes20(hex"c58d2bf7ad7cb023760e767e9050be3f15cad686")));assertEq(hook.lpManager(),address(bytes20(hex"9418a8ccb8170814d27c7f3db99e1b9f8c4a7b76")));
  IRegistryView registry=IRegistryView(address(bytes20(hex"5bd7ea82642b49ebdfc3fbc0e656941c165392ea")));
  assertFalse(registry.hasRole(bytes32(0),address(bootstrap)));
  assertFalse(registry.hasRole(keccak256("UPGRADE_ADMIN_ROLE"),address(bootstrap)));
  assertTrue(registry.hasRole(bytes32(0),address(bytes20(hex"ace2b3e7c752d5debca72210141d464371b3b9b1"))));assertTrue(registry.hasRole(keccak256("UPGRADE_ADMIN_ROLE"),address(bytes20(hex"ace2b3e7c752d5debca72210141d464371b3b9b1"))));
  assertEq(registry.hook(),address(0));
  (bool reinitialized,)=expected.call(initData);assertFalse(reinitialized);
  vm.expectRevert(TSVHookProxyMcpBootstrap.InvalidDeploymentInputs.selector);
  new TSVHookProxyMcpBootstrap(factory,implementation,initData,0x000000000000000000000000000000000000000000000000f332010000000000,expected);
 }
 function testInvalidFactoryRevertsBeforeDeployment() public {
  vm.expectRevert(TSVHookProxyMcpBootstrap.InvalidDeploymentInputs.selector);
  new TSVHookProxyMcpBootstrap(address(0),address(bytes20(hex"6422ef382cfe42b200aec323236c005c604550f7")),hex"1459457a000000000000000000000000360e68faccca8ca495c1b759fd9eee466db9fb320000000000000000000000005bd7ea82642b49ebdfc3fbc0e656941c165392ea0000000000000000000000009b43d49b1a6d41aa22ac788442eb5cb5bbc543c5000000000000000000000000c58d2bf7ad7cb023760e767e9050be3f15cad6860000000000000000000000009418a8ccb8170814d27c7f3db99e1b9f8c4a7b76",0x000000000000000000000000000000000000000000000000f332010000000000,address(bytes20(hex"F151416e74d6B4Ae00197e8D8E4f4765283B3fff")));
  assertEq(address(bytes20(hex"F151416e74d6B4Ae00197e8D8E4f4765283B3fff")).code.length,0);
 }
}

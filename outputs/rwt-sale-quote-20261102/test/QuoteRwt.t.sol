// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
struct Key {address currency0;address currency1;uint24 fee;int24 tickSpacing;address hooks;}
struct Request {Key key;bool zeroForOne;uint128 amountSpecified;uint128 limitAmount;uint64 deadline;uint256 expectedMultiplier;}
interface Token {function approve(address,uint256) external returns(bool);function balanceOf(address) external view returns(uint256);}
interface Adapter {function currentMultiplier(address) external view returns(uint256);}
interface Router {function swapExactInput(Request calldata) external returns(uint256,uint256);}
interface Registry {function isPaused() external view returns(bool);function getSecurityPauseMode(bytes32) external view returns(uint8);}
interface Ledger {function Quota(bytes32) external view returns(uint256);function currentESTDay() external view returns(uint256);function usedWad(bytes32,uint256) external view returns(uint256);}
contract QuoteRwtTest is Test {
 address constant OWNER=0xC2ceBE8485f666874667e500B36028AB2A297f8F;
 address constant REG=0x2233EA2044FFA04CccEeEf0b9AdFe0799505a908;
 address constant ROUTER=0xe5Df3Ab010BB20094f490DFCf61b6E2D9a3311C8;
 address constant LEDGER=0x4FBFfBE7cA5ce0fc3AF30C9F305E0F6365ff3bC2;
 address constant U=0x28Ccb07e804c6541634C07f1809f7Eaae3B523B0;
 address constant ADAPTER=0x1501e20d4990f4A33f3807a9482AF910bDcD3F68;
 bytes32 constant SECURITY=0xe29c89c6170c14d1aec33ef8c32df8beb88a6ff3e6e3c30a8bcb27e4321773e3;
 function testQuote() public {
  vm.createSelectFork("https://rpc.xlayer.tech",74848469);
  uint256 amount=Token(U).balanceOf(OWNER);uint256 multiplier=Adapter(ADAPTER).currentMultiplier(U);
  console2.log("RWT amount raw",amount);console2.log("multiplier",multiplier);
  console2.log("global paused",Registry(REG).isPaused());console2.log("security pause",Registry(REG).getSecurityPauseMode(SECURITY));
  console2.log("quota",Ledger(LEDGER).Quota(SECURITY));console2.log("used",Ledger(LEDGER).usedWad(SECURITY,Ledger(LEDGER).currentESTDay()));
  vm.prank(OWNER);require(Token(U).approve(ROUTER,amount));
  string memory rows="[";
 rows=string.concat(rows,"",quote(Key(address(bytes20(hex"b6ceceab302e2e4948951ee7843fc24e92933061")),address(bytes20(hex"f6bb667b55d0cacdb9d2bb9d75d78b4ebe1f1b6c")),2000,40,address(bytes20(hex"bc6d8c8a8b681872a93554116f01268f80c9ffff"))),amount,multiplier));
rows=string.concat(rows,",",quote(Key(address(bytes20(hex"b6ceceab302e2e4948951ee7843fc24e92933061")),address(bytes20(hex"f6bb667b55d0cacdb9d2bb9d75d78b4ebe1f1b6c")),2000,60,address(bytes20(hex"bc6d8c8a8b681872a93554116f01268f80c9ffff"))),amount,multiplier));
rows=string.concat(rows,",",quote(Key(address(bytes20(hex"b6ceceab302e2e4948951ee7843fc24e92933061")),address(bytes20(hex"f6bb667b55d0cacdb9d2bb9d75d78b4ebe1f1b6c")),2000,20,address(bytes20(hex"bc6d8c8a8b681872a93554116f01268f80c9ffff"))),amount,multiplier));
  rows=string.concat(rows,"]");
  vm.writeFile("quote-results.json",string.concat('{"block":',vm.toString(uint256(74848469)),',"rwtBalanceRaw":"',vm.toString(amount),'","assumption":"price-only: mock only registry isTradable on local fork; real ledger accounting and quota; no mainnet writes","pools":',rows,'}'));
 }
 function quote(Key memory key,uint256 amount,uint256 multiplier) internal returns(string memory) {
  bytes32 pid=keccak256(abi.encode(key));uint256 snap=vm.snapshotState();
  Request memory req=Request(key,false,uint128(amount),1,uint64(block.timestamp+3600),multiplier);
  vm.prank(OWNER);(bool baseline,bytes memory base)=ROUTER.call(abi.encodeCall(Router.swapExactInput,(req)));
  require(vm.revertToState(snap));snap=vm.snapshotState();
  // Only the trade-admission result is mocked; the real quota and ledger checks remain active.
  vm.mockCall(REG,abi.encodeWithSignature("isTradable(bytes32)",pid),abi.encode(true));
  uint256 beforeQ=Token(key.currency0).balanceOf(OWNER);vm.prank(OWNER);
  (bool ok,bytes memory result)=ROUTER.call(abi.encodeCall(Router.swapExactInput,(req)));
  uint256 actualIn;uint256 actualOut;
  if(ok){(actualIn,actualOut)=abi.decode(result,(uint256,uint256));assertEq(actualIn,amount);assertEq(Token(key.currency0).balanceOf(OWNER)-beforeQ,actualOut);}
  console2.logBytes32(pid);console2.log("conditional quote succeeded",ok);console2.log("quote raw",actualOut);
  string memory row=string.concat('{"poolId":"',vm.toString(pid),'","baselineSucceeded":',baseline?'true':'false',',"baselineReturn":"',vm.toString(base),'","conditionalSucceeded":',ok?'true':'false',',"conditionalReturn":"',vm.toString(result),'","actualInRaw":"',vm.toString(actualIn),'","amountOutRaw":"',vm.toString(actualOut),'"}');
  require(vm.revertToState(snap));vm.clearMockedCalls();return row;
 }
}

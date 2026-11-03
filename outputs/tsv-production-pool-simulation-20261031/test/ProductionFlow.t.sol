// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";

struct Key { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }
struct Registration { address currency; bytes32 securityId; address legalShareAdapter; }
struct Swap { Key key; bool zeroForOne; uint128 amountSpecified; uint128 limitAmount; uint64 deadline; uint256 expectedMultiplier; }
interface Token { function balanceOf(address) external view returns(uint256); function approve(address,uint256) external returns(bool); }
interface DSTokenServices { function getDSService(uint256) external view returns(address); }
interface RebasingProvider { function convertTokensToShares(uint256) external view returns(uint256); }
interface IssuerRegistry {
    function registerInvestor(string calldata,string calldata) external returns(bool);
    function addWallet(address,string calldata) external returns(bool);
}
interface IssuerWallets { function addPlatformWallet(address) external returns(bool); function isPlatformWallet(address) external view returns(bool); }
interface StockIssuer { function issueTokens(address,uint256) external returns(bool); }
interface Registry {
    function grantRole(bytes32,address) external;
    function registerPermissionedCurrency(Registration calldata,uint8,bytes32) external;
    function isKnownPool(bytes32) external view returns(bool);
    function isTradable(bytes32) external view returns(bool);
    function sbtTokenIds() external view returns(uint256[] memory);
    function isSbtAllowed(bytes2,address) external view returns(bool);
    function participantSbt() external view returns(address);
}
interface Wrapped {
    function owner() external view returns(address);
    function allowListChecker() external view returns(address);
    function depositForVerification(uint256) external;
    function updateSwappingEnabled(bool) external;
}
interface Factory { function verifyPermissionsAdapter(address) external; }
interface Ledger {
    function setQuota(bytes32,uint256,bytes32) external;
    function Quota(bytes32) external view returns(uint256);
    function currentESTDay() external view returns(uint256);
    function usedWad(bytes32,uint256) external view returns(uint256);
}
interface LP {
    function initializePool(Key calldata,uint160) external payable returns(int24);
    function modifyLiquidities(bytes calldata,uint256) external payable;
    function nextTokenId() external view returns(uint256);
    function ownerOf(uint256) external view returns(address);
    function getPositionLiquidity(uint256) external view returns(uint128);
}
interface Router { function swapExactInput(Swap calldata) external returns(uint256,uint256); }

contract ProductionFlowTest is Test {
    using stdStorage for StdStorage;
    StdStorage private shareStorage;
    address constant REG = 0x5bd7EA82642B49EbDfC3FBc0E656941c165392eA;
    address constant LEDGER = 0x9b43D49B1a6D41Aa22ac788442eB5CB5bBc543c5;
    address constant ROUTER = 0xC58D2BF7Ad7cb023760E767E9050bE3F15cad686;
    address constant LPM = 0x9418a8Ccb8170814D27C7f3dB99e1b9F8C4a7B76;
    address constant HOOK = 0xF151416e74d6B4Ae00197e8D8E4f4765283B3fff;
    address constant FACTORY = 0x4c750656FcA58dA2A2E0402bd1Ab0b39D134BDbA;
    address constant ADMIN = 0xAcE2B3E7c752d5deBca72210141d464371b3B9b1;
    address constant ACTOR = 0x31846cfea0c2b5EEA300Bc8C4AF50ed563a9f042;
    address constant U = 0xf83D29cA0F926CEf42597ac57e807ad452Ce5B43;
    address constant W = 0xE1218F57c5FE7d11088Ac4682781906f3C4b0BFF;
    address constant Q = 0xB6CEceAB302E2E4948951eE7843FC24E92933061;
    address constant ADAPTER = 0xb7e043949745296276480AC907819443Bb3a1521;
    bytes32 constant SECURITY = keccak256("FORK_ONLY_MSTR_20261031");
    uint160 constant PRICE = uint160(uint256(1 << 96) / 10);
    Key key;
    string report;

    function setUp() public {
        vm.createSelectFork("https://rpc.xlayer.tech",74651998);
        key=Key(Q,W,3000,60,HOOK);
        assertEq(block.chainid,196);
    }
    function _save(string memory filename,string memory stage,bool ok,bytes memory result) internal {
        console2.log(stage,ok);console2.logBytes(result);
        vm.serializeBool(filename,stage,ok);
        report=vm.serializeBytes(filename,string.concat(stage,"_result"),result);
        vm.writeJson(report,string.concat(vm.projectRoot(),"/",filename,".json"));
    }
    function _invoke(string memory filename,string memory stage,address from,address to,bytes memory input) internal returns(bool ok,bytes memory result) {
        vm.prank(from);(ok,result)=to.call(input);_save(filename,stage,ok,result);
    }
    function _poolId() internal view returns(bytes32) {return keccak256(abi.encode(key));}
    function _fundStock(address account,uint256 rawAmount) internal {
        // DS balanceOf converts internal 18-decimal shares to 6-decimal tokens.
        // Use the real conversion provider; ordinary ERC20 deal writes wrong units.
        address provider=DSTokenServices(U).getDSService(8196);
        uint256 shares=RebasingProvider(provider).convertTokensToShares(rawAmount);
        uint256 slot=shareStorage.target(U).sig(Token.balanceOf.selector).with_key(account).find();
        vm.store(U,bytes32(slot),bytes32(shares));
        assertEq(Token(U).balanceOf(account),rawAmount);
    }
    function _mintData() internal view returns(bytes memory) {
        bytes[] memory params=new bytes[](2);
        params[0]=abi.encode(key,int24(-887220),int24(887220),uint256(9_900_000),uint128(100_000_000),uint128(1_000_000),ACTOR,bytes(""));
        params[1]=abi.encode(Q,W);
        return abi.encodeWithSelector(LP.modifyLiquidities.selector,abi.encode(hex"020d",params),block.timestamp+1 hours);
    }
    function _swapData(bool buy,uint128 amount) internal view returns(bytes memory) {
        return abi.encodeWithSelector(Router.swapExactInput.selector,Swap(key,buy,amount,1,uint64(block.timestamp+1 hours),1e18));
    }
    function testCurrentProductionStateAllThreeOperations() public {
        string memory file="baseline";
        (bool opened,)=_invoke(file,"initializePool",ADMIN,LPM,abi.encodeWithSelector(LP.initializePool.selector,key,PRICE));
        assertFalse(opened,"Unexpectedly already admitted");
        (bool minted,)=_invoke(file,"mintLP",ACTOR,LPM,_mintData());assertFalse(minted);
        (bool swapped,)=_invoke(file,"swap",ACTOR,ROUTER,_swapData(true,1_000_000));assertFalse(swapped);
    }
    function _configure(string memory file,bool assumeIdentity,bool issuerPrepared) internal returns(bool) {
        // Synthetic funding is fork-local. No production storage or balances change.
        if(!issuerPrepared)_fundStock(ACTOR,2_000_000);
        deal(Q,ACTOR,200_000_000);
        vm.prank(ACTOR);Token(U).approve(W,1);
        (bool deposit,)=_invoke(file,"realUnderlyingVerificationDeposit",ACTOR,W,abi.encodeWithSelector(Wrapped.depositForVerification.selector,1));
        if(!deposit) {
            // Continue admission using a clearly recorded, synthetic one-unit W seed.
            // All later underlying token transfers still use the real production code.
            _fundStock(W,1);
            vm.serializeBool(file,"syntheticVerificationSeed",true);
        }
        (bool verified,)=_invoke(file,"factoryVerify",ACTOR,FACTORY,abi.encodeWithSelector(Factory.verifyPermissionsAdapter.selector,W));
        if(!verified)return false;
        (bool registered,)=_invoke(file,"registerMSTR",ADMIN,REG,abi.encodeWithSelector(Registry.registerPermissionedCurrency.selector,Registration(W,SECURITY,ADAPTER),uint8(1),bytes32("FORK_REGISTER_MSTR")));
        if(!registered)return false;
        address owner=Wrapped(W).owner();
        (bool enabled,)=_invoke(file,"enableWSwap",owner,W,abi.encodeWithSelector(Wrapped.updateSwappingEnabled.selector,true));
        if(!enabled)return false;
        vm.prank(ADMIN);Registry(REG).grantRole(keccak256("VOLUME_ORACLE_ROLE"),ADMIN);
        vm.prank(ADMIN);Ledger(LEDGER).setQuota(SECURITY,1000e18,bytes32("FORK_QUOTA"));
        if(assumeIdentity) {
            // Conditional run only: external identity/issuer responses are assumptions,
            // explicitly distinguished from the unchanged-production readiness test.
            uint256[] memory ids=Registry(REG).sbtTokenIds();require(ids.length>0);
            vm.mockCall(Registry(REG).participantSbt(),abi.encodeWithSignature("verify(address,uint256)",ACTOR,ids[0]),abi.encode(true));
            if(!issuerPrepared)vm.mockCall(Wrapped(W).allowListChecker(),abi.encodeWithSignature("checkAllowlist(address,address)",ACTOR,U),abi.encode(bytes2(0x0003)));
            vm.serializeBool(file,"assumedSbtIdentity",true);
            vm.serializeBool(file,"assumedIssuerEligibility",!issuerPrepared);
        }
        vm.serializeBool(file,"registryLpIdentity",Registry(REG).isSbtAllowed(0x0002,ACTOR));
        vm.serializeBool(file,"registrySwapIdentity",Registry(REG).isSbtAllowed(0x0001,ACTOR));
        (bool opened,)=_invoke(file,"initializePool",ADMIN,LPM,abi.encodeWithSelector(LP.initializePool.selector,key,PRICE));
        if(!opened)return false;
        assertTrue(Registry(REG).isKnownPool(_poolId()));assertTrue(Registry(REG).isTradable(_poolId()));
        vm.startPrank(ACTOR);Token(U).approve(LPM,1_000_000);Token(Q).approve(LPM,100_000_000);vm.stopPrank();
        uint256 next=LP(LPM).nextTokenId();
        uint256 beforeU=Token(U).balanceOf(ACTOR);uint256 beforeQ=Token(Q).balanceOf(ACTOR);
        (bool minted,)=_invoke(file,"mintLP",ACTOR,LPM,_mintData());
        if(!minted) {
            _invoke(file,"swapAfterFailedLP",ACTOR,ROUTER,_swapData(true,1_000_000));
            return false;
        }
        assertEq(LP(LPM).ownerOf(next),ACTOR);assertEq(LP(LPM).getPositionLiquidity(next),9_900_000);
        vm.serializeUint(file,"positionTokenId",next);
        vm.serializeUint(file,"LPStockRaw",beforeU-Token(U).balanceOf(ACTOR));
        vm.serializeUint(file,"LPQuoteRaw",beforeQ-Token(Q).balanceOf(ACTOR));
        vm.startPrank(ACTOR);Token(Q).approve(ROUTER,1_000_000);Token(U).approve(ROUTER,5_000);vm.stopPrank();
        uint256 day=Ledger(LEDGER).currentESTDay();
        uint256 usedBefore=Ledger(LEDGER).usedWad(SECURITY,day);
        uint256 uBeforeBuy=Token(U).balanceOf(ACTOR);uint256 qBeforeBuy=Token(Q).balanceOf(ACTOR);
        (bool bought,bytes memory buyResult)=_invoke(file,"buyMSTR",ACTOR,ROUTER,_swapData(true,1_000_000));
        if(!bought)return false;
        (uint256 buyIn,uint256 buyOut)=abi.decode(buyResult,(uint256,uint256));assertEq(buyIn,1_000_000);assertGt(buyOut,0);
        assertEq(Token(U).balanceOf(ACTOR)-uBeforeBuy,buyOut);
        assertEq(qBeforeBuy-Token(Q).balanceOf(ACTOR),buyIn);
        vm.serializeUint(file,"buyStockBalanceIncreaseRaw",buyOut);
        vm.serializeUint(file,"buyQuoteBalanceDecreaseRaw",buyIn);
        uint256 usedAfterBuy=Ledger(LEDGER).usedWad(SECURITY,day);
        assertEq(usedAfterBuy-usedBefore,buyOut*1e12);
        uint256 uBeforeSell=Token(U).balanceOf(ACTOR);uint256 qBeforeSell=Token(Q).balanceOf(ACTOR);
        (bool sold,bytes memory sellResult)=_invoke(file,"sellMSTR",ACTOR,ROUTER,_swapData(false,5_000));
        if(!sold)return false;
        (uint256 sellIn,uint256 sellOut)=abi.decode(sellResult,(uint256,uint256));assertEq(sellIn,5_000);assertGt(sellOut,0);
        assertEq(uBeforeSell-Token(U).balanceOf(ACTOR),sellIn);
        assertEq(Token(Q).balanceOf(ACTOR)-qBeforeSell,sellOut);
        vm.serializeUint(file,"sellStockBalanceDecreaseRaw",sellIn);
        vm.serializeUint(file,"sellQuoteBalanceIncreaseRaw",sellOut);
        uint256 usedAfterSell=Ledger(LEDGER).usedWad(SECURITY,day);assertEq(usedAfterSell-usedAfterBuy,sellIn*1e12);
        vm.serializeUint(file,"usedWadAfterBuy",usedAfterBuy);vm.serializeUint(file,"usedWadAfterSell",usedAfterSell);
        _save(file,"allStagesPassed",true,bytes(""));return true;
    }
    function testForkConfigurationWithRealExternalEligibility() public {_configure("configured-real-identities",false,false);}
    function testConditionalForkFlowWithExternalIdentityAssumptions() public {_configure("conditional-identities",true,false);}
    function _issuerCall(string memory file,address master,address target,bytes memory input) internal {
        vm.prank(master);(bool ok,bytes memory reason)=target.call(input);
        if(!ok && reason.length==68 && bytes4(reason)==bytes4(0xe2517d3f)) {
            bytes32 role;
            assembly("memory-safe") {role:=mload(add(reason,68))}
            // The global issuer Registry has separate AccessControl from token TrustService.
            // Assume that administrative permission only on the fork, record the exact role,
            // then execute the genuine issuer Registry method and all its normal effects.
            shareStorage.target(target).sig("hasRole(bytes32,address)").with_key(role).with_key(master).checked_write(true);
            vm.serializeBool(file,"assumedIssuerGlobalRegistryAuthority",true);
            vm.serializeBytes32(file,"assumedIssuerGlobalRegistryRole",role);
            vm.prank(master);(ok,reason)=target.call(input);
        }
        if(!ok) {console2.logBytes(reason);revert("Issuer preparation failed");}
    }
    function testIssuerPreparedAndSbtAssumptionFullFlow() public {
        string memory file="issuer-prepared-flow";
        address master=address(uint160(uint256(vm.load(DSTokenServices(U).getDSService(1),bytes32(0)))));
        vm.serializeAddress(file,"issuerMasterImpersonatedOnlyOnFork",master);
        address investorRegistry=DSTokenServices(U).getDSService(4);
        address walletManager=DSTokenServices(U).getDSService(32);
        _issuerCall(file,master,investorRegistry,abi.encodeWithSelector(IssuerRegistry.registerInvestor.selector,"FORK_ONLY_TSV_SIMULATION",""));
        _issuerCall(file,master,investorRegistry,abi.encodeWithSelector(IssuerRegistry.addWallet.selector,ACTOR,"FORK_ONLY_TSV_SIMULATION"));
        vm.startPrank(master);
        if(!IssuerWallets(walletManager).isPlatformWallet(W))IssuerWallets(walletManager).addPlatformWallet(W);
        assertTrue(StockIssuer(U).issueTokens(ACTOR,2_000_000));
        vm.stopPrank();
        assertEq(Token(U).balanceOf(ACTOR),2_000_000);
        vm.serializeBool(file,"realIssuerRegistrationAndMintOnFork",true);
        bool complete=_configure(file,true,true);
        assertTrue(complete,"Full flow failed; inspect issuer-prepared-flow.json");
    }
}

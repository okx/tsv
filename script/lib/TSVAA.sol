// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

// ABI follows okx-smart-wallet-dev, chore/scripts (ERC-4337 v0.7).
struct AAOwner {
    bytes32 keyHash;
    address validator;
}

struct AACall {
    address target;
    uint256 value;
    bytes data;
}

struct AAUserOp {
    address sender;
    uint256 nonce;
    bytes initCode;
    bytes callData;
    bytes32 accountGasLimits;
    uint256 preVerificationGas;
    bytes32 gasFees;
    bytes paymasterAndData;
    bytes signature;
}

interface IAAFactory {
    function IMPLEMENTATION() external view returns (address);
    function getAddress(AAOwner[] calldata owners, uint256 salt) external view returns (address);
    function createAccount(AAOwner[] calldata owners, uint256 salt) external payable returns (address);
}

interface IAAWallet {
    function IMPLEMENTATION() external view returns (address);
    function entryPoint() external view returns (address);
    function getOwnerConfig(bytes32 keyHash) external view returns (address, uint256);
    function isSettingsExpired(uint256 settings) external view returns (bool);
    function executeUserOp(AAUserOp calldata userOp, bytes32 hash) external;
}

interface IAAEntryPoint {
    function getNonce(address sender, uint192 key) external view returns (uint256);
    function getUserOpHash(AAUserOp calldata op) external view returns (bytes32);
    function balanceOf(address account) external view returns (uint256);
    function depositTo(address account) external payable;
    function handleOps(AAUserOp[] calldata ops, address payable beneficiary) external;
}

abstract contract TSVAA is Script {
    address internal constant ENTRY_POINT = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    bytes32 private constant USER_OP_EVENT =
        keccak256("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)");

    function _checkWallet(address wallet, address signer) internal view returns (address implementation) {
        require(wallet.code.length != 0, "AA wallet not deployed");
        require(IAAWallet(wallet).entryPoint() == ENTRY_POINT, "wrong AA EntryPoint");
        implementation = IAAWallet(wallet).IMPLEMENTATION();
        require(implementation.code.length != 0, "AA implementation missing");
        (address validator, uint256 settings) = IAAWallet(wallet).getOwnerConfig(keccak256(abi.encodePacked(signer)));
        require(validator == address(1), "signer not ECDSA owner");
        require(!IAAWallet(wallet).isSettingsExpired(settings), "AA owner expired");
    }

    function _submitAA(address wallet, AACall[] memory calls, uint256 privateKey) internal {
        address signer = vm.addr(privateKey);
        address implementation = _checkWallet(wallet, signer);
        IAAEntryPoint ep = IAAEntryPoint(ENTRY_POINT);
        uint256 configuredFee = vm.envOr("AA_MAX_FEE_PER_GAS", block.basefee * 2 + 1);
        uint256 configuredPriority = vm.envOr("AA_PRIORITY_FEE", uint256(1));
        require(configuredFee <= type(uint128).max && configuredPriority <= type(uint128).max, "AA fee overflow");
        uint128 fee = uint128(configuredFee);
        uint128 priority = uint128(configuredPriority);
        require(fee >= priority && fee >= block.basefee, "invalid AA fees");
        uint128 verificationGas = 2_000_000;
        uint128 callGas = 2_000_000;
        uint256 preVerificationGas = 100_000;
        uint48 validUntil = uint48(block.timestamp + 1 hours);
        AAUserOp memory op = AAUserOp({
            sender: wallet,
            nonce: ep.getNonce(wallet, 0), // chain-bound key, never chainless namespace 196
            initCode: bytes(""),
            callData: abi.encodePacked(IAAWallet.executeUserOp.selector, abi.encode(calls)),
            accountGasLimits: bytes32((uint256(verificationGas) << 128) | uint256(callGas)),
            preVerificationGas: preVerificationGas,
            gasFees: bytes32((uint256(priority) << 128) | uint256(fee)),
            paymasterAndData: bytes(""),
            signature: bytes("")
        });
        bytes32 rawHash = ep.getUserOpHash(op);
        bytes32 digest =
            MessageHashUtils.toEthSignedMessageHash(keccak256(abi.encode(rawHash, validUntil, implementation)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        op.signature = abi.encodePacked(keccak256(abi.encodePacked(signer)), validUntil, r, s, v);
        uint256 prefund = (uint256(verificationGas) + callGas + preVerificationGas) * fee;
        uint256 deposit = ep.balanceOf(wallet);
        if (deposit < prefund) ep.depositTo{value: prefund - deposit}(wallet);
        AAUserOp[] memory ops = new AAUserOp[](1);
        ops[0] = op;
        vm.recordLogs();
        ep.handleOps(ops, payable(signer));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == ENTRY_POINT && logs[i].topics.length == 4 && logs[i].topics[0] == USER_OP_EVENT
                    && logs[i].topics[1] == rawHash && address(uint160(uint256(logs[i].topics[2]))) == wallet
            ) {
                (, bool success,,) = abi.decode(logs[i].data, (uint256, bool, uint256, uint256));
                require(success, "AA execution failed");
                return;
            }
        }
        revert("missing UserOperationEvent");
    }
}

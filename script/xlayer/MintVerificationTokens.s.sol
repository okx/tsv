// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

interface IRWATVerificationToken {
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
    function issueTokens(address to, uint256 amount) external returns (bool);
}

/// @notice Tops up the operator's configured tokens to their verification amounts.
/// @dev Does not modify any token service, role, lock, or transfer permission.
contract MintVerificationTokens is Script {
    function run() external {
        require(block.chainid == 196, "wrong chain");
        uint256 key = vm.envUint("XLAYER_PRIVATE_KEY");
        address operator = vm.addr(key);
        uint256 count = vm.envUint("TSV_MINT_COUNT");
        require(count > 0 && count <= 50, "invalid count");
        address[] memory tokens = new address[](count);
        uint256[] memory targets = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            string memory suffix = vm.toString(i);
            tokens[i] = vm.envAddress(string.concat("TSV_MINT_TOKEN_", suffix));
            targets[i] = vm.envUint(string.concat("TSV_MINT_TARGET_", suffix));
            require(tokens[i].code.length > 0 && targets[i] > 0, "invalid token or amount");
            require(IRWATVerificationToken(tokens[i]).decimals() == 18, "unexpected decimals");
            for (uint256 j; j < i; ++j) {
                require(tokens[j] != tokens[i], "duplicate token");
            }
        }
        console2.log("Operator:", operator);
        vm.startBroadcast(key);
        for (uint256 i; i < count; ++i) {
            IRWATVerificationToken token = IRWATVerificationToken(tokens[i]);
            uint256 current = token.balanceOf(operator);
            if (current >= targets[i]) continue;
            console2.log("Mint token:", tokens[i]);
            console2.log("Mint raw shortfall:", targets[i] - current);
            require(token.issueTokens(operator, targets[i] - current), "mint returned false");
            require(token.balanceOf(operator) >= targets[i], "mint balance mismatch");
        }
        vm.stopBroadcast();
    }
}

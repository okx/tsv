# TSV Relayer 角色授权：Forge 命令与校验

整理日期：2026-10-20。依据当前工作区 Solidity 源码及 `script/xlayer/deployment.json`。

四项授权统一调用 **TSVRegistryV1 代理** 的 `grantRole(bytes32,address)`。Ledger、LP Manager 在执行业务时查询 Registry 的角色状态。授权账户需要持有目标角色的管理角色；当前源码中这三个角色的管理角色均为 `DEFAULT_ADMIN_ROLE`，值为 `bytes32(0)`。

本文提供 Forge 模拟、广播、回读命令及可选的逐笔 cast 命令。仅生成文档及脚本；未发送链上交易，未读取目标链当前授权状态。部署地址取自本地部署记录，不代表已核验为本次业务环境。

## 1. 授权清单

| Relayer 地址 | 授权角色 | 当前交易用途 | 业务调用目标 |
| --- | --- | --- | --- |
| `0xc7228a9ce9c36f035bad7e4e417a3974901249c9` | `HALT_REPORTER_ROLE` | 按证券暂停或恢复交易、LP 操作：applySecurityStatus | TSVRegistryV1 |
| `0x60d0ce25e0930958b869a0b126f3d9a456559b5b` | `VOLUME_ORACLE_ROLE` | setQuota、setUsedWad，以及 Ledger 自带 multicall 的组合调用 | TSVVolumeLedgerV1 |
| `0xde739bd7e3281c167fab53d00f17b36aafc599dc` | `HALT_REPORTER_ROLE` | 按证券暂停或恢复交易、LP 操作：applySecurityStatus | TSVRegistryV1 |
| `0x726880a6f4604ff4271740dc5cba73a91280800e` | `FORCE_EXIT_ADMIN_ROLE` | unwindPositionByTsv | TSVLPManagerV1 |

两个 HALT Relayer 各自拥有独立调用权限，不要求双方同时批准。这些角色没有按 securityId、池子或 tokenId 限定授权范围；表格中的用途不是链上权限的额外限制。业务函数自身的状态、参数等校验仍然生效。

角色值为 `keccak256` 对角色名称字符串计算所得：

```text
HALT_REPORTER_ROLE
0x3bb4716226a17af20de9bb8fb0b4eac6d19604f20e50522e7012bc46a752cd48
VOLUME_ORACLE_ROLE
0x2d97f6a70b8b79080c0d186cf732f0382b6349ae993b9ce160f265f74e801516
FORCE_EXIT_ADMIN_ROLE
0xfb184699a3b1eacde7d2a547a592194816605090c2320ec2ceb56b0a38a34bee
DEFAULT_ADMIN_ROLE
0x0000000000000000000000000000000000000000000000000000000000000000
```

## 2. 配置执行环境

在 TSV 仓库根目录执行。以下示例采用仓库记录的 X Layer Mainnet（chainId=196）。如目标为其他部署，替换 RPC、chainId 和三个代理地址。`ADMIN_ACCOUNT` 替换为已经配置好的 Foundry keystore 账户名称，命令交互式请求解锁密码。签名账户必须是 Registry 的角色管理员，不能使用待授权的 Relayer 代替管理员。

```bash
export RPC_URL='https://rpc.xlayer.tech'
export EXPECTED_CHAIN_ID='196'
export TSV_REGISTRY='0x2233ea2044ffa04ccceeef0b9adfe0799505a908'
export TSV_LEDGER='0x4fbffbe7ca5ce0fc3af30c9f305e0f6365ff3bc2'
export TSV_LP_MANAGER='0xf73d8683b948564d2795c62a2a909012ea168d29'
export ADMIN_ACCOUNT='替换为管理员keystore名称'
export TSV_ROLE_ADMIN="$(cast wallet address --account "$ADMIN_ACCOUNT")"
```

此方式适用于管理员是可由 Foundry 签名的 EOA。若管理角色由 Safe 等合约钱包持有，不能用其某个 owner EOA 直接执行以下广播命令；应由该合约钱包提交相同的四项 grantRole 调用。

## 3. Forge 脚本与执行命令

脚本保存于 `script/xlayer/GrantRelayerRoles.s.sol`。文末包含完整源码，便于其他工作区复制使用。

脚本在记录交易前检查 chainId、Registry 合约代码、Ledger/LP Manager 的 Registry 绑定，以及管理员对四项授权的管理权限。已有角色会跳过。检查管理权限时使用链上的 `getRoleAdmin`，不硬编码其返回值。

### 3.1 编译与模拟，不发送交易

```bash
forge build script/xlayer/GrantRelayerRoles.s.sol

forge script script/xlayer/GrantRelayerRoles.s.sol:GrantRelayerRoles \
  --rpc-url "$RPC_URL" \
  --sender "$TSV_ROLE_ADMIN" \
  -vvvv
```

模拟使用指定管理员地址作为发送者，不需要签名；模拟通过不代表操作者拥有该地址的签名能力，也不代表角色已经写入链上。

### 3.2 正式广播

核对模拟输出中的 chainId、Registry、Admin 和四个 Relayer 后执行：

```bash
forge script script/xlayer/GrantRelayerRoles.s.sol:GrantRelayerRoles \
  --rpc-url "$RPC_URL" \
  --sender "$TSV_ROLE_ADMIN" \
  --account "$ADMIN_ACCOUNT" \
  --broadcast \
  --slow \
  -vvvv
```

最多发送四笔独立的 grantRole 交易，`--slow` 等待上一笔成功后再发送下一笔；这不是一笔原子批量交易。中途失败时，已成功的授权仍然有效。先检查回执和角色状态，再重新模拟、执行；脚本会跳过链上已存在的授权。如果存在尚未确认的交易，先处理其状态，避免重复提交。

## 4. 授权后链上回读

广播完成后执行以下命令，四项 `hasRole` 均应返回 `true`：

```bash
export HALT_ROLE="$(cast keccak 'HALT_REPORTER_ROLE')"
export VOLUME_ROLE="$(cast keccak 'VOLUME_ORACLE_ROLE')"
export FORCE_EXIT_ROLE="$(cast keccak 'FORCE_EXIT_ADMIN_ROLE')"

cast call "$TSV_REGISTRY" 'hasRole(bytes32,address)(bool)' \
  "$HALT_ROLE" 0xc7228a9ce9c36f035bad7e4e417a3974901249c9 --rpc-url "$RPC_URL"
cast call "$TSV_REGISTRY" 'hasRole(bytes32,address)(bool)' \
  "$VOLUME_ROLE" 0x60d0ce25e0930958b869a0b126f3d9a456559b5b --rpc-url "$RPC_URL"
cast call "$TSV_REGISTRY" 'hasRole(bytes32,address)(bool)' \
  "$HALT_ROLE" 0xde739bd7e3281c167fab53d00f17b36aafc599dc --rpc-url "$RPC_URL"
cast call "$TSV_REGISTRY" 'hasRole(bytes32,address)(bool)' \
  "$FORCE_EXIT_ROLE" 0x726880a6f4604ff4271740dc5cba73a91280800e --rpc-url "$RPC_URL"
```

对实际提交的每笔交易核对 receipt.status=1。新增授权应在 Registry 代理地址发出 `RoleGranted(bytes32 indexed role,address indexed account,address indexed sender)`；role 对应角色哈希，account 对应 Relayer，sender 对应执行授权的管理员。已有授权被跳过时没有新交易和新 RoleGranted。

## 5. 可选：Foundry cast 逐笔授权

Forge 用于运行 Solidity 脚本，Foundry 的 cast 用于直接调用合约。以下四条命令与 Forge 脚本中的授权效果相同，选择一种执行方式即可。执行前先完成上面的配置、Forge 模拟，并设置第 4 节中的三个角色变量。

```bash
# 1. HALT Reporter A
cast send "$TSV_REGISTRY" 'grantRole(bytes32,address)' \
  "$HALT_ROLE" 0xc7228a9ce9c36f035bad7e4e417a3974901249c9 \
  --rpc-url "$RPC_URL" --account "$ADMIN_ACCOUNT"

# 2. Volume Oracle
cast send "$TSV_REGISTRY" 'grantRole(bytes32,address)' \
  "$VOLUME_ROLE" 0x60d0ce25e0930958b869a0b126f3d9a456559b5b \
  --rpc-url "$RPC_URL" --account "$ADMIN_ACCOUNT"

# 3. HALT Reporter B
cast send "$TSV_REGISTRY" 'grantRole(bytes32,address)' \
  "$HALT_ROLE" 0xde739bd7e3281c167fab53d00f17b36aafc599dc \
  --rpc-url "$RPC_URL" --account "$ADMIN_ACCOUNT"

# 4. Force Exit Admin
cast send "$TSV_REGISTRY" 'grantRole(bytes32,address)' \
  "$FORCE_EXIT_ROLE" 0x726880a6f4604ff4271740dc5cba73a91280800e \
  --rpc-url "$RPC_URL" --account "$ADMIN_ACCOUNT"
```

`grantRole(bytes32,address)` 的 calldata selector 是 `0x2f2ff15d`。如需交给合约钱包提案系统，使用 `cast calldata 'grantRole(bytes32,address)' "$HALT_ROLE" 0xc7228a9ce9c36f035bad7e4e417a3974901249c9` 生成单项 calldata，交易 to 为 Registry 代理，value 为 0；其他三项替换 role 和 account。

## 6. multicall 与业务调用的权限边界

`TSVVolumeLedgerV1` 继承 OpenZeppelin `Multicall`。Relayer 直接调用 Ledger 代理的 `multicall(bytes[])`，其中组合 setQuota、setUsedWad 时，内部通过 self-delegatecall 保留原始 msg.sender；给上述 Relayer 授予 VOLUME_ORACLE_ROLE 即可通过这两个函数的角色检查，无需额外 multicall 角色。子调用任一失败会回滚整个 multicall。

如果业务侧改为调用外部 Multicall 合约，再由其普通 CALL 到 Ledger，Ledger 看到的 msg.sender 将是外部合约地址。此时仅给 Relayer 授权不够，需要按实际执行路径设计权限，不能把两种 multicall 混同。

当前业务入口：

- Registry：`applySecurityStatus(bytes32 securityId, SecurityPauseMode mode, bool enable, bytes32 reasonCode)`，HALT_REPORTER_ROLE；同一角色可以暂停和恢复，管理的是按证券暂停状态。
- Ledger：`setQuota(bytes32 securityId, uint256 amount, bytes32 reasonCode)`，VOLUME_ORACLE_ROLE。
- Ledger：`setUsedWad(bytes32 securityId, DailyQuota[] values, bytes32 reasonCode)`，VOLUME_ORACLE_ROLE；DailyQuota 为 `(uint256 ESTDay,uint256 amount)`。
- LP Manager：`unwindPositionByTsv(uint256 tokenId, uint128 amount0Min, uint128 amount1Min, bytes hookData)`，FORCE_EXIT_ADMIN_ROLE；角色检查通过后仍须满足该入口的其他业务条件。

## 7. 完整 Forge 脚本

将下面内容保存为仓库内 `script/xlayer/GrantRelayerRoles.s.sol`，依赖仓库已有的 forge-std 配置。

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

interface IRelayerRoleRegistry {
    function getRoleAdmin(bytes32 role) external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function grantRole(bytes32 role, address account) external;
}

interface IRelayerRegistryBound {
    function registry() external view returns (address);
}

/// @notice Grants the four requested relayer assignments on the Registry proxy.
/// @dev Simulates by default. Use --sender plus --account and --broadcast to send.
contract GrantRelayerRoles is Script {
    function run() external {
        require(block.chainid == vm.envUint("EXPECTED_CHAIN_ID"), "wrong chain");
        address admin = vm.envAddress("TSV_ROLE_ADMIN");
        address registryAddress = vm.envAddress("TSV_REGISTRY");
        require(admin != address(0), "zero admin");
        require(registryAddress.code.length != 0, "Registry has no code");
        require(
            IRelayerRegistryBound(vm.envAddress("TSV_LEDGER")).registry() == registryAddress,
            "Ledger Registry mismatch"
        );
        require(
            IRelayerRegistryBound(vm.envAddress("TSV_LP_MANAGER")).registry() == registryAddress,
            "LP Manager Registry mismatch"
        );
        IRelayerRoleRegistry registry = IRelayerRoleRegistry(registryAddress);
        bytes32[4] memory roles = [
            keccak256("HALT_REPORTER_ROLE"),
            keccak256("VOLUME_ORACLE_ROLE"),
            keccak256("HALT_REPORTER_ROLE"),
            keccak256("FORCE_EXIT_ADMIN_ROLE")
        ];
        address[4] memory accounts = [
            vm.parseAddress("0xc7228a9ce9c36f035bad7e4e417a3974901249c9"),
            vm.parseAddress("0x60d0ce25e0930958b869a0b126f3d9a456559b5b"),
            vm.parseAddress("0xde739bd7e3281c167fab53d00f17b36aafc599dc"),
            vm.parseAddress("0x726880a6f4604ff4271740dc5cba73a91280800e")
        ];

        // Validate all four assignments before recording any transaction.
        for (uint256 i; i < roles.length; ++i) {
            require(registry.hasRole(registry.getRoleAdmin(roles[i]), admin), "sender lacks role admin");
        }
        console2.log("Chain ID:", block.chainid);
        console2.log("Registry:", registryAddress);
        console2.log("Admin:", admin);
        vm.startBroadcast(admin);
        for (uint256 i; i < roles.length; ++i) {
            if (registry.hasRole(roles[i], accounts[i])) {
                console2.log("Already granted; skipping:", accounts[i]);
            } else {
                console2.log("Granting to:", accounts[i]);
                console2.logBytes32(roles[i]);
                registry.grantRole(roles[i], accounts[i]);
            }
        }
        vm.stopBroadcast();
        for (uint256 i; i < roles.length; ++i) {
            require(registry.hasRole(roles[i], accounts[i]), "role readback failed");
        }
    }
}
```

## 8. 来源与验证范围

- `src/v1/governance/TSVGoverned.sol`：角色常量和初始化管理员。
- `src/v1/core/TSVRegistryV1.sol`：applySecurityStatus 的 HALT_REPORTER_ROLE 检查。
- `src/v1/core/TSVVolumeLedgerV1.sol`：Registry 权限查询、setQuota、setUsedWad 和 Multicall 继承。
- `src/v1/periphery/TSVLPManagerV1.sol`、`src/v1/libraries/TSVLPManagerLib.sol`：unwindPositionByTsv 与 Registry 权限查询。
- `dependencies/@openzeppelin-contracts-upgradeable-5.5.0/access/AccessControlUpgradeable.sol`：grantRole、getRoleAdmin、hasRole。
- `dependencies/@openzeppelin-contracts-5.5.0/utils/Multicall.sol`：self-delegatecall 行为。
- `script/xlayer/deployment.json`：2026-10-14 部署记录中的网络和代理地址。

本次验证：本地计算三个角色哈希及 grantRole selector；核对源码授权路径；编译授权脚本。未做目标链 fork 模拟、未核验当前管理员与现有角色、未执行链上授权。执行者需在目标 RPC 上运行第 3、4 节的模拟和回读。

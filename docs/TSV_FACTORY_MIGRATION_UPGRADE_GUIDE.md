# TSV Factory 替换与五个代理合约升级指南

> 历史方案与源码快照，不能直接视为当前版本可执行的升级手册。本文引用的 `script/finalize-factory-migration.py` 和 `test/integration/local/deployment/FactoryMigration.t.sol` 未随当前仓库提供；下方相应命令和内嵌源码仅保留为历史记录。生产迁移前需要针对目标版本重新验证。

本方案用于：保留 Registry、Router、LP Manager、Hook、Ledger 的代理地址和已有资产、池、LP NFT，将三个组件使用的 PermissionsAdapterFactory 同步替换，并升级五个组件的实现。

**不能把原有 `upgrade-all` 命令中的 Factory 地址换掉后直接执行。** 当前 Router 的旧实现会拒绝 Factory 不同的新实现；Registry 的 `bindComponents()` 不能重绑；新部署的普通 Factory 不认识旧 Adapter。

本指南配套代码已经落地。默认先模拟，只有显式带 `--broadcast` 的指定阶段才发送交易。本次交付没有执行链上升级。

## 1. 文件和适用范围

| 文件 | 用途 |
| --- | --- |
| [`UpgradePermissionsFactory.s.sol`](../script/UpgradePermissionsFactory.s.sol) | Forge 入口：读取部署快照、完整演练、部署准备合约、授权、原子升级、回读、撤销授权 |
| [`TSVFactoryMigration.sol`](../script/lib/TSVFactoryMigration.sol) | 兼容 Factory、Registry 迁移实现、Router 过渡实现、一次性升级协调合约 |
| `finalize-factory-migration.py`（当前未提供） | 历史方案中的回执校验及部署清单更新工具 |
| `FactoryMigration.t.sol`（当前未提供） | 历史方案中的迁移及交易／LP 回归测试 |

本方案新增 Factory 使用当前仓库的 `PermissionsAdapter` 实现。它不会修改已经部署的 Adapter，也不会升级 DSToken、SBT、PoolManager、Legal-share Adapter 或外部 DexRouter／TSVAdapter。如果你的目标还包括修改 Adapter 的包装／解包逻辑，需要另行实现并验证，不能仅替换 Factory 地址。

脚本假定：旧代理支持 `tsvImplementation()`，当前链上实现与本仓库的代理存储布局兼容，旧 Factory 遵循当前接口且保持可读。链上快照和代码哈希只能锁定目标，不能证明已部署版本与本地源码布局一致。部署前必须使用原部署版本的构建产物核对存储布局，尤其是 LP Manager 的 ERC721、nonce、positionInfo 等继承存储，以及 Registry 已有 SBT 迁移状态。

## 2. 升级后的依赖

```text
Registry proxy ──────────────┐
Router proxy ────────────────┼─> 新兼容 Factory ──旧 Adapter 查询──> 旧 Factory
LP Manager proxy ────────────┘           └───────新 Adapter 查询──> 新 Factory 本地记录

Hook proxy / Ledger proxy：升级实现，保留原来的组件地址和业务状态。
PoolManager / 旧 Adapter / U、Q 代币 / LP NFT 所属代理：不迁移。
```

旧 Adapter 不需要再次 `verify`，也不需要重新配置原代理地址的 `allowedWrappers`。新 Adapter 仍需按正常流程完成发行方准入、余额验证、Hook／Wrapper 配置和 Registry 注册。

兼容 Factory 的旧记录来自**实时查询**，不是一次性复制：旧 Factory 后续创建或验证的 Adapter 也能被查询到，但接入 TSV 仍需 Registry 的治理注册。不要销毁、停用或改变旧 Factory 的查询语义。新创建的 Adapter 不会反向登记到旧 Factory，因此完成迁移并启用新 Adapter 后，不能简单回退三个组件到旧 Factory。

## 3. 为什么需要 Router 过渡实现

旧 Router 执行升级授权时要求新实现的 PoolManager 和 Factory 均不变。升级协调合约会在**同一笔 `execute()` 交易**内依次执行：

1. Registry 升级到 `TSVRegistryFactoryMigration`，通过 `upgradeToAndCall` 将 Factory 改为固定的新地址。
2. Router 升级到 `TSVRouterFactoryBridge`：该实现仍暴露旧 Factory，满足旧实现的检查。
3. 调用过渡实现的 `completeFactoryMigration()`，只允许切换到部署时固定的新 Router 实现；校验升级角色、Registry、新 Factory、目标代码哈希和锁状态。
4. LP Manager 升级到使用新 Factory 的实现；其余 immutable 参数从旧代理读取并逐项比较。
5. Ledger、Hook 升级，均不重复调用 `initialize()`。
6. 校验五个实现地址和组件绑定；协调合约主动撤销自己的 `UPGRADE_ADMIN_ROLE`。

其中任何一步失败，**这一笔交易中的所有升级、Registry 修改和角色撤销都回滚**。准备阶段部署的合约及之前单独授予的升级角色不会随之回滚。

Registry 迁移实现和 Router 过渡实现只新增 immutable 参数，没有新增代理存储变量。Registry 使用固定旧／新地址实现单向迁移，没有占用可能已被 SBT 迁移使用的 `reinitializer(2)`。完成后的标准 Router 恢复原来的依赖一致性检查，不能随意换 Factory。

**本专用 Factory 迁移脚本仍要求 Registry 未暂停。** 普通 Registry、Hook、Router、LP Manager 和 Ledger 的授权 UUPS 升级已允许在全局暂停时执行，并保留暂停状态；但本方案的迁移方法和协调器另有显式的未暂停前置条件，脚本仍会拒绝全局暂停的 Registry。本方案通过原子切换避免跨交易的混合依赖状态；如使用此脚本并需要维护窗口，可先停止前端、撮合或后台入口。普通暂停升级能力不等于此专用脚本已支持暂停迁移。

## 4. 权限和接口

| 入口 | 调用权限／条件 | 返回和状态变化 |
| --- | --- | --- |
| `snapshot()` | 只读 RPC；预期 chainId、Registry 地址 | 仅写本地快照；无交易 |
| `rehearse()` | 提供公开的 operator 地址；模拟其权限 | 在 fork 上演练整个流程；没有 broadcast 调用 |
| `prepare()` | `PK` 对应 operator；operator 当前有 Registry `DEFAULT_ADMIN_ROLE` | 部署新 Factory、五个实现、Router 过渡实现及协调合约；不升级代理 |
| `authorize()` | Registry `DEFAULT_ADMIN_ROLE` | 授予协调合约 `UPGRADE_ADMIN_ROLE`；重复授权会拒绝 |
| `execute()` | 固定 operator；协调合约已有升级角色；计划未过期 | 单笔交易完成五个代理升级；成功后撤销协调合约角色 |
| `verifyPrepared()` | 无权限要求 | 校验准备状态，任何不符均 revert |
| `verifyCompleted()` | 无权限要求 | 校验升级后状态和权限清理，任何不符均 revert |
| `cancelAuthorization()` | Registry `DEFAULT_ADMIN_ROLE`；尚未执行成功 | 撤销协调合约的升级角色；不回滚成功迁移 |

协调合约不需要 `DEFAULT_ADMIN_ROLE`。它没有通用 `call` 接口，目标、代码哈希、operator 和有效期部署后不可修改。脚本的 `prepare()` 默认使用同一个 EOA 部署并执行；如果治理账户是多签，不要把多签地址当作 EOA 私钥，应另行通过多签提交准备好的固定 calldata。

## 5. 环境准备和目标选择

从 TSV 仓库根目录执行。使用本机已安装的 Forge/Cast 和仓库指定的 Solidity 0.8.26、Cancun、via-IR 配置。

```bash
forge --version
cast --version
mkdir -p dployment/history

export TSV_UPGRADE_SCRIPT='script/UpgradePermissionsFactory.s.sol:UpgradePermissionsFactory'

# 读取当前交互操作器配置中的公开 RPC 和 Registry 地址。
# 执行前核对输出的地址是否就是本次目标，不要混用不同部署的清单。
export RPC_URL="$(python3 -c 'import json; print(json.load(open("script/xlayer/deployment.json"))["rpcUrl"])')"
export TSV_UPGRADE_REGISTRY="$(python3 -c 'import json; print(json.load(open("script/xlayer/deployment.json"))["environment"]["TSV_REGISTRY"])')"
export TSV_UPGRADE_CHAIN_ID="$(python3 -c 'import json; print(json.load(open("script/xlayer/deployment.json"))["chainId"])')"

printf 'Registry: %s\nChain: %s\n' "$TSV_UPGRADE_REGISTRY" "$TSV_UPGRADE_CHAIN_ID"
cast chain-id --rpc-url "$RPC_URL"

# 输入有 DEFAULT_ADMIN_ROLE 的执行账户公开地址。
export TSV_UPGRADE_OPERATOR='替换为本次升级执行账户地址'

# 显式设置本次计划的有效期：此例为当前时间后 24 小时。
export TSV_UPGRADE_DEADLINE="$(python3 -c 'import time; print(int(time.time()) + 86400)')"
export TSV_UPGRADE_MANIFEST='dployment/factory-migration-source.json'
export TSV_UPGRADE_PLAN='dployment/factory-migration-plan.json'
```

`RPC_URL` 可以由你覆盖为有权限且可正常 fork 的节点地址。密钥只通过进程环境变量传入，不放进源码、Markdown、部署 JSON 或命令参数。

当前操作器配置引用的 `dployment/XLAYER_MAINNET_EXTERNAL_20261014.json` 在本次工作区中不存在，因此下面提供 `snapshot()` 从指定链读取真实代理和实现地址。不要为了继续执行而猜测实现地址，也不要把另一个部署的 SMOKE 清单当作替代。

已有完整、正确、`deploymentStatus=confirmed` 的部署清单时，可以将 `TSV_UPGRADE_MANIFEST` 指向它并跳过 snapshot。至少需要以下字段；地址必须来自目标部署：

```json
{
  "chainId": 196,
  "deploymentStatus": "confirmed",
  "proxies": {"registry": "<address>", "ledger": "<address>", "router": "<address>", "lpManager": "<address>", "hook": "<address>"},
  "implementations": {"registry": "<address>", "ledger": "<address>", "router": "<address>", "lpManager": "<address>", "hook": "<address>"},
  "factories": {"permissionedAdapter": "<old factory address>"},
  "dependencies": {"poolManager": "<address>"}
}
```

快照生成命令不需要 PK，且拒绝覆盖已有文件：

```bash
forge script "$TSV_UPGRADE_SCRIPT" --sig 'snapshot()' \
  --rpc-url "$RPC_URL" --no-metadata
```

快照的 `confirmed` 表示“地址和实现从链上读取”，不等于“部署源码兼容性已审查”。快照仅含迁移所需字段，不是包含资产／SBT／AA 配置的完整业务清单。

## 6. 本地检查和完整 fork 演练

本次工作区还有未纳入此次升级的 DSToken 0.8.22 源码以及接口不一致的交易脚本。下面限定编译入口，避免这些无关源码阻断迁移测试，不修改项目全局编译配置。

```bash
forge build script/UpgradePermissionsFactory.s.sol --offline

FOUNDRY_TEST=test/integration/local/deployment FOUNDRY_SCRIPT=script/lib \
forge test --contracts src/v1/core \
  --match-path test/integration/local/deployment/FactoryMigration.t.sol --offline -vv

python3 -m unittest discover -s test/tools -p test_factory_migration_finalize.py -v

# 仅使用 operator 的公开地址模拟，不需要 PK。
forge script "$TSV_UPGRADE_SCRIPT" --sig 'rehearse()' \
  --rpc-url "$RPC_URL" --no-metadata
```

`rehearse()` 故意不调用 `startBroadcast`，不会生成可广播的交易。它验证完整部署和原子迁移，但不自动枚举所有历史资产和仓位。正式执行前还应针对实际持仓做 fork 验证：旧池 LP mint/increase/decrease/burn、双向 swap、issuer／TSV 两种 unwind，以及新 Factory Adapter 的 Registry 准入。

存储布局比较应使用**旧部署版本产物**，不仅是同一工作区的新旧类名。可在对应版本的隔离 checkout 中导出；保持其原始编译设置和依赖锁定：

```bash
# 在原部署版本 checkout 中导出五个组件的 storageLayout。
forge inspect src/v1/core/TSVRegistryV1.sol:TSVRegistryV1 storageLayout --json
forge inspect src/v1/core/TSVVolumeLedgerV1.sol:TSVVolumeLedgerV1 storageLayout --json
forge inspect src/v1/periphery/TSVSwapRouterV1.sol:TSVSwapRouterV1 storageLayout --json
forge inspect src/v1/periphery/TSVLPManagerV1.sol:TSVLPManagerV1 storageLayout --json
forge inspect src/v1/core/TSVHookV1.sol:TSVHookV1 storageLayout --json

# 在本次版本中编译两个迁移实现并导出布局，与各自基类及旧部署布局核对。
forge build script/lib/TSVFactoryMigration.sol --extra-output storageLayout --offline
python3 - <<'PY'
import json
from pathlib import Path
for name in ('TSVRegistryFactoryMigration', 'TSVRouterFactoryBridge'):
    artifact = json.loads(Path(f'out/TSVFactoryMigration.sol/{name}.json').read_text())
    Path(f'dployment/{name}.storage-layout.json').write_text(
        json.dumps(artifact['storageLayout'], indent=2) + '\n'
    )
PY
```

核对每个字段的 slot、offset、类型和继承顺序；AccessControl／Initializable 的 namespaced storage 也需保持所用依赖版本兼容。脚本只检查实现地址、代码哈希和运行时绑定，不替代存储布局审查。

## 7. 部署准备合约

在 zsh 中安全输入已有账户私钥；不生成新私钥，不打印私钥：

```bash
read -rs 'PK?输入升级账户私钥（隐藏输入）: '
export PK
```

如果环境已经安全注入 `PK`，跳过上述输入。`prepare()` 要求该私钥对应 `TSV_UPGRADE_OPERATOR`。

先模拟准备部署，单独输出模拟计划：

```bash
TSV_UPGRADE_PLAN='dployment/factory-migration-dryrun.json' \
forge script "$TSV_UPGRADE_SCRIPT" --sig 'prepare()' \
  --rpc-url "$RPC_URL" --no-metadata
```

再显式广播准备部署：

```bash
forge script "$TSV_UPGRADE_SCRIPT" --sig 'prepare()' \
  --rpc-url "$RPC_URL" --no-metadata --broadcast --slow

forge script "$TSV_UPGRADE_SCRIPT" --sig 'verifyPrepared()' \
  --rpc-url "$RPC_URL" --no-metadata
```

准备阶段可能包含链接库部署；Forge 自动处理库链接。它会部署多个合约，但不会修改五个代理或授予角色。所有目标实现及 Router bridge 的运行时代码长度均被检查为不超过 EIP-170 限制。

**模拟生成的 JSON 不能用于证明真实部署成功。** `prepare()` 的本地 JSON 会先由模拟阶段生成；广播中途失败时它可能包含尚未上链的地址。必须等待准备部署所有交易成功，且 `verifyPrepared()` 在真实 RPC 上通过后才能授权。模拟和正式计划文件不应同名，已存在的计划文件不会被覆盖。

## 8. 授权并原子升级

授权是独立交易；先模拟再广播：

```bash
forge script "$TSV_UPGRADE_SCRIPT" --sig 'authorize()' \
  --rpc-url "$RPC_URL" --no-metadata

forge script "$TSV_UPGRADE_SCRIPT" --sig 'authorize()' \
  --rpc-url "$RPC_URL" --no-metadata --broadcast --slow
```

授权实际成功后，模拟并广播原子升级：

```bash
forge script "$TSV_UPGRADE_SCRIPT" --sig 'execute()' \
  --rpc-url "$RPC_URL" --no-metadata

forge script "$TSV_UPGRADE_SCRIPT" --sig 'execute()' \
  --rpc-url "$RPC_URL" --no-metadata --broadcast --slow
```

记录最后一个命令产生的 **coordinator.execute() 交易哈希**，不是准备阶段的部署交易或授权交易哈希。不要使用 `--skip-simulation`。不要通过原有 `TSVProtocol upgrade-all` 分别发送这次 Factory 切换。

## 9. 回执、回读和部署清单更新

```bash
export TSV_UPGRADE_TX='替换为实际 execute 交易哈希'

cast receipt "$TSV_UPGRADE_TX" --rpc-url "$RPC_URL" --json

forge script "$TSV_UPGRADE_SCRIPT" --sig 'verifyCompleted()' \
  --rpc-url "$RPC_URL" --no-metadata

# 只读验证真实回执、完成事件、canonical block、固定计划和当前链上状态。
python3 script/finalize-factory-migration.py \
  --plan "$TSV_UPGRADE_PLAN" --tx "$TSV_UPGRADE_TX"

# 同样验证通过后，备份并更新本次选用的源部署清单。
python3 script/finalize-factory-migration.py \
  --plan "$TSV_UPGRADE_PLAN" --tx "$TSV_UPGRADE_TX" --write

unset PK
```

完成后的必要等式：

```text
Registry.permissionsAdapterFactory()
  == Router.PERMISSIONS_ADAPTER_FACTORY()
  == LPManager.PERMISSIONS_ADAPTER_FACTORY()
  == 新 Factory

新 Factory.POOL_MANAGER() == 原 PoolManager
新 Factory.LEGACY_FACTORY() == 原 Factory
五个 proxy.tsvImplementation() == 计划中对应 after 实现
Registry.hasRole(UPGRADE_ADMIN_ROLE, coordinator) == false
```

旧 Adapter 的 `permissionsAdapterOf(W)` 和 `verifiedPermissionsAdapterOf(W)` 在新旧 Factory 中应相同；新 Adapter 的映射只存在于新 Factory。全局 Registry/SBT 地址、Hook 关联、LP NFT owner/positionInfo、Router Adapter allowlist 和 Ledger 配额／已用量应保留。

`--write` 只更新选定的源清单，备份保存在 `dployment/history/`，不会自动改写其他部署清单或交互操作器配置。之后同步：

- `script/xlayer/deployment.json` 中同一部署的 `TSV_PERMISSIONS_ADAPTER_FACTORY`；五个代理地址保持不变。
- 后端、索引器使用的新 Factory 地址及新实现 ABI；保留对旧 Factory 的历史／后续事件监听。
- 实际业务使用的其他完整部署清单中的五个 implementation 地址和 Factory；不要拿迁移专用最小快照覆盖含资产、SBT、AA 的完整清单。

在同步同一部署前，逐项比较 Registry/Router/LP/Hook/Ledger 代理地址；不匹配的文件属于其他部署，不能批量替换地址。

## 10. 事件和异常恢复

| 事件 | 发出地址 | 参数和含义 |
| --- | --- | --- |
| `PermissionsFactoryMigrated(address,address)` | Registry **代理** | `previous`、`current` 均 indexed；Factory 存储更新 |
| `Upgraded(address)` | 对应组件代理 | `implementation` indexed；Router 在同一交易会有过渡实现和最终实现两条 |
| `RoleGranted(bytes32,address,address)` | Registry 代理 | 准备授权；协调合约获得升级角色 |
| `RoleRevoked(bytes32,address,address)` | Registry 代理 | 成功结束时协调合约主动 renounce |
| `FactoryMigrationCompleted(bytes32,address,address)` | 协调合约 | `planHash`、`oldFactory`、`newFactory` 均 indexed；全部升级与末尾检查完成 |
| `PermissionsAdapterCreated(address,address)` / `PermissionsAdapterVerified(address,address)` | 新或旧 Factory | 两个参数均 indexed；旧 Adapter 验证转发由旧 Factory 发出事件，不会在新 Factory 重复发出 |

恢复规则：

1. **prepare 失败或中断**：代理未修改。检查 `broadcast/UpgradePermissionsFactory.s.sol/<chainId>/` 中的记录和每笔回执，不要直接重跑部署产生不同地址。只有确认本地广播记录对应本次计划且 nonce 未被其他交易占用，才用 Foundry 的 `--resume` 续传；否则保留旧计划／回执并使用新文件名重新准备。
2. **authorize 已成功但 execute 尚未成功**：角色仍在协调合约上；可查回执后重试同一固定计划，或执行下面的撤销授权命令。
3. **execute 回执 status=0**：该笔交易全部回滚，五个旧实现和旧 Factory 绑定应仍在；准备部署和先前角色授权仍存在。
4. **execute 回执 status=1，但回读网络失败**：先查 receipt、完成事件和 `verifyCompleted()`，不要再次发送升级。重复执行会被拒绝。
5. **成功后的业务回退**：本方案没有自动 rollback。最终 Router 会拒绝 Factory 不同的旧实现；新 Adapter 也无法被旧 Factory 识别。需要另外制定兼容已有新旧资产的反向迁移，不能只把实现地址改回去。

撤销尚未完成的计划授权，同样先模拟再广播：

```bash
forge script "$TSV_UPGRADE_SCRIPT" --sig 'cancelAuthorization()' \
  --rpc-url "$RPC_URL" --no-metadata

forge script "$TSV_UPGRADE_SCRIPT" --sig 'cancelAuthorization()' \
  --rpc-url "$RPC_URL" --no-metadata --broadcast --slow
```

如需续传准备部署，在核对上述条件后使用同一计划环境和广播记录：

```bash
forge script "$TSV_UPGRADE_SCRIPT" --sig 'prepare()' \
  --rpc-url "$RPC_URL" --no-metadata --broadcast --resume --slow
```

`--resume` 使用已有广播记录，不是重新执行 `prepare()` 来重新计算部署地址；续传后必须再次 `verifyPrepared()`。

## 11. 本次验证记录

验证日期：2026-10-19。本机 Forge `1.6.0-nightly`，Solidity 0.8.26。

- 升级合约及 Forge 脚本编译通过；无现有业务合约修改。
- **9 项 Solidity 测试通过**：真实 PoolManager 下保留旧 NFT／nonce／授权／额度，旧池继续 mint/increase/decrease/collect/burn 和双向 swap，两种强制退出，新 Factory 的 Adapter 注册／建池／交易，末尾失败整笔回滚，错误角色／重复／过期／暂停／实现漂移拒绝，Router 原始与最终 Factory 检查，以及 Forge snapshot + rehearse 入口。
- **6 项 Python 工具测试通过**：只读不修改、备份／更新／幂等，失败回执、缺少完成事件、链上状态漂移、篡改计划均拒绝更新。RPC 使用测试响应，不代表真实主网回执验证。
- 当前源码产物的 Registry 基类与迁移实现 14 个普通存储字段一致；Router 基类与过渡实现 8 个普通存储字段一致，包含嵌套类型、slot、offset 检查。未拿链上历史版本产物做布局比较。
- 新 Factory / Registry 迁移实现 / Router bridge / coordinator 运行时代码分别为 8,983 / 16,130 / 14,724 / 8,480 字节；LP Manager 为 23,888 字节，均低于 24,576 字节。
- `forge fmt --check` 和改动格式检查通过。编译仍有仓库原有的 proxy receive、不可达代码、未使用参数及 Foundry 配置提示；未声称全仓测试通过。

尚未执行目标链上的 snapshot、fork 演练、准备部署或广播，也未验证实际链上业务资产和历史仓位。部署操作者仍需执行本文的链上验证步骤；本地测试通过不等于任意已部署版本均可直接升级。

## 附录：完整脚本源码

下方源码与配套文件一致，便于单独分享本文档。实际执行以仓库配套文件为准；修改实现后需重新运行测试并重新生成计划。

### A. Forge 入口

来源：`script/UpgradePermissionsFactory.s.sol`。

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {
    TSVCompatiblePermissionsAdapterFactory,
    TSVRegistryFactoryMigration,
    TSVRouterFactoryBridge,
    TSVFactoryMigrationCoordinator
} from "./lib/TSVFactoryMigration.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {TSVLPManagerV1, IPoolManager, IPermissionsAdapterFactory} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {ITSVPermissionedRegistry} from "tsv-v1/interfaces/ITSVPermissionedRegistry.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";

/// @notice Read docs/TSV_FACTORY_MIGRATION_UPGRADE_GUIDE.md before use.
/// @dev PK is read only by broadcast-capable stages. No stage changes a deployment manifest.
contract UpgradePermissionsFactory is Script {
    /// @notice Capture the selected live topology without deploying or broadcasting anything.
    function snapshot() external {
        require(block.chainid == vm.envUint("TSV_UPGRADE_CHAIN_ID"), "wrong RPC chain");
        string memory path = vm.envString("TSV_UPGRADE_MANIFEST");
        require(!vm.exists(path), "manifest exists; use a fresh path");
        TSVRegistryV1 r = TSVRegistryV1(vm.envAddress("TSV_UPGRADE_REGISTRY"));
        TSVHookV1 h = TSVHookV1(r.hook());
        address[5] memory proxies = [address(r), address(h.ledger()), h.router(), r.lpManager(), address(h)];
        string memory proxyJson;
        string memory implJson;
        string memory hashJson;
        for (uint256 i; i < 5; ++i) {
            address impl = TSVERC1967Proxy(payable(proxies[i])).tsvImplementation();
            require(impl.code.length != 0, "implementation missing");
            proxyJson = vm.serializeAddress("snapshot-proxies", _name(i), proxies[i]);
            implJson = vm.serializeAddress("snapshot-implementations", _name(i), impl);
            hashJson = vm.serializeBytes32("snapshot-hashes", _name(i), impl.codehash);
        }
        string memory result = string.concat(
            '{"chainId":',
            vm.toString(block.chainid),
            ',"snapshotBlock":',
            vm.toString(block.number),
            ',"deploymentStatus":"confirmed","proxies":',
            proxyJson,
            ',"implementations":',
            implJson,
            ',"implementationCodeHashes":',
            hashJson,
            ',"factories":{"permissionedAdapter":"',
            vm.toString(r.permissionsAdapterFactory()),
            '"},"dependencies":{"poolManager":"',
            vm.toString(r.permissionedPoolManager()),
            '"}}'
        );
        vm.writeJson(result, path);
        console2.log("Read-only chain snapshot written; independently confirm deployed source/storage lineage", path);
    }

    function rehearse() external {
        address operator = vm.envAddress("TSV_UPGRADE_OPERATOR");
        // Deliberately no startBroadcast: even --broadcast cannot publish this rehearsal.
        vm.startPrank(operator);
        TSVFactoryMigrationCoordinator c = _deploy(operator);
        TSVFactoryMigrationCoordinator.Plan memory p = c.getPlan();
        TSVRegistryV1 r = TSVRegistryV1(p.proxies[0]);
        r.grantRole(r.UPGRADE_ADMIN_ROLE(), address(c));
        c.execute();
        vm.stopPrank();
        c.verifyCompleted();
        console2.log("Full atomic migration rehearsal passed (no broadcast transactions).");
    }

    function prepare() external {
        string memory path = vm.envString("TSV_UPGRADE_PLAN");
        require(!vm.exists(path), "plan file exists; use a fresh path");
        uint256 pk = vm.envUint("PK");
        address operator = vm.envAddress("TSV_UPGRADE_OPERATOR");
        require(vm.addr(pk) == operator, "PK/operator mismatch");
        vm.startBroadcast(pk);
        TSVFactoryMigrationCoordinator c = _deploy(operator);
        vm.stopBroadcast();
        _writePlan(c, path);
        console2.log("Coordinator", address(c));
        console2.log("Plan written; simulated file is NOT evidence of deployment", path);
    }

    function verifyPrepared() external view {
        TSVFactoryMigrationCoordinator c = _load();
        c.verifyPrepared();
        console2.log("Prepared contracts, old implementations and bindings verified on selected RPC.");
    }

    function authorize() external {
        TSVFactoryMigrationCoordinator c = _load();
        c.verifyPrepared();
        TSVFactoryMigrationCoordinator.Plan memory p = c.getPlan();
        TSVRegistryV1 r = TSVRegistryV1(p.proxies[0]);
        uint256 pk = vm.envUint("PK");
        require(r.hasRole(r.DEFAULT_ADMIN_ROLE(), vm.addr(pk)), "signer lacks default admin role");
        require(!r.hasRole(r.UPGRADE_ADMIN_ROLE(), address(c)), "already authorized; do not resend");
        vm.startBroadcast(pk);
        r.grantRole(r.UPGRADE_ADMIN_ROLE(), address(c));
        vm.stopBroadcast();
        require(r.hasRole(r.UPGRADE_ADMIN_ROLE(), address(c)), "grant failed");
    }

    function execute() external {
        TSVFactoryMigrationCoordinator c = _load();
        c.verifyPrepared();
        uint256 pk = vm.envUint("PK");
        require(vm.addr(pk) == c.getPlan().operator, "signer is not plan operator");
        vm.startBroadcast(pk);
        c.execute();
        vm.stopBroadcast();
        c.verifyCompleted();
    }

    function verifyCompleted() external view {
        TSVFactoryMigrationCoordinator c = _load();
        c.verifyCompleted();
        console2.log("All five implementation slots, new factory bindings and role cleanup verified.");
    }

    function cancelAuthorization() external {
        TSVFactoryMigrationCoordinator c = _load();
        require(!c.executed(), "completed plan already renounced its role");
        TSVRegistryV1 r = TSVRegistryV1(c.getPlan().proxies[0]);
        uint256 pk = vm.envUint("PK");
        require(r.hasRole(r.DEFAULT_ADMIN_ROLE(), vm.addr(pk)), "signer lacks default admin role");
        require(r.hasRole(r.UPGRADE_ADMIN_ROLE(), address(c)), "role absent; nothing to revoke");
        vm.startBroadcast(pk);
        r.revokeRole(r.UPGRADE_ADMIN_ROLE(), address(c));
        vm.stopBroadcast();
    }

    function _deploy(address operator) private returns (TSVFactoryMigrationCoordinator c) {
        string memory j = vm.readFile(vm.envString("TSV_UPGRADE_MANIFEST"));
        TSVFactoryMigrationCoordinator.Plan memory p;
        p.chainId = vm.parseJsonUint(j, ".chainId");
        require(p.chainId == block.chainid, "wrong RPC chain");
        require(
            keccak256(bytes(vm.parseJsonString(j, ".deploymentStatus"))) == keccak256("confirmed"),
            "manifest unconfirmed"
        );
        p.deadline = vm.envUint("TSV_UPGRADE_DEADLINE");
        p.operator = operator;
        p.poolManager = vm.parseJsonAddress(j, ".dependencies.poolManager");
        p.oldFactory = vm.parseJsonAddress(j, ".factories.permissionedAdapter");
        for (uint256 i; i < 5; ++i) {
            string memory component = _name(i);
            p.proxies[i] = vm.parseJsonAddress(j, string.concat(".proxies.", component));
            p.beforeImpl[i] = vm.parseJsonAddress(j, string.concat(".implementations.", component));
            require(
                TSVERC1967Proxy(payable(p.proxies[i])).tsvImplementation() == p.beforeImpl[i],
                "manifest implementation drift"
            );
            p.beforeCodeHash[i] = p.beforeImpl[i].codehash;
            string memory hashPath = string.concat(".implementationCodeHashes.", component);
            if (vm.keyExistsJson(j, hashPath)) {
                require(vm.parseJsonBytes32(j, hashPath) == p.beforeCodeHash[i], "manifest code hash drift");
            }
        }
        TSVRegistryV1 r = TSVRegistryV1(p.proxies[0]);
        require(!r.isPaused(), "Registry paused: cannot migrate");
        require(r.hasRole(r.DEFAULT_ADMIN_ROLE(), operator), "operator lacks default admin role");
        require(r.permissionsAdapterFactory() == p.oldFactory, "manifest factory drift");
        p.newFactory = address(new TSVCompatiblePermissionsAdapterFactory(p.oldFactory));
        p.afterImpl[0] = address(new TSVRegistryFactoryMigration(p.oldFactory, p.newFactory));
        p.afterImpl[1] = address(new TSVVolumeLedgerV1());
        p.afterImpl[2] = address(new TSVSwapRouterV1(p.poolManager, p.newFactory));
        TSVLPManagerV1 oldLP = TSVLPManagerV1(payable(p.proxies[3]));
        p.afterImpl[3] = address(
            new TSVLPManagerV1(
                IPoolManager(p.poolManager),
                oldLP.permit2(),
                oldLP.unsubscribeGasLimit(),
                oldLP.tokenDescriptor(),
                oldLP.WETH9(),
                IPermissionsAdapterFactory(p.newFactory),
                oldLP.DELIVERY_GAS_LIMIT(),
                ITSVPermissionedRegistry(p.proxies[0])
            )
        );
        p.afterImpl[4] = address(new TSVHookV1());
        p.bridge = address(new TSVRouterFactoryBridge(p.poolManager, p.oldFactory, p.afterImpl[2], p.proxies[0]));
        c = new TSVFactoryMigrationCoordinator(p);
    }

    function _load() private view returns (TSVFactoryMigrationCoordinator c) {
        string memory j = vm.readFile(vm.envString("TSV_UPGRADE_PLAN"));
        require(vm.parseJsonUint(j, ".chainId") == block.chainid, "wrong plan chain");
        address a = vm.parseJsonAddress(j, ".coordinator");
        require(
            a.code.length != 0 && a.codehash == vm.parseJsonBytes32(j, ".coordinatorCodeHash"),
            "coordinator missing/code drift"
        );
        c = TSVFactoryMigrationCoordinator(a);
        require(c.PLAN_HASH() == vm.parseJsonBytes32(j, ".planHash"), "wrong plan hash");
    }

    function _writePlan(TSVFactoryMigrationCoordinator c, string memory path) private {
        TSVFactoryMigrationCoordinator.Plan memory p = c.getPlan();
        string memory key = "factory-migration-plan";
        vm.serializeUint(key, "chainId", p.chainId);
        vm.serializeUint(key, "deadline", p.deadline);
        vm.serializeString(key, "sourceManifest", vm.envString("TSV_UPGRADE_MANIFEST"));
        vm.serializeAddress(key, "operator", p.operator);
        vm.serializeAddress(key, "coordinator", address(c));
        vm.serializeBytes32(key, "coordinatorCodeHash", address(c).codehash);
        vm.serializeBytes32(key, "planHash", c.PLAN_HASH());
        vm.serializeAddress(key, "oldFactory", p.oldFactory);
        vm.serializeAddress(key, "newFactory", p.newFactory);
        vm.serializeAddress(key, "bridge", p.bridge);
        vm.serializeAddress(key, "poolManager", p.poolManager);
        for (uint256 i; i < 5; ++i) {
            vm.serializeAddress(key, string.concat(_name(i), "Proxy"), p.proxies[i]);
            vm.serializeAddress(key, string.concat(_name(i), "Before"), p.beforeImpl[i]);
            vm.serializeAddress(key, string.concat(_name(i), "After"), p.afterImpl[i]);
            vm.serializeBytes32(key, string.concat(_name(i), "BeforeCodeHash"), p.beforeCodeHash[i]);
        }
        string memory result = vm.serializeString(key, "status", "unverified-until-readback");
        vm.writeJson(result, path);
    }

    function _name(uint256 i) private pure returns (string memory) {
        if (i == 0) return "registry";
        if (i == 1) return "ledger";
        if (i == 2) return "router";
        if (i == 3) return "lpManager";
        return "hook";
    }
}
```

### B. Factory 兼容、Registry 迁移、Router 过渡与原子协调合约

来源：`script/lib/TSVFactoryMigration.sol`。

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {IPermissionsAdapterFactory} from "tsv-v1/vendor/permissionedPools/interfaces/IPermissionsAdapterFactory.sol";
import {PermissionsAdapter} from "tsv-v1/vendor/permissionedPools/PermissionsAdapter.sol";
import {IERC20} from "tsv-v1/vendor/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {IAllowlistChecker} from "tsv-v1/vendor/permissionedPools/interfaces/IAllowlistChecker.sol";

/// @notice New factory that preserves the original factory's adapter provenance.
/// @dev The fallback is live, not a snapshot. The original factory must remain available.
contract TSVCompatiblePermissionsAdapterFactory is IPermissionsAdapterFactory {
    IPermissionsAdapterFactory public immutable LEGACY_FACTORY;
    address public immutable POOL_MANAGER;
    mapping(address => address) private localAdapters;
    mapping(address => address) private localVerified;

    constructor(address legacy) {
        require(legacy.code.length != 0, "legacy factory has no code");
        LEGACY_FACTORY = IPermissionsAdapterFactory(legacy);
        POOL_MANAGER = LEGACY_FACTORY.POOL_MANAGER();
        require(POOL_MANAGER.code.length != 0, "PoolManager has no code");
    }

    function permissionsAdapterOf(address adapter) public view returns (address) {
        address underlying = localAdapters[adapter];
        return underlying == address(0) ? LEGACY_FACTORY.permissionsAdapterOf(adapter) : underlying;
    }

    function verifiedPermissionsAdapterOf(address adapter) public view returns (address) {
        if (localAdapters[adapter] != address(0)) return localVerified[adapter];
        return LEGACY_FACTORY.verifiedPermissionsAdapterOf(adapter);
    }

    function createPermissionsAdapter(IERC20 token, address owner, IAllowlistChecker checker)
        external
        returns (address adapter)
    {
        require(address(token).code.length != 0, "token has no code");
        adapter = address(new PermissionsAdapter(token, POOL_MANAGER, owner, checker));
        localAdapters[adapter] = address(token);
        emit PermissionsAdapterCreated(adapter, address(token));
    }

    function verifyPermissionsAdapter(address adapter) external {
        address underlying = localAdapters[adapter];
        if (underlying == address(0)) {
            // The legacy contract emits its own event; do not duplicate it here.
            LEGACY_FACTORY.verifyPermissionsAdapter(adapter);
            return;
        }
        if (localVerified[adapter] != address(0)) revert PermissionsAdapterAlreadyVerified(adapter);
        if (IERC20(underlying).balanceOf(adapter) == 0) revert PermissionsAdapterNotVerified(adapter);
        localVerified[adapter] = underlying;
        emit PermissionsAdapterVerified(adapter, underlying);
    }
}

/// @notice Registry implementation with a fixed, one-way factory migration; no new storage slots.
contract TSVRegistryFactoryMigration is TSVRegistryV1 {
    address public immutable EXPECTED_FACTORY;
    address public immutable NEXT_FACTORY;
    event PermissionsFactoryMigrated(address indexed previous, address indexed current);

    constructor(address previous, address next) {
        require(previous != next, "same factory");
        require(address(TSVCompatiblePermissionsAdapterFactory(next).LEGACY_FACTORY()) == previous, "wrong legacy");
        EXPECTED_FACTORY = previous;
        NEXT_FACTORY = next;
    }

    function migratePermissionsFactory() external onlyProxy onlyRole(UPGRADE_ADMIN_ROLE) {
        require(!this.isPaused(), "Registry paused");
        require(permissionsAdapterFactory == EXPECTED_FACTORY, "factory changed/already migrated");
        require(IPermissionsAdapterFactory(NEXT_FACTORY).POOL_MANAGER() == permissionedPoolManager, "wrong PoolManager");
        permissionsAdapterFactory = NEXT_FACTORY;
        emit PermissionsFactoryMigrated(EXPECTED_FACTORY, NEXT_FACTORY);
    }
}

/// @notice Temporary router implementation accepted by the old immutable-dependency guard.
/// @dev Installed and removed inside one coordinator transaction; adds no storage variables.
contract TSVRouterFactoryBridge is TSVSwapRouterV1 {
    address public immutable TARGET_IMPLEMENTATION;
    address public immutable EXPECTED_REGISTRY;
    bytes32 public immutable TARGET_CODE_HASH;

    constructor(address pm, address previousFactory, address target, address registry_)
        TSVSwapRouterV1(pm, previousFactory)
    {
        require(target.code.length != 0, "target has no code");
        require(address(TSVSwapRouterV1(target).poolManager()) == pm, "wrong PoolManager");
        address next = address(TSVSwapRouterV1(target).PERMISSIONS_ADAPTER_FACTORY());
        require(
            address(TSVCompatiblePermissionsAdapterFactory(next).LEGACY_FACTORY()) == previousFactory, "wrong legacy"
        );
        TARGET_IMPLEMENTATION = target;
        EXPECTED_REGISTRY = registry_;
        TARGET_CODE_HASH = target.codehash;
    }

    function completeFactoryMigration() external onlyProxy {
        require(address(registry) == EXPECTED_REGISTRY, "wrong Registry");
        require(!registry.isPaused(), "Registry paused");
        if (!registry.hasRole(UPGRADE_ADMIN_ROLE, msg.sender)) revert UnauthorizedUpgrade();
        if (_getLocker() != address(0)) revert ContractLocked();
        require(TARGET_IMPLEMENTATION.codehash == TARGET_CODE_HASH, "target code changed");
        require(
            registry.permissionsAdapterFactory()
                == address(TSVSwapRouterV1(TARGET_IMPLEMENTATION).PERMISSIONS_ADAPTER_FACTORY()),
            "Registry not migrated"
        );
        // This deliberately bypasses the old equality guard, for this fixed target only.
        // The final standard router restores its immutable-dependency equality guard.
        ERC1967Utils.upgradeToAndCall(TARGET_IMPLEMENTATION, "");
    }
}

interface IFactoryMigrationUUPS {
    function upgradeToAndCall(address next, bytes calldata data) external payable;
}

/// @notice All five proxy upgrades are atomic. This contract has no arbitrary-call interface.
contract TSVFactoryMigrationCoordinator {
    // Component order everywhere: Registry, Ledger, Router, LP Manager, Hook.
    struct Plan {
        uint256 chainId;
        uint256 deadline;
        address operator;
        address poolManager;
        address oldFactory;
        address newFactory;
        address bridge;
        address[5] proxies;
        address[5] beforeImpl;
        address[5] afterImpl;
        bytes32[5] beforeCodeHash;
    }

    Plan private plan;
    bytes32[5] private afterCodeHash;
    bytes32 private immutable bridgeCodeHash;
    bytes32 private immutable factoryCodeHash;
    address private immutable originalSbt;
    bool public executed;
    bytes32 public immutable PLAN_HASH;
    event FactoryMigrationCompleted(bytes32 indexed planHash, address indexed oldFactory, address indexed newFactory);

    constructor(Plan memory p) {
        require(p.operator != address(0) && p.chainId == block.chainid, "invalid operator/chain");
        require(p.deadline > block.timestamp, "expired plan");
        plan = p;
        PLAN_HASH = keccak256(abi.encode(p));
        originalSbt = TSVRegistryV1(p.proxies[0]).participantSbt();
        for (uint256 i; i < 5; ++i) {
            require(
                p.afterImpl[i].code.length != 0 && p.afterImpl[i].code.length <= 24_576, "invalid implementation size"
            );
            afterCodeHash[i] = p.afterImpl[i].codehash;
        }
        require(p.bridge.code.length != 0 && p.bridge.code.length <= 24_576, "invalid bridge size");
        bridgeCodeHash = p.bridge.codehash;
        factoryCodeHash = p.newFactory.codehash;
        verifyPrepared();
    }

    function getPlan() external view returns (Plan memory) {
        return plan;
    }

    function verifyPrepared() public view {
        Plan memory p = plan;
        require(!executed && block.chainid == p.chainId, "executed/wrong chain");
        require(block.timestamp <= p.deadline, "expired plan");
        _verifyImplementations(false);
        _verifyBindings(p.oldFactory);
        _verifyTargets();
        TSVLPManagerV1 oldLP = TSVLPManagerV1(payable(p.proxies[3]));
        TSVLPManagerV1 nextLP = TSVLPManagerV1(payable(p.afterImpl[3]));
        require(
            address(oldLP.permit2()) == address(nextLP.permit2())
                && oldLP.unsubscribeGasLimit() == nextLP.unsubscribeGasLimit()
                && address(oldLP.tokenDescriptor()) == address(nextLP.tokenDescriptor())
                && address(oldLP.WETH9()) == address(nextLP.WETH9())
                && oldLP.DELIVERY_GAS_LIMIT() == nextLP.DELIVERY_GAS_LIMIT(),
            "LP immutable drift"
        );
    }

    function execute() external {
        require(msg.sender == plan.operator, "only operator");
        verifyPrepared();
        Plan memory p = plan;
        TSVRegistryV1 r = TSVRegistryV1(p.proxies[0]);
        require(r.hasRole(r.UPGRADE_ADMIN_ROLE(), address(this)), "coordinator lacks upgrade role");
        executed = true;
        IFactoryMigrationUUPS(p.proxies[0])
            .upgradeToAndCall(p.afterImpl[0], abi.encodeCall(TSVRegistryFactoryMigration.migratePermissionsFactory, ()));
        IFactoryMigrationUUPS(p.proxies[2]).upgradeToAndCall(p.bridge, "");
        TSVRouterFactoryBridge(p.proxies[2]).completeFactoryMigration();
        IFactoryMigrationUUPS(p.proxies[3]).upgradeToAndCall(p.afterImpl[3], "");
        IFactoryMigrationUUPS(p.proxies[1]).upgradeToAndCall(p.afterImpl[1], "");
        IFactoryMigrationUUPS(p.proxies[4]).upgradeToAndCall(p.afterImpl[4], "");
        r.renounceRole(r.UPGRADE_ADMIN_ROLE(), address(this));
        verifyCompleted();
        emit FactoryMigrationCompleted(PLAN_HASH, p.oldFactory, p.newFactory);
    }

    function verifyCompleted() public view {
        require(executed && block.chainid == plan.chainId, "not executed/wrong chain");
        _verifyTargets();
        _verifyImplementations(true);
        _verifyBindings(plan.newFactory);
        TSVRegistryV1 r = TSVRegistryV1(plan.proxies[0]);
        require(!r.hasRole(r.UPGRADE_ADMIN_ROLE(), address(this)), "upgrade role remains");
    }

    function _verifyImplementations(bool after_) private view {
        for (uint256 i; i < 5; ++i) {
            address expected = after_ ? plan.afterImpl[i] : plan.beforeImpl[i];
            require(TSVERC1967Proxy(payable(plan.proxies[i])).tsvImplementation() == expected, "implementation drift");
            require(
                expected.codehash == (after_ ? afterCodeHash[i] : plan.beforeCodeHash[i]), "implementation code drift"
            );
        }
    }

    function _verifyTargets() private view {
        Plan memory p = plan;
        require(p.newFactory.codehash == factoryCodeHash && p.bridge.codehash == bridgeCodeHash, "migration code drift");
        for (uint256 i; i < 5; ++i) {
            require(p.afterImpl[i].codehash == afterCodeHash[i], "target code drift");
        }
        require(
            address(TSVCompatiblePermissionsAdapterFactory(p.newFactory).LEGACY_FACTORY()) == p.oldFactory,
            "wrong legacy"
        );
        require(IPermissionsAdapterFactory(p.newFactory).POOL_MANAGER() == p.poolManager, "wrong new PoolManager");
        TSVRegistryFactoryMigration nextR = TSVRegistryFactoryMigration(p.afterImpl[0]);
        require(
            nextR.EXPECTED_FACTORY() == p.oldFactory && nextR.NEXT_FACTORY() == p.newFactory, "wrong Registry migration"
        );
        TSVRouterFactoryBridge bridge = TSVRouterFactoryBridge(p.bridge);
        require(
            bridge.TARGET_IMPLEMENTATION() == p.afterImpl[2] && bridge.EXPECTED_REGISTRY() == p.proxies[0],
            "wrong bridge"
        );
        _verifyPeriphery(p.bridge, p.afterImpl[3], p.oldFactory, p.newFactory);
        _verifyPeriphery(p.afterImpl[2], p.afterImpl[3], p.newFactory, p.newFactory);
    }

    function _verifyPeriphery(address router_, address lp_, address routerFactory, address lpFactory) private view {
        TSVSwapRouterV1 router = TSVSwapRouterV1(router_);
        TSVLPManagerV1 lp = TSVLPManagerV1(payable(lp_));
        require(
            address(router.poolManager()) == plan.poolManager && address(lp.poolManager()) == plan.poolManager,
            "PoolManager drift"
        );
        require(address(router.PERMISSIONS_ADAPTER_FACTORY()) == routerFactory, "Router factory drift");
        require(address(lp.PERMISSIONS_ADAPTER_FACTORY()) == lpFactory, "LP factory drift");
        require(address(lp.registry()) == plan.proxies[0], "LP Registry drift");
    }

    function _verifyBindings(address factory) private view {
        Plan memory p = plan;
        TSVRegistryV1 r = TSVRegistryV1(p.proxies[0]);
        TSVHookV1 h = TSVHookV1(p.proxies[4]);
        require(!r.isPaused(), "Registry paused");
        require(
            r.permissionsAdapterFactory() == factory && r.permissionedPoolManager() == p.poolManager,
            "Registry factory drift"
        );
        require(
            r.hook() == p.proxies[4] && r.lpManager() == p.proxies[3] && r.participantSbt() == originalSbt,
            "Registry binding drift"
        );
        require(
            address(h.registry()) == p.proxies[0] && address(h.poolManager()) == p.poolManager, "Hook binding drift"
        );
        require(
            h.router() == p.proxies[2] && h.lpManager() == p.proxies[3] && address(h.ledger()) == p.proxies[1],
            "Hook components drift"
        );
        require(address(TSVVolumeLedgerV1(p.proxies[1]).registry()) == p.proxies[0], "Ledger Registry drift");
        require(address(TSVSwapRouterV1(p.proxies[2]).registry()) == p.proxies[0], "Router Registry drift");
        _verifyPeriphery(p.proxies[2], p.proxies[3], factory, factory);
    }
}
```

### C. 回执验证和清单更新工具

来源：`script/finalize-factory-migration.py`。

```python
#!/usr/bin/env python3
"""Verify the atomic upgrade receipt and live plan, then optionally update its public manifest."""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
COMPONENTS = ("registry", "ledger", "router", "lpManager", "hook")


def run(*args):
    result = subprocess.run(args, cwd=ROOT, capture_output=True, text=True)
    if result.returncode:
        # RPC URLs may contain credentials; do not echo subprocess arguments/errors.
        raise RuntimeError(f"{args[0]} failed; inspect the node/CLI separately")
    return result.stdout.strip()


def rpc(method, *params):
    encoded = [json.dumps(value) if not isinstance(value, str) else value for value in params]
    return json.loads(run("cast", "rpc", "--rpc-url", os.environ["RPC_URL"], method, *encoded))


def call(address, signature):
    return rpc("eth_call", {"to": address, "data": run("cast", "sig", signature)}, "latest")


def deployment_path(value):
    path = (ROOT / value).resolve()
    if not path.is_relative_to(ROOT / "dployment"):
        raise ValueError("manifest and plan must be inside dployment/")
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", required=True)
    parser.add_argument("--tx", required=True, help="Hash of coordinator.execute transaction")
    parser.add_argument("--write", action="store_true", help="Back up and update the source deployment manifest")
    args = parser.parse_args()
    plan = json.loads(deployment_path(args.plan).read_text())
    coordinator = plan["coordinator"].lower()
    chain = int(rpc("eth_chainId"), 16)
    if chain != plan["chainId"]:
        raise ValueError("wrong RPC chain")
    code = rpc("eth_getCode", coordinator, "latest")
    if code == "0x" or run("cast", "keccak", code).lower() != plan["coordinatorCodeHash"].lower():
        raise ValueError("coordinator missing/code mismatch")
    raw_plan = call(coordinator, "getPlan()")
    if len(raw_plan) != 2 + 27 * 64:
        raise ValueError("unexpected coordinator Plan ABI")
    plan_hash = run("cast", "keccak", raw_plan).lower()
    if plan_hash != plan["planHash"].lower() or call(coordinator, "PLAN_HASH()").lower() != plan_hash:
        raise ValueError("plan hash mismatch")
    words = [raw_plan[2 + i * 64:2 + (i + 1) * 64] for i in range(27)]
    address = lambda i: "0x" + words[i][-40:]
    if int(words[0], 16) != chain or int(words[1], 16) != plan["deadline"]:
        raise ValueError("plan chain/deadline mismatch")
    for field, index in (("operator", 2), ("poolManager", 3), ("oldFactory", 4), ("newFactory", 5), ("bridge", 6)):
        if address(index) != plan[field].lower():
            raise ValueError(f"plan {field} mismatch")
    for i, name in enumerate(COMPONENTS):
        for suffix, start in (("Proxy", 7), ("Before", 12), ("After", 17)):
            if plan[name + suffix].lower() != address(start + i):
                raise ValueError(f"plan {name}{suffix} mismatch")

    receipt = rpc("eth_getTransactionReceipt", args.tx)
    if not receipt or int(receipt["status"], 16) != 1 or receipt["to"].lower() != coordinator:
        raise ValueError("missing/failed/wrong-target execution receipt")
    tx = rpc("eth_getTransactionByHash", args.tx)
    if tx["from"].lower() != plan["operator"].lower() or tx["input"].lower() != run("cast", "sig", "execute()").lower():
        raise ValueError("not the planned operator's execute transaction")
    block = rpc("eth_getBlockByNumber", receipt["blockNumber"], False)
    if not block or block["hash"].lower() != receipt["blockHash"].lower():
        raise ValueError("receipt is not on the current canonical chain")
    topic = run("cast", "keccak", "FactoryMigrationCompleted(bytes32,address,address)").lower()
    expected_topics = [topic, plan_hash, "0x" + plan["oldFactory"][2:].lower().zfill(64), "0x" + plan["newFactory"][2:].lower().zfill(64)]
    if not any(log["address"].lower() == coordinator and [t.lower() for t in log["topics"]] == expected_topics for log in receipt["logs"]):
        raise ValueError("expected completion event missing")
    call(coordinator, "verifyCompleted()")  # Reverts on any live implementation/binding/role mismatch.

    source = deployment_path(plan["sourceManifest"])
    manifest = json.loads(source.read_text())
    if manifest["chainId"] != chain:
        raise ValueError("source manifest chain mismatch")
    for name in COMPONENTS:
        if manifest["proxies"][name].lower() != plan[name + "Proxy"].lower():
            raise ValueError("source manifest proxy drift")
    if manifest.get("factoryMigration", {}).get("transactionHash", "").lower() == args.tx.lower():
        if manifest["factories"]["permissionedAdapter"].lower() != plan["newFactory"].lower() or any(
            manifest["implementations"][name].lower() != plan[name + "After"].lower() for name in COMPONENTS
        ):
            raise ValueError("recorded migration has inconsistent manifest bindings")
        print("Receipt and live state verified; this transaction is already recorded.")
        return
    if manifest["factories"]["permissionedAdapter"].lower() != plan["oldFactory"].lower():
        raise ValueError("source manifest factory drift")
    for name in COMPONENTS:
        if manifest["implementations"][name].lower() != plan[name + "Before"].lower():
            raise ValueError("source manifest implementation drift")
        manifest["implementations"][name] = plan[name + "After"]
        deployed = rpc("eth_getCode", plan[name + "After"], "latest")
        manifest.setdefault("implementationCodeHashes", {})[name] = run("cast", "keccak", deployed)
    manifest["factories"]["permissionedAdapter"] = plan["newFactory"]
    manifest["deploymentStatus"] = "confirmed"
    manifest["factoryMigration"] = {
        "coordinator": coordinator, "planHash": plan_hash,
        "previousFactory": plan["oldFactory"], "factory": plan["newFactory"],
        "transactionHash": args.tx, "blockNumber": int(receipt["blockNumber"], 16),
        "blockHash": receipt["blockHash"], "verifiedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
    }
    print("Execution receipt, completion event, canonical block and live state verified.")
    print("Factory:", plan["oldFactory"], "->", plan["newFactory"])
    if not args.write:
        print("Read-only verification complete. Add --write to back up and update:", source)
        return
    history = ROOT / "dployment/history"
    history.mkdir(parents=True, exist_ok=True)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    (history / f"{stamp}-before-factory-migration.json").write_bytes(source.read_bytes())
    temporary = source.with_name(source.name + ".factory-migration.tmp")
    temporary.write_text(json.dumps(manifest, indent=2) + "\n")
    temporary.replace(source)
    print("Manifest updated:", source)


if __name__ == "__main__":
    main()
```

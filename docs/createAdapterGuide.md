# PermissionsAdapter 创建、验证与 TSV 配置指南

本文根据当前工作区源码整理，未读取链上配置。执行前确认目标链、RPC 和部署版本。命令使用 Foundry 的 `cast`；本指南不会自动发送交易。

## 1. 合约地址与交易数量

| 合约 | 地址 |
| --- | --- |
| PermissionsAdapterFactory | `0x92cdb229613da8ca45e375cf69df4b3b645ff48d` |
| 已创建的 PermissionsAdapter | `0xf6bb667b55d0cacdb9d2bb9d75d78b4ebe1f1b6c` |

对于已创建、尚未验证且尚未配置的 adapter：

| 操作 | 交易数量 |
| --- | --- |
| 直接转入底层 Token，再调用 Factory 验证 | 2 |
| 授权 Router、LP Manager、Hook，并开启 Swap | 4 |
| 合计，不含创建和 Registry 登记 | 6 |

如果从头创建，再增加 1 笔创建交易，共 7 笔。已完成的步骤可以跳过；adapter 已有非零底层 Token 余额时，无需再转入验证资金。

## 2. 环境变量与签名账户

| 变量 | 含义 |
| --- | --- |
| `RPC_URL` | Factory、adapter 和 TSV 组件所在链的 RPC |
| `PRIVATE_KEY` | 验证资金提供账户的私钥；账户须有底层 Token 和手续费资产 |
| `OWNER_PRIVATE_KEY` | adapter 当前 owner 的私钥；用于后续 4 笔配置交易 |
| `ROUTER` | TSVSwapRouterV1 代理地址 |
| `LP_MANAGER` | TSVLPManagerV1 代理地址 |
| `HOOK` | TSVHookV1 代理地址 |
| `ADAPTER_OWNER` | 创建时指定的 adapter owner，仅新建时需要 |
| `ALLOWLIST_CHECKER` | 实现 IAllowlistChecker 的检查合约地址，仅新建时需要 |

私钥通过已有环境变量提供，不写入文档或脚本。若资金账户和 owner 是同一账户，两种签名操作可使用同一账户。

```bash
# export FACTORY=0x038b77f3355afe8aea10c6c2b7be9312d8148e3f
export FACTORY=0x92cdb229613da8ca45e375cf69df4b3b645ff48d
# export ADAPTER=0x4cf5b1073ec81b45419358c63a2bafc83842c60d
export ADAPTER=0xf6bb667b55d0cacdb9d2bb9d75d78b4ebe1f1b6c
export ADAPTER_OWNER=0x224467f6640AbE0A62D1be98187912627b59722A
export ALLOWLIST_CHECKER=0xb4110157542283aecacb7483b7029d2216507525
export PERMISSIONED_TOKEN=0x28Ccb07e804c6541634C07f1809f7Eaae3B523B0
export LP_MANAGER=0xf73d8683b948564d2795c62a2a909012ea168d29
export HOOK=0xbc6d8c8a8b681872a93554116f01268f80c9ffff
export RPC_URL=https://xlayerrpc.okx.com
export ROUTER=0xe5df3ab010bb20094f490dfcf61b6e2d9a3311c8

# Read the underlying token address from the adapter.
export UNDERLYING=$(cast call "$ADAPTER" \
  "PERMISSIONED_TOKEN()(address)" --rpc-url "$RPC_URL")
```

以下命令为只读查询，不产生交易：

```bash
cast chain-id --rpc-url "$RPC_URL"

cast call "$ADAPTER" "owner()(address)" --rpc-url "$RPC_URL"

cast call "$FACTORY" \
  "permissionsAdapterOf(address)(address)" "$ADAPTER" \
  --rpc-url "$RPC_URL"

cast call "$FACTORY" \
  "verifiedPermissionsAdapterOf(address)(address)" "$ADAPTER" \
  --rpc-url "$RPC_URL"

cast call "$PERMISSIONED_TOKEN" \
  "balanceOf(address)(uint256)" "$ADAPTER" \
  --rpc-url "$RPC_URL"
```

确认 `permissionsAdapterOf(ADAPTER)` 返回 `UNDERLYING`。若 `verifiedPermissionsAdapterOf(ADAPTER)` 已返回 `UNDERLYING`，跳过第 1、2 笔验证交易。

## 3. 可选：创建新的 adapter

本文给出的 adapter 已创建，可直接跳至第 4 节。只有需要新建时才执行本节。

将 `PERMISSIONED_TOKEN` 设置为待包装的底层 Token U，`ADAPTER_OWNER` 设置为新 adapter 的 owner，`ALLOWLIST_CHECKER` 设置为权限检查合约。

```bash
cast send "$FACTORY" \
  "createPermissionsAdapter(address,address,address)(address)" \
  "$PERMISSIONED_TOKEN" \
  "$ADAPTER_OWNER" \
  "$ALLOWLIST_CHECKER" \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY"
```

当前源码中创建接口没有角色限制。checker 必须通过 IAllowlistChecker 的 ERC-165 接口检查，不能使用普通钱包地址；initialOwner 不能为零地址。

新 adapter 地址从交易回执中的事件获取：

```solidity
event PermissionsAdapterCreated(
    address indexed permissionsAdapter,
    address indexed permissionedToken
);
```

发送交易得到的是交易回执，函数签名中的 `(address)` 不表示 cast 会直接显示新 adapter 地址。新建后须将 `ADAPTER` 改为事件中的地址，并重新读取 `UNDERLYING`。

## 4. 第 1 笔：转入底层 Token

Factory 验证要求底层 Token 的 `balanceOf(ADAPTER)` 大于零。可以直接向 adapter 转账，无需先 approve。

```bash
cast send "$PERMISSIONED_TOKEN" \
  "transfer(address,uint256)(bool)" "$ADAPTER" 1 \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY"
```

`1` 是 1 个最小单位，不是 1 枚完整 Token。资金账户和 adapter 须满足底层 Token 的转账及发行方白名单限制。转账后回读余额，确认实际到账大于零；有手续费或最小转账限制的 Token 需要调整数量。

```bash
cast call "$PERMISSIONED_TOKEN" "balanceOf(address)(uint256)" "$ADAPTER" --rpc-url "$RPC_URL"
```

## 5. 第 2 笔：Factory 验证

```bash
cast send "$FACTORY" \
  "verifyPermissionsAdapter(address)" "$ADAPTER" \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY"
```

此接口没有 owner 或角色限制。Factory 检查 adapter 由自身创建、尚未验证，且持有非零底层 Token 余额，然后记录验证状态。

回读结果应等于 `UNDERLYING`：

```bash
cast call "$FACTORY" \
  "verifiedPermissionsAdapterOf(address)(address)" "$ADAPTER" \
  --rpc-url "$RPC_URL"
```

重复验证会 revert `PermissionsAdapterAlreadyVerified`；未知 adapter 会 revert `PermissionsAdapterNotFound`；底层 Token 余额为零会 revert `PermissionsAdapterNotVerified`。

## 6. 第 3～6 笔：配置 TSV 使用权限

以下接口均要求调用者是 adapter 当前 owner。先确认 `ROUTER`、`LP_MANAGER`、`HOOK` 是目标 TSV 实例的代理地址。

```bash
# Transaction 3: allow the TSV Router to wrap underlying tokens.
cast send "$ADAPTER" \
  "updateAllowedWrapper(address,bool)" "$ROUTER" true \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY"

# Transaction 4: allow the TSV LP Manager to wrap underlying tokens.
cast send "$ADAPTER" \
  "updateAllowedWrapper(address,bool)" "$LP_MANAGER" true \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY"

# Transaction 5: allow the TSV Hook.
cast send "$ADAPTER" \
  "updateAllowedHook(address,bool)" "$HOOK" true \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY"

# Transaction 6: enable swaps.
cast send "$ADAPTER" \
  "updateSwappingEnabled(bool)" true \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY"
```

## 7. 配置回读

以下四项均应返回 `true`：

```bash
cast call "$ADAPTER" \
  "allowedWrappers(address)(bool)" "$ROUTER" \
  --rpc-url "$RPC_URL"

cast call "$ADAPTER" \
  "allowedWrappers(address)(bool)" "$LP_MANAGER" \
  --rpc-url "$RPC_URL"

cast call "$ADAPTER" \
  "allowedHooks(address)(bool)" "$HOOK" \
  --rpc-url "$RPC_URL"

cast call "$ADAPTER" \
  "swappingEnabled()(bool)" \
  --rpc-url "$RPC_URL"
```

## 8. 使用 depositForVerification 的替代路径

如果不直接 transfer，可用以下两笔替代第 1 笔，再执行第 2 笔 Factory 验证：

```bash
cast send "PERMISSIONED_TOKEN" \
  "approve(address,uint256)(bool)" "$ADAPTER" 1 \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY"

cast send "$ADAPTER" \
  "depositForVerification(uint256)" 1 \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY"
```

此路径从已创建的 adapter 开始，共 3 笔完成验证、再加 4 笔 TSV 配置，共 7 笔。直接 transfer 与 approve + deposit 二选一，无需重复执行两条资金转入路径。

## 9. 完成范围与后续操作

以上步骤只完成 Factory 验证和 adapter 侧配置。用于 TSV 池还需要：

- Registry 已绑定正确的 Factory、Hook、LP Manager 和 SBT。
- 使用 SYMBOL_ADMIN_ROLE 调用 Registry.registerPermissionedCurrency，登记 W、securityId、legalShareAdapter 及 tier；相关 tier 须先配置。
- 完成报价 Token 登记、创建池及必要的额度与身份配置。
- 参与者通过 allowListChecker 和底层 Token 的发行方权限检查。

Factory 验证成功不等于以上 Registry、池和用户权限配置均已完成。

## 10. 源码依据

- [PermissionsAdapterFactory.sol](../src/v1/vendor/permissionedPools/PermissionsAdapterFactory.sol)：创建、Factory 映射与验证条件。
- [PermissionsAdapter.sol](../src/v1/vendor/permissionedPools/PermissionsAdapter.sol)：验证存款、owner 权限、wrapper/Hook 白名单和 Swap 开关。
- [市场开通指南](OPENING_A_STOCK_MARKET_V1.md)：当前 Registry、Factory、资产和池的配置顺序。


cast send "$PERMISSIONED_TOKEN" 'setUIMultiplier(uint256,uint256)' "$UI_NEW_MULTIPLIER" "$UI_EFFECTIVE_AT" --private-key "$PRIVATE_KEY" --rpc-url "$RPC_URL"
# OTA-01：实时乘数准入检查与后续生产升级

关联 Issue：<https://gitlab.okg.com/web3-dex/tsv/-/work_items/35>。

## 生产基线

- 部署源码：`a8bfc93aa2cf40142e6511e5069d90f65b59f420`。
- 固定分支：`release-prod-V0.0.1-20261029`；日期采用部署清单的 `deploymentDate`，Hook 部署于 2026-10-30 完成。
- Registry 代理：`0x5bd7ea82642b49ebdfc3fbc0e656941c165392ea`。
- 原 Registry 实现：`0xf68f1d1d990352eeb83fc68ab705a98114bbbf13`。
- 原校验库：`0x8db3a851e94b38e258f801f835e2e7deeb217538`。

区块 `74915874` 的只读回查确认 Registry 仍使用上述原实现。本次代码修复不包含任何生产部署或升级交易。

## 变更

Registry 的首次股票准入和 `replaceUnderlyingLegalShareAdapter` 共享 `PermissionedValidationLib.validateLegalShareAdapter`。在原有接口和绑定 U 的校验后，新增对 `currentMultiplier(U)` 的实时读取：调用回退、返回不足一个 ABI word 或值为零时拒绝操作。失败交易会回滚上市计数、证券登记及 Adapter 变更。

`ERC8056DirectLegalShareAdapter` 的构造函数也读取 U 的 `uiMultiplier()`，拒绝缺少接口、畸形返回和零乘数的源。正乘数不要求固定为 `1e18`，不使用一次最小 raw amount 的换算结果代替乘数检查，避免拒绝合法的舍入情况。

不缓存乘数，后续合法的乘数更新仍由运行时读取。准入探测不能证明未来所有调用均可用，也不能证明 Adapter 的经济换算定义正确；既有交易时检查继续保留。

## 后续升级方式

1. 基于最终合并的固定 commit 构建并部署新版 `PermissionedValidationLib`。
2. 使用新库地址链接并部署新的 `TSVRegistryV1` 实现。旧库不可原地修改，仅部署新库不会让原实现自动使用它。
3. 按生产基线比较 Registry 的完整存储布局、公共 ABI 和绑定地址，核对候选实现的 `permissionedValidationLibrary()` 返回新库地址。
4. 由当时持有 `UPGRADE_ADMIN_ROLE` 的治理账户，通过 Registry 代理的 `upgradeToAndCall(newImplementation, "0x")` 执行既定升级流程。此次没有新存储字段或迁移初始化步骤，不要重新调用 `initialize`。
5. 升级后核对实现槽、校验库 getter、角色、绑定组件、Tier、股票/池记录和 Ledger 数据，并先模拟后续准入或 Adapter 替换操作。

本项不要求升级 Hook、Router、LPManager 或 Ledger。既有不可升级 Adapter 不会自动获得新的构造检查，但只要仍正常返回正乘数，就不需要为本项重新部署。新构造检查适用于将来新部署的 Adapter。

新准入检查只约束升级后执行的准入与替换；它不会自动重新验证、撤销或修改既有登记。生产升级仍需单独安排，本 MR 的测试结果不代表升级已执行。

## 验证

准备仓库既有依赖后运行：

```sh
FOUNDRY_PROFILE=ota01 forge test -vv
```

该专项入口复用 Adapter、准入、替换、Hook/Ledger 消费及 Factory 检查测试，54 项通过，包含每项 256 次的 fuzz。默认构建和测试入口保持原样。

额外执行全部 Registry 单测及 Adapter 单测，共 95 项，90 项通过、5 项失败；这 5 项 SBT/角色测试已在未修改的生产源码基线上逐项复现，未由本项修复引入，本 MR 未扩展修改其行为或期望。具体测试名和兼容性摘要见 [OTA-01-validation.json](OTA-01-validation.json)。

两个针对性回归用例在修复前均失败、修复后通过。比较确认 Registry 的 14 项传统存储条目及其递归类型布局不变，Registry、校验库和 Adapter 的公共 ABI 不变；命名空间存储依赖未更改。

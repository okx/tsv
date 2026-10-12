# TSV LP Manager 链接库与代码大小

`TSVLPManagerV1` 使用链接库拆分 LP action 校验、支付、退出和位置数学逻辑。当前源码中主要对应 [`TSVLPManagerLib.sol`](../src/v1/libraries/TSVLPManagerLib.sol) 与 [`LPPositionMath.sol`](../src/v1/vendor/permissionedPools/libraries/LPPositionMath.sol)。本说明不保存某一历史编译的 runtime 大小；每个候选 commit 都应使用目标部署配置重新构建核验。

## 当前继承与状态边界

`TSVLPManagerV1` 继承 `Initializable`、`UUPSUpgradeable` 和本地 `PermissionedPositionManager`。LP 业务角色通过 Registry 查询；代理 initializer 是 `initialize(registry)`。PoolManager、Permit2、Descriptor、WETH、Permissions Adapter Factory、TokenApproveProxy 及若干 gas 参数由实现构造器固定。升级前必须核对候选 implementation 与 proxy 部署环境匹配，不能仅凭 storage layout 相同就升级。

`TSVLPManagerLib` 是无持久状态库，借助 Solidity 链接调用在 LP Manager 上下文执行，并从主合约接收必要的 mapping/storage 及 immutable 地址。`LPPositionMath` 提供上游 position 数学所需计算。修改库调用、继承链或数据传递会影响运行时大小、执行 gas 和链接字节码。

## 代码大小门槛

EIP-170 合约 runtime 上限为 24,576 bytes。提交前构建生产 profile 并检查 LP Manager 和每个链接库的 runtime/initcode 大小：

```sh
forge build src --sizes
```

如修改了链接地址或库实现，部署 bytecode 必须使用同一组 library addresses 和同一 compiler/EVM/optimizer 配置。不要依赖 `code_size_limit`、本地测试放宽值或旧 MR 的数值替代当前产物检查。

## 行为不变量

- 普通 LP position/settlement action 必须通过当前 Registry、SBT 与 issuer permission checks。
- 两个 delta-funded mint/increase action 不受支持；`withdrawClaim` 禁用。
- 普通 mint/burn 成功后更新 Registry position NFT 计数。
- unwind 使用专用、一次性 PoolManager callback 授权；不同 unwind 入口的资产交付路径不同，见 [`SYSTEMS_OVERVIEW.md`](./SYSTEMS_OVERVIEW.md)。
- 库调用不得绕过 global pause、Hook 检查、NFT owner 授权或结束时清理 unwind callback state。

单元链接库测试不能替代真实 PoolManager 的本地 LP 集成。测试位置及实际边界见 [`../test/README.md`](../test/README.md) 和 [`TEST_COVERAGE_V1.md`](./TEST_COVERAGE_V1.md)。

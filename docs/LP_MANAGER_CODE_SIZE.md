# LP Manager 的链接库拆分

`TSVLPManagerV1` 通过链接库解决 EIP-170 大小限制，并直接继承 `Initializable` / `UUPSUpgradeable`，不再继承 `TSVGoverned`。拆出的流动性业务代码保留原来的分支、校验顺序、错误、事件和失败回滚方式；角色统一查询 Registry。

在本次固定配置下，主合约 runtime 从 **30,646 B** 降为 **22,955 B**，距离 24,576 B 上限剩余 **1,621 B**。后续改动须继续运行大小回归，不能只依赖普通测试环境能否创建合约。

## 代码对应关系

| 原实现 | 拆分后 |
| --- | --- |
| TSV 的建池、支付、普通 action 校验、NFT 计数更新 | `TSVLPManagerLib`；主合约保留入口门禁及上游 action 执行顺序 |
| 两种 unwind 的状态检查、退订、burn 参数构造和交付 | `TSVLPManagerLib.unwindPositionByOkx` / `unwindPosition`，仍然是两个独立函数 |
| `PermissionedPositionManager` 的交付回退、claim 提取、币种校验、sweep | 库内对应函数；LP → issuer admin → ERC-6909 claim 的顺序不变 |
| NFT permit、Permit2 转发、订阅和 multicall | 库内搬运原实现；入口暂停/截止时间/审批/锁检查仍在主合约 |
| `TickMath` / `LiquidityAmounts` | `LPPositionMath` 直接调用原版 Uniswap 函数，不重写公式 |

`PositionManager.sol` 只改两条数学库 import，调用代码不变。`PermissionedPositionManager.sol` 只给 `_sweep` 增加 `virtual`，函数体不变。`lib/` 下的 Uniswap 依赖没有修改。

库通过 Solidity 生成的 `delegatecall` 执行，沿用 LP 代理的 `address(this)`、`msg.sender`、`msg.value` 和瞬态存储。NFT 映射以 `storage` 引用传入，不硬编码存储槽。退出回调仍使用原来的瞬态槽和一次性数据哈希授权。签名使用主合约读取的代理 EIP-712 domain。

## 编译与部署

使用仓库原有编译配置：Solidity 0.8.26、Cancun、via-IR、optimizer runs 200。无需单独的 `lp-size` 配置，没有提高 `code_size_limit`。新增回归用例直接检查部署后实现和两个库的代码长度均不超过 24,576 字节。

部署时先部署两个库，再将真实库地址链接进 LP 实现。两个库都没有构造参数：

- `src/v1/libraries/TSVLPManagerLib.sol:TSVLPManagerLib`
- `src/v1/vendor/permissionedPools/libraries/LPPositionMath.sol:LPPositionMath`

使用已部署的地址编译：

```sh
forge build src/v1/periphery/TSVLPManagerV1.sol \
  --libraries "src/v1/libraries/TSVLPManagerLib.sol:TSVLPManagerLib:$TSV_LP_MANAGER_LIBRARY" \
  --libraries "src/v1/vendor/permissionedPools/libraries/LPPositionMath.sol:LPPositionMath:$TSV_LP_POSITION_MATH_LIBRARY"
```

部署与验证实现时使用相同编译配置和库地址；实现构造参数不变，代理初始化改为 `initialize(ITSVPermissionedRegistry registry)`，不再传 Anchor。链接地址是实现字节码的一部分，不能独立修改。新增库调用增加部分执行 gas；本次不宣称 gas 与拆分前相同。

## Registry 权限与 UUPS

- 建池：`registry.hasRole(POOL_CREATOR_ROLE, msg.sender)`。
- OKX 强制退出：`registry.hasRole(FORCE_EXIT_ADMIN_ROLE, msg.sender)`。
- UUPS 升级：Registry 的 `DEFAULT_ADMIN_ROLE`（`bytes32(0)`）或 Registry 指定 Anchor 的活跃批量调用可以授权；二者都必须满足 Anchor 未冻结升级。当前 Registry 将默认管理员动态解析为 Governor，身份恢复后立即切换。
- 所有角色在 Registry 上授予、撤销；LP 不再提供 `grantRole` / `revokeRole` / `renounceRole` / `hasRole` / `getRoleAdmin`，也不再声明支持 IAccessControl。旧 LP 本地角色不会自动迁移，升级前须在 Registry 上配置对应业务角色。
- LP 保留 Registry 暂停门禁以及 Anchor 的升级冻结和批量升级机制。`_authorizeUpgrade` 从 Registry 获取 Anchor，并显式检查默认管理员或活跃 Anchor 批量上下文；不使用会提前拒绝 Anchor 的 `onlyRole` 修饰器。未经授权返回 `UnauthorizedUpgrade`，冻结时返回 `UpgradeFrozen`。
- `governanceAnchor()` 仅转发 Registry 查询，供原有六组件绑定校验使用，不在 LP 保存治理身份。原 `governanceAnchor` 的 slot 11 保留为未使用的私有地址；NFT 状态、Registry 的 slot 12 和 gap 均不移动，Initializable 的命名空间不变。
- 删除治理相关 ABI（含 LP 不使用的六个角色常量 getter）是显式接口变更；ERC-721、流动性和退出接口保持原样。新代理必须在构造时原子调用新 initializer；已有代理升级时不重复初始化。

## 验证范围

```sh
forge test --match-path 'test/unit/v1/deployment/LP*.t.sol' -vv
forge test --summary
forge build src --sizes
python3 script/check-test-layout.py
```

新增用例覆盖代理 domain 与 nonce 重放、带 value 的 permit、Permit2 catch 返回、multicall 的调用者和原子回滚、订阅失败的完整错误数据、退出时订阅重挂、普通操作权限/下架门禁、支付调用者与付款人、两种退出的交付/claim 回退、NFT 计数失败回滚、回调授权清理、claim 收款哨兵、底层资产 sweep，以及与原数学库成功/失败结果的 fuzz 差分。

退出回归使用明确的 PoolManager 行为替身，验证库拆分的控制流和存储上下文；它不代表真实池流动性或链上 gas 的完整集成验证。权限测试使用真实 Registry 的 `hasRole` / `grantRole` / `revokeRole` 及真实 Anchor 的 `upgradeBatch`；测试派生合约直接设置 LP 绑定以隔离其余五组件的部署，不覆盖整组组件绑定。`isPaused` 和 LP 消费者接口仍由 mock 提供，不代表已有 Registry consumer 集成缺口已解决。

本次本地验证结果：

- LP 专项 32/32 通过：22 个链接库行为/大小用例和 10 个 Registry 权限/UUPS 用例。其中 18 个业务行为用例此前在恢复拆分前合约和编译配置后也全部通过；权限用例使用真实 Registry 的授予/撤销和管理员恢复，并覆盖 Anchor 批量升级、冻结/解冻和失败后的上下文回滚。
- 库拆分阶段完整 ABI 相同；此次 Registry 权限调整的 ABI 变化见上文。存储兼容检查仅允许旧 Anchor 槽替换为等宽预留地址，其余槽、偏移和类型保持一致。
- `forge build src --sizes`、修改文件格式检查、diff 检查和测试目录检查通过。
- 上一次仅 Registry 授权版本的完整测试集为 241 通过、45 失败；恢复原合约和原编译配置后，232 通过、同样 45 个测试失败。基线跳过新增的 EIP-170 大小用例。失败集中于既有 Wrapped Swap、DEX Adapter、Registry consumer 套件，本次未修改这些业务。两次运行的随机 fuzz 输入不同，不将随机用例的错误文本视为逐字相同。

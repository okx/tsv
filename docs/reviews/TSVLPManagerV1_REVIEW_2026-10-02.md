# TSVLPManagerV1 逻辑 Review

| 项目 | 内容 |
|---|---|
| 日期 | 2026-10-02 |
| 审查基线 | Git HEAD `9f696db`；`TSVLPManagerV1.sol`、相关 Hook 和规范文档按当前工作区内容审查 |
| 范围 | `TSVLPManagerV1`、`TSVHookV1`、Registry、直接结算库、固定 V4 `PoolManager` 相关路径及 LP 规范 |
| 结论 | 未确认可利用的 LP Manager 漏洞；发现已弃用存储槽、重复派生和可简化的防御检查，并发现规范与当前 ABI 不一致 |
| 验证 | 静态源码审阅；未运行测试或构建 |

## 执行摘要

LP 主流程在当前实现中是闭合的：入口限制资格、仓位所有权和池状态；LP Manager 保存本次操作上下文后调用 PoolManager；Hook 把 PoolManager 的流动性回调与该上下文逐项匹配；Manager 按实际 `callerDelta` 检查边界并直接结算；只有成功后才更新流动性或销毁 Receipt。

LP 的 `activeContext` 不能照搬 Router 的结论直接移除。Hook 的 `beforeAddLiquidity` / `beforeRemoveLiquidity` 需要验证当前池、tick、salt、方向和操作类型；当前 Hook 通过 `activeLPContext()` 读取这些信息，且 `hookData` 必须为空。移除它需要改造 Hook 的授权/上下文传递方式。`activeRequestHash` 也覆盖 callback 中的 `positionId`、模式及 LP bounds，保护实际付款/收款限制；建议保留。

可以优先清理两个已弃用的存储槽和 `forceExit` 返回后的重复负 delta 检查。LP 操作还会重复计算 PoolId；这是小幅 Gas 优化。当前规范仍写着已不存在的 `nextOperationNonce`、`operationId` 与 `activeLPContext(bytes32)`，应在 ABI 对外冻结前修正。

## Review 项

### 1. 规范仍描述旧 LP operationId ABI

当前代码没有 `nextOperationNonce` getter，也没有 `operationId`。Hook data 为空，`activeLPContext()` 无参数；源码改用 Manager 存储的上下文和 `activeRequestHash` 校验本次 PoolManager 回调。规范仍记录旧字段、旧 getter 签名和 `hookData = abi.encode(operationId)`，系统总览还把不存在的 `nextOperationNonce()` 列为查询接口。

这是 ABI/集成文档问题，不是合约可利用漏洞；但调用方若按规范构造请求或集成 Hook，会与当前实现不匹配。应将 `LPContext`、回调数据、 getter 和部署/查询接口统一更新为当前源码。

位置：[TSVLPManagerV1.sol:192](../../src/v1/periphery/TSVLPManagerV1.sol#L192)、[TSVLPManagerV1.sol:228](../../src/v1/periphery/TSVLPManagerV1.sol#L228)、[TSVLPManagerV1.sol:260](../../src/v1/periphery/TSVLPManagerV1.sol#L260)、[CODING_SPEC_V1.md:193](../CODING_SPEC_V1.md#L193)、[SYSTEMS_OVERVIEW.md:191](../SYSTEMS_OVERVIEW.md#L191)。

### 2. 两个 `operationId` 遗留槽可在部署前删除

`__deprecatedNextOperationNonce` 和 `__deprecatedActiveOperationId` 从未读写，只作为旧实现的布局占位。当前实施状态文档说明合约尚未部署，因此无需为了旧代理存储兼容保留它们。删除会调整后续状态变量的 storage slot；只有确认没有已部署代理或需兼容的快照后才可做。

删除不会节省正常 LP 交易的运行时 Gas，因为这两个槽目前不被读写；收益是去掉误导性的遗留状态并让初始 storage layout 与当前设计一致。未来实现升级则仍应按 UUPS 规则追加存储。

位置：[TSVLPManagerV1.sol:51](../../src/v1/periphery/TSVLPManagerV1.sol#L51)、[TSVLPManagerV1.sol:55](../../src/v1/periphery/TSVLPManagerV1.sol#L55)、[IMPLEMENTATION_STATUS_V1.md:44](../IMPLEMENTATION_STATUS_V1.md#L44)。

### 3. `forceExit` 的返回 delta 负值检查重复

`unlockCallback()` 会先对 force-exit 的每条 delta 调用 `_settle()`。只要 delta 为负，`_settle()` 就因为 `mode == FORCE_EXIT` 立即回滚，不会结算；请求模式又由 `activeRequestHash` 绑定。因此 `_modify()` 只有在两个 delta 都非负时才能返回。`forceExit()` 随后对同一返回 delta 再检查 `< 0`，该检查在当前调用链中不可达。

可以删除 `delta.amount0() < 0 || delta.amount1() < 0` 检查。`TSVLPManagerV1.SettlementMismatch()` 与结算库的同名错误 selector 相同，现有测试用 Manager 声明解码结算库 revert；如保留该 ABI 别名可继续保留错误声明，它本身不产生运行时检查。真正负责阻止强退付款的边界应保留在 `_settle()`，因为它位于 Token 转账之前。

位置：[TSVLPManagerV1.sol:183](../../src/v1/periphery/TSVLPManagerV1.sol#L183)、[TSVLPManagerV1.sol:184](../../src/v1/periphery/TSVLPManagerV1.sol#L184)、[TSVLPManagerV1.sol:285](../../src/v1/periphery/TSVLPManagerV1.sol#L285)。

### 4. 常规 LP 操作重复计算 PoolId

`increaseLiquidity`、`decreaseLiquidity`、`collectFees` 和 `closePosition` 在 `_requireOwner()` 中通过 `p.key.toId()` 查询 `isTradable()`，随后 `_modify()` 再对相同的存储 PoolKey 调用 `toId()` 设置上下文。`openPosition()` 还分别在入口检查、`_modify()` 和最终事件中派生 PoolId。

可在外部入口计算一次并把 `poolId` 传给内部 helper；`openPosition()` 可复用同一局部值完成资格检查、上下文创建和事件输出。此项只减少本地哈希计算，不应为了省一次哈希而新增每仓位的 PoolId storage 字段。

**保留 Manager 和 Hook 各自的 `isTradable()` 检查。**Manager 检查让无效操作在调用 PoolManager 前失败；Hook 检查位于 PoolManager 的修改边界，即使 Manager 有入口门禁，也不能由此移除。

位置：[TSVLPManagerV1.sol:106](../../src/v1/periphery/TSVLPManagerV1.sol#L106)、[TSVLPManagerV1.sol:122](../../src/v1/periphery/TSVLPManagerV1.sol#L122)、[TSVLPManagerV1.sol:265](../../src/v1/periphery/TSVLPManagerV1.sol#L265)、[TSVLPManagerV1.sol:304](../../src/v1/periphery/TSVLPManagerV1.sol#L304)、[TSVHookV1.sol:100](../../src/v1/core/TSVHookV1.sol#L100)。

### 5. Hook 返回的 LPContext 含两个未使用字段

Hook 消费 `poolId`、tick 上下界、`salt`、`mode` 和 `liquidityDelta`；它不读取 `positionId` 或 `owner`。`positionId` 目前仍被 Manager 用作活跃上下文哨兵，所以不能简单从存储中删掉；但可以在 `activeLPContext()` 内继续检查该哨兵，同时返回 Hook 所需的窄结构，不把两个未使用字段编码返回给 Hook。

收益是减少 Hook↔Manager 查询时的 ABI 返回数据与解码工作，优先级低。若 getter 也被其他合约/链下工具使用，需先确认并同步 ABI；当前仓库只有 Hook 调用该 getter。

位置：[TSVTypes.sol:75](../../src/v1/types/TSVTypes.sol#L75)、[TSVLPManagerV1.sol:192](../../src/v1/periphery/TSVLPManagerV1.sol#L192)、[TSVHookV1.sol:215](../../src/v1/core/TSVHookV1.sol#L215)。

### 6. `int128.min` 输入边界会先转账再由 PoolManager 回滚

LP delta 的输入侧若为 `type(int128).min`，`_settle()` 扩展到 `int256` 后可以安全取绝对值，得到 `2^127`。只要 `maxPoolIn` 足够大，直接结算库会先执行 ERC-20 转账；随后 PoolManager 的 `settle()` 将正付款量转换为 `int128`，因超出 `int128.max` 回滚。原子性保证 Token 转账和整个 LP 操作回滚，没有资金损失，但会多走一次外部转账路径并让失败原因落在依赖合约。

可在 `_settle()` 的 Token 交互前显式拒绝 `delta == type(int128).min`。这属于更早失败和更清楚诊断，不是资金安全修复的必要条件。

位置：[TSVLPManagerV1.sol:284](../../src/v1/periphery/TSVLPManagerV1.sol#L284)、[TSVDirectSettlementLib.sol:18](../../src/v1/libraries/TSVDirectSettlementLib.sol#L18)、[PoolManager.sol:362](../../lib/v4-core/src/PoolManager.sol#L362)。

### 7. 池不可交易时也返回 `Unauthorized()`

`_requireUserPool()` 将“不具备 SBT 资格”和“池不可交易”合并成一个条件，并统一回滚 `Unauthorized()`。这会让已获资格用户面对暂停池时收到身份错误；合约已有 `InvalidPool()` 错误。拆成先检查资格、再检查可交易状态，可改善前端和运维诊断，成功路径仍然只调用一次每个 Registry getter。

这是错误语义问题，不会绕过资格或池门禁。若协议有意隐藏池状态，则应记录这是有意的错误归一化，而不是继续保留未使用的错误分类。

位置：[TSVLPManagerV1.sol:294](../../src/v1/periphery/TSVLPManagerV1.sol#L294)。

## 需要保留的逻辑

- `activeContext` 是当前 Hook LP 授权路径的输入。Hook 只允许 LP Manager 发起的回调，并通过当前上下文匹配 poolId、完整 PoolKey、ticks、salt、delta 和 add/remove 模式。删除这份上下文前，需要设计并审查替代传递机制；它与 Router 不被 Hook 读取的 Swap 上下文不同。
- `activeRequestHash` 覆盖整个 `ModifyRequest`，包括 `LPBounds`、模式和 `positionId`。Hook 上下文只核对部分字段，hash 让 `unlockCallback` 在付款前确认 PoolManager 返回的还是本次请求数据。固定 V4 实现会原样转发 unlock data，但移除此 hash 会弱化对替换/异常 PoolManager 改写 bounds 的防护；不建议仅为少一个 storage write/delete 就删掉。
- Hook 的 PoolKey 比对、`onlyPoolManager`、调用方和空 `hookData` 检查都处于 V4 回调安全边界，应保留。
- `_settle()` 中 `FORCE_EXIT` 禁止任何负 delta、每侧最低到账检查，以及转账前后精确余额校验应保留。强退可以在池停用/暂停时执行，但资产只能交付原 owner。
- `decreaseLiquidity()` 禁止减到零是有意规则：完整退出走 `closePosition()`，一次移除流动性并结清累计费用，最后 burn Receipt。
- `_requireOwner()` 同时核对内部 owner 和 Receipt owner 是状态一致性防护。Receipt 虽不可转让，这个校验仍能拒绝内部仓位与 NFT 状态意外分离的情形。
- `collectFees()` 的零手续费回滚、零 delta 也遵守调用者设置的最小输出，以及全交易原子回滚都是有意义的边界；不要把零值绕过成免费通过。

## 低优先级 API/业务语义

- `collectFees()` 复用完整 `LPBounds`，其中 `maxPoolIn0/1` 在当前固定 V4 行为下没有用途：流动性 delta 为零时本金 delta 为零、应收费用非负，Hook 也返回零 delta。通用 `_settle()` 仍允许非 `FORCE_EXIT` 模式按 `maxPoolIn` 付款。可以在 `COLLECT` 模式下拒绝负 delta，避免以后 Hook 行为变化时“领费”路径意外扣款；当前 fixed V4 路径中这不是可利用问题。
- `forceExit()` 要求非零 `evidenceHash`，但 `PositionClosed` 事件不含该哈希。调用交易数据本身仍保存入参；若事件索引器需要可直接查询的证据关联，应把哈希写入关闭事件或单独审计事件，否则可考虑删掉仅用于非零检查的参数。
- `openPosition()` 使用 `keccak256(chainid, manager, positionId)` 生成 salt。由于 `positionId` 在 Manager 内从 1 单调递增、V4 仓位还由 manager 地址和 pool/ticks 区分，`bytes32(positionId)` 已足以在该 Manager 内唯一；保留哈希则提供清楚的域分离。Gas 收益很小，属于偏简洁的可选调整，不建议为此改变已部署仓位 salt。
- `_requireUserPool()` 的短路条件先做 SBT，再查 `isTradable()`；这避免无资格调用者触发第二次 Registry/SBT 状态查询。不要为了分别返回错误而无条件并行读取两个检查。

## 建议顺序

1. 先修正 LP 规范与当前代码的 ABI/上下文描述。
2. 因尚未部署，移除两个弃用存储占位槽；同时删除 `forceExit()` 返回后的重复 delta 符号检查。
3. 若要继续压低 LP 操作 Gas，优先缓存单次 PoolId 计算；再评估缩窄 Hook 上下文返回结构。
4. 可选增加 `int128.min` 的结算前拒绝，并明确 `collectFees` 是否允许任何负 delta。

本报告是当前工作区源码的静态 Review，不代替独立安全审计或测试。本轮未修改 Solidity 源码，也未运行测试或构建。

# TSV V1 安全审计报告

| 项目 | 内容 |
|---|---|
| 日期 | 2026-10-01 |
| 分支 | main（仓库尚无提交） |
| 技术栈 | Solidity 0.8.26、Foundry、Uniswap v4、OpenZeppelin 5.5.0 |
| 模式 | Standard：源码审查、攻击面梳理、现有测试验证 |
| 风险判断 | HIGH；完成高危部署控制和中危资金保护后再考虑生产准入 |

## 执行摘要

- **发现 3 项条件性问题**：高危 1 项、中危 2 项；未确认无权限直接盗取普通 Swap/LP 资产的路径。
- **测试**：`forge test --force --summary` 编译成功，46 项通过，0 失败。
- **主要问题**：通用代理允许空初始化数据；已批准的可升级 ERC20 实现变化不会让准入失效；强制 LP 退出没有最小收款或价格偏离保护。
- **当前版本不能证明“没有资金漏洞”**。静态审查和本地测试不能替代目标链部署核验、模糊/不变量测试、fork 测试及独立审计。

优先处理：

1. 让所有 TSV 代理部署强制原子初始化，并核验线上每个代理的 authority、timelock 和实现地址。
2. 默认拒绝可升级代币；只有能持续校验实现版本并在升级后暂停交易时才允许准入。
3. 为强制退出增加基于可信价格或偏离阈值的保护，避免公开退出交易被夹击。

## 攻击面

| 入口 | 权限与信任边界 | 资金相关路径 |
|---|---|---|
| `TSVSwapRouterV1.swapExactInput/Output` | 本人调用或 EIP-712 授权调用者；SBT、nonce、截止时间、池准入校验 | Router → PoolManager 解锁 → Hook 记账 → ERC20 双向结算 |
| `TSVLPManagerV1` 开仓、调整、退出 | Receipt 持有人；强退需要专门角色 | Manager 代表 LP 持有 V4 仓位，资产结算给原持有人 |
| `TSVDataInboxV1.submit*` | 对应报告角色签名；EIP-712、sequence、reportId 和截止时间 | 影响市场状态、ADTV 与交易额度，不直接转移资产 |
| 治理与 UUPS 升级 | Business Authority、Timelock、Emergency Controller | 可改变准入、权限和合约实现，属于最高信任边界 |
| ERC20 与法律股数 Adapter | 资产发行方及准入管理员 | 决定真实转账行为、余额读取和股票数量记账 |

仓库没有 HTTP/API、文件上传或服务端 URL 请求入口；Solidity 外部入口按合约公开函数审查。

## 发现

| 编号 | 严重性 | 维度 | 位置 | CWE | 问题 |
|---|---|---|---|---|---|
| S-01 | HIGH（条件性，评分 4） | D3/D8 | `src/v1/deployment/TSVERC1967Proxy.sol:9` | CWE-665 | 通用代理可用空初始化数据部署，之后任何人都能先初始化并取得该代理治理权 |
| S-02 | MEDIUM（条件性，评分 1） | D8/D9 | `src/v1/core/TSVRegistryV1.sol:197-200,252-257` | CWE-693 | 可升级代币更换实现后 runtime codehash 不变，原准入仍有效 |
| S-03 | MEDIUM（条件性，评分 2） | D9 | `src/v1/periphery/TSVLPManagerV1.sol:178-192,283-284` | CWE-362 | 强制 LP 退出没有最小收款或价格偏离保护，可能被公开交易夹击 |

### S-01：可空初始化部署的代理可能被抢先接管

**位置：**`TSVERC1967Proxy` 构造函数第 9 行；各业务实现的 `initialize` 使用 `initializer`，但代理构造函数本身不要求传入初始化 calldata。OpenZeppelin `ERC1967Proxy` 在初始化 calldata 为空时只设置实现地址，不执行初始化调用。Hook 专用 factory 会拒绝空 calldata，但通用代理没有该限制。

**实际代码：**

~~~solidity
contract TSVERC1967Proxy is ERC1967Proxy {
    constructor(address implementation, bytes memory data) ERC1967Proxy(implementation, data) {}
}
~~~

**触发与影响：**若部署脚本先创建空初始化代理、随后再单独初始化，攻击者可在间隙调用公开 `initialize`，指定自己控制的 authority、timelock 和 controller。随后可取得代理治理及 UUPS 升级权；若目标是 Registry、LP Manager 等生产代理，攻击者可能更改准入或替换资金逻辑。

**评分：**未授权调用 `+3`，完全控制代理及资金逻辑 `+3`，依赖部署错误 `-2`，专用 Hook factory 的保护不覆盖通用代理 `+0`，合计 **4（HIGH）**。

**修复：**在通用代理构造函数中拒绝空初始化数据；所有生产代理在同一部署交易中初始化。部署后校验 implementation、authority、timelock、controller 及关键角色，发现未初始化实例时不要接入资金系统。

~~~solidity
error EmptyInitializationData();

constructor(address implementation, bytes memory data) ERC1967Proxy(implementation, data) {
    if (data.length == 0) revert EmptyInitializationData();
}
~~~

**验证：**新增空 calldata 部署应回滚的测试；对每种 TSV 代理验证部署后初始化状态与治理地址均符合部署清单。

### S-02：代理代币升级不会让准入失效

**位置：**Registry 注册及批准时只对 `userToken`、`poolCurrency` 比较 runtime codehash。`TokenConfig` 中虽然有 `userImplementationHash` 和 `poolImplementationHash`，当前准入路径没有校验这些字段；ERC-1967 代理升级实现通常不改变代理 runtime codehash。

**触发与影响：**一个代理 ERC20 获批后，其管理员升级实现。Registry 仍返回可交易状态，但新实现可能改变 `transfer`、`balanceOf`、`decimals` 或限制行为，使结算假设失效、交易冻结或造成资产/股票数量记账错误。该触发需要发行方或代理管理员权限；对任意不可升级 ERC20 不适用。

**评分：**代币管理员权限 `+1`，资金结算或可用性受影响 `+2`，需要特定代理资产与实现升级 `-2`，现有 runtime hash 检查可被代理实现槽绕过 `+0`，合计 **1（MEDIUM）**。

**修复：**默认只准入不可升级代币。若业务必须支持代理，明确支持的代理类型和实现读取方式；准入时保存实际实现地址/codehash，在每次可交易检查中核验，检测变化时先禁用资产并要求重新审查。只存代理 runtime codehash 不足以固定代币行为。

**验证：**用代理 Token 部署两个实现，升级后保持代理地址和 runtime codehash 不变；修复后必须使该资产不可交易，重新审查前 Swap/LP 加仓应回滚。

### S-03：强制 LP 退出缺少价格保护

**位置：**`forceExit` 构造空 `LPBounds` 并只设置 deadline；`_settle` 在 `minOut == 0` 时接受任何正数输出。普通 LP 退出可以传入最小输出，强退路径没有对应保护。

**触发与影响：**强退交易公开待执行时，具备交易资格的参与者可以先交易移动池价，再让强退移除仓位，随后反向交易或套利。强退会把被移除仓位的资产组合按被操纵后的池状态交给原持有人，可能令其承担损失。实现该路径还需要可用流动性、交易额度和足够低的价格操纵成本，因此是条件性 MEV 风险。

**评分：**具备 SBT 的普通参与者 `+2`，部分价值损失 `+2`，依赖公开强退及特定市场深度/额度 `-2`，强退没有价格保护 `+0`，合计 **2（MEDIUM）**。

**修复：**以可信 TWAP/价格源或最大价格偏离作为强退门槛；只靠强退调用者传入 `minOut` 不够，因为调用者可将其设为零。若退出时偏离超过门槛，应保持仓位并允许稍后重试，或使用受控的私有执行流程。

**验证：**在本地 V4 集成测试中先操纵价格再执行强退，超出阈值应回滚且仓位仍有效；阈值内执行应把资产交给原持有人。

## 已核对的有效控制

- Router 与 LP Manager 对 ERC20 付款方和 PoolManager/收款方均校验实际余额变化恰好等于名义金额；现有测试覆盖发送方额外扣费回滚。
- Hook 限定 PoolManager、Router、LP Manager 和已登记 PoolKey；直接从 PoolManager 发起 Swap 的测试回滚。
- Swap 校验实际输入/输出、精确输出完整交付、签名授权、deadline、nonce 和参与者资格。
- LP Receipt 禁止转让；常规退出需原持有人，强退资产也发送给记录的原持有人。
- 报告签名检查 signer 角色、EIP-712 域、递增 sequence、reportId 重放和提交截止时间。
- 法律股数转换的静态及 ERC-8056 multiplier 路径有对应单元测试；登记路径当前只接受直接 ERC20 结算。旧 issuer-wrapped settlement adapter 不在当前 Router/LP 的可达资金路径中。

这些控制不能替代代币发行方可信度、代理实现生命周期管理或强退价格保护。

## 覆盖矩阵

| 维度 | 状态 | 覆盖与限制 |
|---|---|---|
| D1 注入 | ⏭️ 跳过 | 无 SQL、命令执行、模板或解释器调用面 |
| D2 身份认证 | ✅ 已覆盖 | EIP-712 Swap/报告签名、时效、nonce、角色检查 |
| D3 授权 | ✅ 已覆盖 | Swap/LP owner、PoolManager callback、报告角色、治理与 UUPS 权限 |
| D4 反序列化 | ✅ 已覆盖 | 审查 ABI 解码与回调请求哈希绑定；未发现不可信任的复杂序列化对象入口 |
| D5 文件操作 | ⏭️ 跳过 | 合约无文件系统操作 |
| D6 SSRF | ⏭️ 跳过 | 合约无 HTTP/URL 请求 |
| D7 密码学 | ⚠️ 部分 | 审查 EIP-712、SignatureChecker、nonce 和报告重放；未做密钥/凭据模式扫描及完整日志敏感数据扫描 |
| D8 配置 | ✅ 已覆盖 | Foundry 编译配置、代理初始化、代币 runtime/implementation hash 准入逻辑 |
| D9 业务逻辑 | ✅ 已覆盖 | Swap、LP、双边结算、额度、日切、强退与动态股数转换 |
| D10 供应链 | ⚠️ 部分 | OpenZeppelin 5.5.0 有 soldeer.lock checksum；没有在线 CVE 核验。`lib/v4-core` 本地源码未锁定 Git commit |
| D11 恶意代码 | ⚠️ 部分 | 检查动态调用、代理升级、assembly、`selfdestruct`、`tx.origin`、外部 URL 等模式；未做完整独立恶意代码扫描 |

## 验证范围与发布限制

- `forge test --force --summary`：46 项通过，0 失败；编译器提示来自代理 payable fallback 及 OpenZeppelin ERC721 不可达分支，未见资金逻辑编译错误。
- 未运行模糊测试、不变量测试、形式化验证、链上 fork、真实发行方代理验证或部署演练。
- `foundry.toml` 从 `lib/v4-core/` 编译，但该目录在当前工作区未锁定为固定 Git commit；仓库目前也没有审计提交。审计结果只能对应这次本地文件状态，不能作为线上部署字节码证明。
- 未核对生产部署地址、角色持有人、发行方实现槽、强退执行流程或实际资产准入记录。

## 版本记录

| 版本 | 日期 | 变更 |
|---|---|---|
| v1.0 | 2026-10-01 | 对当前工作区进行源码与本地测试安全审查 |

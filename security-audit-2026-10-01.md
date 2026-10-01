# TSV V1 安全审计报告

| 项目 | 内容 |
|---|---|
| 日期 | 2026-10-01 |
| 分支 | main（仓库尚无提交） |
| 技术栈 | Solidity 0.8.26、Foundry、Uniswap v4、OpenZeppelin 5.5.0 |
| 模式 | Standard：源码审查、攻击面梳理、现有测试验证 |
| 风险判断 | MEDIUM；S-01、S-03 已修复；S-02 按运营监控控制接受 |

## 执行摘要

- **原审计发现 3 项条件性问题**：S-01 已修复；S-03 已为强退加入两侧最小收款检查；S-02 按用户决定由链下监控发现代币实现变化后触发 pause。
- **测试**：最新重构后 `forge test --force --summary` 编译成功，52 项通过，0 失败。
- **运营控制**：强退的两侧 raw `minPoolOut` 由运营调用方按执行时策略设定；隐私交易仍用于降低公开 mempool 的抢跑风险。
- **审查边界**：本报告的原始代码审计结论针对重构前源码；本次抽库、合并 SBT/Receipt 和隔离旧结算路径已完成编译、测试及部署尺寸核验，但尚未替代独立完整安全复审。V1 已明确采用全新六代理实例组，不复用旧 Router/LP/Receipt/SBT Adapter 地址；部署顺序、Hook 循环地址和 SBT 配置校验以[全新部署清单](docs/DEPLOYMENT_CHECKLIST_V1.md)为准。
- **本次审查不能证明“没有资金漏洞”**。静态审查和本地测试不能替代目标链部署核验、模糊/不变量测试、fork 测试及独立审计。

优先处理：

1. 部署时核验所有 TSV 代理已原子初始化，且 authority、timelock 和实现地址符合清单。
2. 确保链下代币实现监控可及时触发资产 pause，并定期演练告警到暂停流程。
3. 强退运营方按当时估值与风险政策设置两侧最小收款，并使用隐私交易；固定 V4 源码依赖版本以保证部署可复现。
4. 发布前验证 Registry 已配置 SBT；未配置时应得到 `SbtNotConfigured()`，不能把空地址配置当作“无资格用户”处理。

## 攻击面

| 入口 | 权限与信任边界 | 资金相关路径 |
|---|---|---|
| `TSVSwapRouterV1.swapExactInput/Output` | 本人调用或 EIP-712 授权调用者；SBT、nonce、截止时间、池准入校验 | Router → PoolManager 解锁 → Hook 记账 → ERC20 双向结算 |
| `TSVLPManagerV1` 开仓、调整、退出 | Receipt 持有人；强退需要专门角色 | Manager 代表 LP 持有 V4 仓位，资产结算给原持有人 |
| `TSVDataInboxV1.submit*` | `msg.sender` 直接持有对应报告角色；sequence、reportId 和截止时间 | 影响市场状态、ADTV 与交易额度，不直接转移资产；报告不使用 EIP-712 或签名参数 |
| 治理与 UUPS 升级 | Business Authority、Timelock、Emergency Controller | 可改变准入、权限和合约实现，属于最高信任边界 |
| ERC20 与法律股数 Adapter | 资产发行方及准入管理员 | 决定真实转账行为、余额读取和股票数量记账 |

仓库没有 HTTP/API、文件上传或服务端 URL 请求入口；Solidity 外部入口按合约公开函数审查。

## 发现

| 编号 | 严重性 | 维度 | 位置 | CWE | 问题 | 处置 |
|---|---|---|---|---|---|---|
| S-01 | HIGH（条件性，评分 4） | D3/D8 | `src/v1/deployment/TSVERC1967Proxy.sol:11-12` | CWE-665 | 修复前通用代理可用空初始化数据部署，之后任何人都能先初始化并取得该代理治理权 | 已修复：构造函数拒绝空数据；新增回归测试 |
| S-02 | MEDIUM（条件性，评分 1） | D8/D9 | `src/v1/core/TSVRegistryV1.sol:197-200,252-257` | CWE-693 | 可升级代币更换实现后 runtime codehash 不变，原准入仍有效 | 用户接受运营风险：链下监控变化并 pause |
| S-03 | MEDIUM（条件性，评分 2） | D9 | `src/v1/periphery/TSVLPManagerV1.sol:175-192,300-314` | CWE-362 | 修复前强制 LP 退出没有最小收款边界；边界数值仍由运营调用方设定 | 已修复：强退逐侧执行 raw `minPoolOut`；运营决定下限，隐私交易作为额外保护 |

### S-01（已修复）：可空初始化部署的代理可能被抢先接管

**修复前位置：**`TSVERC1967Proxy` 构造函数原第 9 行。各业务实现的 `initialize` 使用 `initializer`，但代理构造函数本身不要求传入初始化 calldata。OpenZeppelin `ERC1967Proxy` 在初始化 calldata 为空时只设置实现地址，不执行初始化调用。Hook 专用 factory 会拒绝空 calldata，但通用代理没有该限制。

**当前处置：**已在代理构造函数中拒绝空 `data`，并更新集成测试的代理 runtime-code 安装方式，避免测试再部署空初始化代理。

**修复前代码：**

~~~solidity
contract TSVERC1967Proxy is ERC1967Proxy {
    constructor(address implementation, bytes memory data) ERC1967Proxy(implementation, data) {}
}
~~~

**触发与影响：**若部署脚本先创建空初始化代理、随后再单独初始化，攻击者可在间隙调用公开 `initialize`，指定自己控制的 authority、timelock 和 controller。随后可取得代理治理及 UUPS 升级权；若目标是 Registry、LP Manager 等生产代理，攻击者可能更改准入或替换资金逻辑。

**评分：**未授权调用 `+3`，完全控制代理及资金逻辑 `+3`，依赖部署错误 `-2`，专用 Hook factory 的保护不覆盖通用代理 `+0`，合计 **4（HIGH）**。

**修复：**通用代理构造函数现已拒绝空初始化数据；生产部署仍应在同一交易中初始化，并校验 implementation、authority、timelock、controller 及关键角色。

~~~solidity
error EmptyInitializationData();

constructor(address implementation, bytes memory data) ERC1967Proxy(implementation, data) {
    if (data.length == 0) revert EmptyInitializationData();
}
~~~

**验证：**`testProxyRejectsEmptyInitializationData` 断言空 calldata 部署回滚；Hook factory 与本地协议集成测试均通过。生产部署核验仍须检查治理地址是否符合部署清单。

### S-02：代理代币升级不会让准入失效

**位置：**Registry 注册及批准时只对 `userToken`、`poolCurrency` 比较 runtime codehash。`TokenConfig` 中虽然有 `userImplementationHash` 和 `poolImplementationHash`，当前准入路径没有校验这些字段；ERC-1967 代理升级实现通常不改变代理 runtime codehash。

**触发与影响：**一个代理 ERC20 获批后，其管理员升级实现。Registry 仍返回可交易状态，但新实现可能改变 `transfer`、`balanceOf`、`decimals` 或限制行为，使结算假设失效、交易冻结或造成资产/股票数量记账错误。该触发需要发行方或代理管理员权限；对任意不可升级 ERC20 不适用。

**处置：**按用户决定，本次不修改链上准入逻辑。运营假设是链下持续监控实现变化，并在检测到变化时及时暂停对应资产；若监控或暂停延迟，链上代码本身不会自动阻止继续交易。

**评分：**代币管理员权限 `+1`，资金结算或可用性受影响 `+2`，需要特定代理资产与实现升级 `-2`，现有 runtime hash 检查可被代理实现槽绕过 `+0`，合计 **1（MEDIUM）**。

**运营验证：**演练代理实现升级告警到资产 pause 的全过程；确认 pause 生效后，新 Swap 和 LP 加仓回滚，并记录监控延迟和告警责任人。

### S-03（已修复）：强制 LP 退出缺少最小收款边界

**审计时的问题：**`forceExit` 构造空 `LPBounds` 并只设置 deadline；`_settle` 在 `minOut == 0` 时接受任何正数输出。普通 LP 退出可以传入最小输出，强退路径没有对应保护。

**触发与影响：**强退交易公开待执行时，具备交易资格的参与者可以先交易移动池价，再让强退移除仓位，随后反向交易或套利。强退会把被移除仓位的资产组合按被操纵后的池状态交给原持有人，可能令其承担损失。实现该路径还需要可用流动性、交易额度和足够低的价格操纵成本，因此是条件性 MEV 风险。

**修复：**`forceExit` 现在要求调用方传入 `minPoolOut0` 和 `minPoolOut1`，写入 LP bounds，并在结算时逐侧检查实际到账。任一侧低于指定值（包括该侧 delta 为零但下限非零）都会回滚整笔交易，仓位、Receipt、余额和额度状态保持不变。测试分别覆盖两侧下限失败及原子回滚。

具体下限由运营调用方根据执行时策略确定；合约不提供可信价格源或最大价格偏离校验，因此若下限设得过低（包括设为零），保护效果也相应有限。隐私交易是降低公开 mempool 抢跑风险的额外措施，不替代 minOut 检查。

**原始评分：**具备 SBT 的普通参与者 `+2`，部分价值损失 `+2`，依赖公开强退及特定市场深度/额度 `-2`，强退没有价格保护 `+0`，合计 **2（MEDIUM）**。当前代码增加了调用方指定的 minOut；残余风险来自运营设置的边界可能过低，且没有可信价格偏离校验。

**验证：**`testForceExitEnforcesBothMinimumOutputsAtomically` 分别将一侧下限设为不可满足值，确认两次均回滚且仓位与资产状态不变；集成测试也覆盖满足边界的成功强退。运营仍应演练隐私交易提交与有界失败重试流程。

## 已核对的有效控制

- Router 与 LP Manager 对 ERC20 付款方和 PoolManager/收款方均校验实际余额变化恰好等于名义金额；现有测试覆盖发送方额外扣费回滚。
- Hook 限定 PoolManager、Router、LP Manager 和已登记 PoolKey；直接从 PoolManager 发起 Swap 的测试回滚。
- Swap 校验实际输入/输出、精确输出完整交付、签名授权、deadline、nonce 和参与者资格。
- LP Receipt 禁止转让；常规退出需原持有人，强退资产也发送给记录的原持有人。
- 报告入口检查 `msg.sender` 角色、递增 sequence、reportId 重放和提交截止时间；Router 用户授权仍单独使用 EIP-712/ERC-1271。
- 法律股数转换的静态及 ERC-8056 multiplier 路径有对应单元测试；登记路径当前只接受直接 ERC20 结算。旧 issuer-wrapped settlement adapter 不在当前 Router/LP 的可达资金路径中。

S-02 运营控制依赖链下监控及时性；强退 minOut 是链上强制执行的调用参数，但具体风险下限由运营设定。隐私交易通道不能替代链上边界检查。

## 覆盖矩阵

| 维度 | 状态 | 覆盖与限制 |
|---|---|---|
| D1 注入 | ⏭️ 跳过 | 无 SQL、命令执行、模板或解释器调用面 |
| D2 身份认证 | ✅ 已覆盖 | EIP-712 Swap 授权、报告直接角色检查、时效、nonce |
| D3 授权 | ✅ 已覆盖 | Swap/LP owner、PoolManager callback、报告角色、治理与 UUPS 权限 |
| D4 反序列化 | ✅ 已覆盖 | 审查 ABI 解码与回调请求哈希绑定；未发现不可信任的复杂序列化对象入口 |
| D5 文件操作 | ⏭️ 跳过 | 合约无文件系统操作 |
| D6 SSRF | ⏭️ 跳过 | 合约无 HTTP/URL 请求 |
| D7 密码学 | ⚠️ 部分 | 审查 Router EIP-712、SignatureChecker、nonce 和报告重放；DataInbox 不再有报告验签；未做密钥/凭据模式扫描及完整日志敏感数据扫描 |
| D8 配置 | ✅ 已覆盖 | Foundry 编译配置、代理初始化、代币 runtime/implementation hash 准入逻辑 |
| D9 业务逻辑 | ✅ 已覆盖 | Swap、LP、双边结算、额度、日切、强退与动态股数转换 |
| D10 供应链 | ⚠️ 部分 | OpenZeppelin 5.5.0 有 soldeer.lock checksum；没有在线 CVE 核验。`lib/v4-core` 本地源码未锁定 Git commit |
| D11 恶意代码 | ⚠️ 部分 | 检查动态调用、代理升级、assembly、`selfdestruct`、`tx.origin`、外部 URL 等模式；未做完整独立恶意代码扫描 |

## 验证范围与发布限制

- `forge test --force --summary`：52 项通过，0 失败；编译器提示来自代理 payable fallback 及 OpenZeppelin ERC721 不可达分支，未见资金逻辑编译错误。
- 未运行模糊测试、不变量测试、形式化验证、链上 fork、真实发行方代理验证或部署演练。
- `foundry.toml` 从 `lib/v4-core/` 编译，但该目录在当前工作区未锁定为固定 Git commit；仓库目前也没有审计提交。审计结果只能对应这次本地文件状态，不能作为线上部署字节码证明。
- 未核对生产部署地址、角色持有人、发行方实现槽、强退执行流程或实际资产准入记录。

## 版本记录

| 版本 | 日期 | 变更 |
|---|---|---|
| v1.0 | 2026-10-01 | 对当前工作区进行源码与本地测试安全审查 |
| v1.1 | 2026-10-01 | 修复 S-01 并验证；记录 S-02/S-03 的运营风险接受决定 |
| v1.2 | 2026-10-01 | 为 `forceExit` 增加两侧 raw minOut 及原子回滚测试；同步架构、接口、测试规范 |
| v1.3 | 2026-10-01 | 反映抽库与代理合并后的测试数及审查边界；该重构尚未单独进行完整安全复审 |

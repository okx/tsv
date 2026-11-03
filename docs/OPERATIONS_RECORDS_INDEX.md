# TSV 运维工具与历史记录索引

本次归档以 `main` 的 `a8bfc93aa2cf40142e6511e5069d90f65b59f420` 为基础，补充此前未入库的工具和操作证据。`src/v1` 业务合约不在此次变更范围内。

## 工具

- `sdk/python/tsv_xlayer_sdk/client.py`：正确解析本地配置的引号和行尾注释，拒绝多余参数；错误内容经过转义时仍对其中的签名值脱敏。
- `sdk/python/tests/test_local_env.py`：配置解析及错误脱敏的回归测试。
- `lib/TestToken/securitize-disperse/`：独立的 ERC-20 分红 Mock，10 分钟防重复窗口，包含权限、原子付款、事件和资金守恒测试。它不是 Securitize 官方实现。
- `script/xlayer/WithdrawLiquidityTSV.s.sol`：撤出签名人持有的相应流动性。
- `script/xlayer/BurnZeroLiquidityTSV.s.sol`：销毁签名人持有的空仓位。
- `script/xlayer/BurnAndDelistTSVPools.s.sol`：销毁空仓位，并在计数归零后下市池。
- `script/xlayer/ForceExitAndDelistZeroLiquidityTSV.s.sol`：对选定的他人空仓位执行强退并下市池。该脚本可能为操作人授予并保留 `FORCE_EXIT_ADMIN_ROLE`，使用前须核对这一永久角色变更。

这些脚本有链上写入能力。构建或测试不等于广播授权；实际使用时仍应确认目标、参数和签名人，并先模拟交易。

## MCP 成功部署记录

| 内容 | 路径 |
| --- | --- |
| MCP 成功部署的请求、最终状态和链上回执 | [deployments/tsv-mcp](deployments/tsv-mcp/) |
| pre / prod 合约地址清单 | [deployment](../deployment/README.md) |
| MCP 成功部署合约的登记资料与 ABI | [production contracts](../deployment/prod/contracts/) |
| 后端监听池和查询 W/U 的接口说明 | [POOL_MONITORING_AND_WU_LOOKUP_V1.md](POOL_MONITORING_AND_WU_LOOKUP_V1.md) |

部署流程见 [tsv-mcp-deploy Skill](../.agents/skills/tsv-mcp-deploy/SKILL.md)。deployments 仅保留已成功的 MCP EOA 创建操作及其证据；失败、等待、计划、重试过程和其他渠道部署均不保留。审计及 review 报告另行管理。每个 run 的 SHA256SUMS.json 对应当前归档文件。

## 链上记录与模拟

| 内容 | 路径 |
| --- | --- |
| 预发五个 TSV 代理的操作历史 | [index.html](../outputs/tsv-operation-history-20261030/index.html) |
| 流动性盘点 | [summary.json](../outputs/tsv-liquidity-inspection-20261029/summary.json) |
| 全部撤资回执与到账核验 | [summary.json](../outputs/tsv-withdraw-all-20261029/summary.json) |
| Mock 分红测试、回收及再次分发 | [summary.json](../outputs/tsv-disperse-test-20261030/summary.json) |
| 2026-11-01 预发 SBT 发放 | [verified-result.json](../outputs/sbt-20261101-1337/verified-result.json) |
| 2026-11-02 四人各 0.1 USDC 分发 | [summary.json](../outputs/usdc-dividend-four-20261102/summary.json) |
| 生产 W 验证与可用性 | [readiness.html](../outputs/production-w-readiness-20261102/readiness.html) |
| 发行方持有准入与授权交易 | [report.html](../outputs/issuer-holding-allowlist-20261102/report.html) |
| RWT 全量卖出的条件化报价（未广播） | [summary.json](../outputs/rwt-sale-quote-20261102/summary.json) |
| 生产合约的条件化分叉流程测试 | [report.html](../outputs/tsv-production-pool-simulation-20261031/report.html) |

上述文件均为固定时间或区块的历史记录。生产 W 的初查与后续回查保留在同一目录，每个 JSON 自身的区块号为准；不得将报告日期理解为实时状态。分叉测试中的身份、资金和管理操作假设只在本地生效，不能作为生产已完成配置的证据。

预发操作历史的 818 份原始 RPC 文件集中在 `raw-records.json`，保留逐文件原文、相对路径和 SHA-256。HTML 可直接查看，运行 `restore_raw_records.py` 可无损恢复原目录；恢复工具拒绝覆盖不同内容的文件。

## 依赖版本

`lib/dex-adapters` 仅指向已存在的远程提交 `f8db6a29c548106f3172d211e54a782f7bbc802f`。此次不提交或推送 DEX 子仓库的本地补丁。

## 验证入口

```sh
PYTHONPATH=sdk/python python3 -m unittest discover -s sdk/python/tests -v
forge test --root lib/TestToken/securitize-disperse -vv
```

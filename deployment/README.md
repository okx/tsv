# TSV 合约地址

所有环境的合约地址清单统一放在本目录：

| 环境 | 地址清单 | 核验依据 |
| --- | --- | --- |
| pre（X Layer 主网预发） | [pre/addresses.json](pre/addresses.json) | [chain-snapshot.json](pre/chain-snapshot.json) |
| prod（X Layer 主网生产） | [prod/addresses.json](prod/addresses.json) | [chain-snapshot.json](prod/chain-snapshot.json) |

两套环境均为 Chain ID 196，pre 不是测试网。`proxies` 为业务入口，`implementations` 为固定核验区块的实际实现，`libraries`、`factories`、`dependencies` 和资产/Adapter 分组分别维护。已有历史配置或未采用部署必须明确标注，不能冒充当前绑定或当前实现。公共地址本身不表示业务角色或交易权限已经配置完成。

核验范围以每份清单的 `verification` 和来源说明为准：当前实现与 Registry 绑定来自固定区块回读；代币、外部集成及历史记录来自所列存档，不把所有历史地址宣称为最新已启用配置。pre 的实现源码 commit 尚未由本次地址整理确认，保留为 null；prod 的初始发布 commit 见清单，不能将当前 main 的 commit 当作已部署版本。

生产初始发布的冻结地址位于 [prod/releases/20261029-mcp-addresses.json](prod/releases/20261029-mcp-addresses.json)，原 MCP 部署合约登记资料与 ABI 位于 [prod/contracts/](prod/contracts/)。这些历史登记资料描述其部署时点，不随代理以后升级自动变成新实现资料。

部署过程、完整 MCP 请求、最终状态、交易回执及核验记录位于 [docs/deployments/](../docs/deployments/tsv-mcp/README.md)。过程原文包含地址以便核对，但 docs 不再维护独立地址汇总表。

旧预发业务操作流水迁至 [docs/operations/xlayer-pre-20261015.md](../docs/operations/xlayer-pre-20261015.md)。脚本中的运行配置用于执行输入，不因本次文档整理自动改写；与清单冲突时必须核对目标和链上绑定后再执行。

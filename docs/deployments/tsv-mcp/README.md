# MCP 成功部署记录

本目录只保存已成功上链的 MCP EOA 创建操作及对应证据，不包含失败、待审批、计划、重试过程、审计报告或其他渠道部署。

| 记录 | 成功交易 | 内容 |
| --- | ---: | --- |
| [20261029-production-main-a8bfc93](runs/20261029-production-main-a8bfc93/manifest.json) | 14 | 核心库、Factory、实现和代理；不包含独立渠道创建的 Hook proxy |
| [20261030-legal-share-adapters](runs/20261030-legal-share-adapters/manifest.json) | 6 | MSTR、BTGO、SECZ 各两份 Adapter；第一份作为 canonical，另一份标记为 unused duplicate |

每批保留实际提交的完整 `request.json` 和最终成功状态 `status.json`。交易文件包含 input、回执及运行时代码或核验结果；UUID、hash、地址可与 manifest 逐项关联。重复部署同样成功上链，因此保留，并明确其用途。

合约地址统一维护于 [deployment/pre](../../../deployment/pre/addresses.json) 和 [deployment/prod](../../../deployment/prod/addresses.json)，合约登记资料及 ABI 位于 [deployment/prod/contracts](../../../deployment/prod/contracts/)。本目录只保存部署过程证据；请求、回执和 manifest 中的地址属于历史证据，不作为独立当前地址表。

每个 run 的 `SHA256SUMS.json` 为当前归档文件生成摘要，不包含自身。校验示例：

```sh
python3 .agents/skills/tsv-mcp-deploy/scripts/validate_records.py docs/deployments/tsv-mcp/runs/20261029-production-main-a8bfc93
python3 .agents/skills/tsv-mcp-deploy/scripts/validate_records.py docs/deployments/tsv-mcp/runs/20261030-legal-share-adapters
```

后续部署流程见 内部运维工具（不作为公开仓库依赖）。

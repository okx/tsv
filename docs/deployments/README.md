# TSV 部署说明

main 保留公开部署步骤、构建工具、ABI 和合约地址清单。MCP 使用方法、提交请求、审批状态、完整回执、操作日志及做市运行工具维护于 `ops/deployment`。

## 发布和部署顺序

1. 在 main 完成合约修改和验证，固定完整 source commit。
2. 从该 commit 创建 `release/prod/<version>-<YYYYMMDD>` 分支并冻结。分支名称和日期由实际发布决定，不代表已经部署。
3. 在运维分支同步该 source commit，保留运维专属文件，按同一编译配置构建。同步方法见 [分支职责](../REPOSITORY_BRANCHES.md)。
4. 按 [部署准备清单](../DEPLOYMENT_CHECKLIST_V1.md) 确定依赖地址、构造参数、初始化参数、角色与链接库，完成模拟后执行部署。
5. 将完整请求、最终状态、交易 hash、回执和核验结果记录在运维分支。将经核验的地址与版本信息通过单独 MR 更新到 main 的 [deployment/](../../deployment/README.md)。

部署后仍需核验实现绑定、角色、组件绑定、资产准入和池配置；创建 release 分支或合约部署成功不等于业务已可用。ABI 与存储布局必须来自目标发布的构建，不能直接用当前 main 快照替代历史版本。

## 历史证据

本次分离前的操作记录固定保留在 `ops/deployment` 的 commit `298ee17bd657a7fb57106b19c3a0a24628226320`：

- `docs/deployments/tsv-mcp/runs/`：成功 MCP 部署的请求、最终状态、回执与核验记录。
- `outputs/`：历史操作、查询、模拟、分红和做市工具。
- `.agents/skills/tsv-mcp-deploy/`：MCP 操作流程和记录校验工具。
- `deployment/prod/releases/`：历史部署的冻结地址和版本记录。
- `deployment/prod/contracts/`：历史合约登记资料和部署 ABI。
- `deployment/pre/chain-snapshot.json`、`deployment/prod/chain-snapshot.json`：固定区块的链上读取证据。

以上为归档位置，不是 main 中的文件链接。合约地址统一见 [pre](../../deployment/pre/addresses.json) 和 [prod](../../deployment/prod/addresses.json)。历史登记 ABI 和链上快照由上述固定 commit 归档，当前源码 ABI 见 [artifacts/](../artifacts/README.md)。

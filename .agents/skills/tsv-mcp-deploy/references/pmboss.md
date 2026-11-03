# PMBoss 请求与历史证据

当前可发现的工具名：`mcp__pmboss__create_evm_contract_deployment_task` 和 `mcp__pmboss__query_evm_contract_deployment_task_status`。调用前重新读取其 schema；工具能力可能变化。

历史成功提交的业务 JSON 顶层为 `deptName` 和 `tasks`，没有额外的 `request` 包裹。`deptName` 本次使用 `Dex`。当前暴露的创建工具 schema 只声明 `tasks`，未声明 `deptName`：未来实际提交前须核实工具如何传递部门信息。若无法满足必需字段，报告接口差异，不能臆造参数、默默丢弃字段或声称已提交完整 JSON。

任务的字段形状如下；占位值须来自本次参数、当前编译结果与有效审批，不能直接发送示例。

```json
{
  "deptName": "Dex",
  "tasks": [{
    "name": "<run-contract>",
    "desc": "<commit and decoded constructor purpose>",
    "chain_id": 196,
    "calldata": "<creation bytecode plus constructor args>",
    "gas_limit": 1000000,
    "privilege_address": "<authorized deployer>",
    "signatures": [{"approval_address": "<configured approver>", "signature": "<approval value>"}],
    "value": "0",
    "uuid": "<fresh UUID per task per new submission>"
  }]
}
```

`gas_limit` 必须按当前模拟估算；196 只是本仓库 X Layer 主网历史实例。历史经用户指定的空审批 signature 不构成未来请求的有效审批证明；以当前工具要求、用户授权和平台状态为准。

状态查询输入是 `{"uuid":"<original submitted uuid>"}`。历史最终成功状态为 `TASK_BROADCAST_SUCCESS_AND_TRANSACTION_SUCCESS`（数值 11），且 `contract_address` 可能为空，应从链上 receipt 获取创建地址。数值和文案必须以当前真实响应为准。

可参考仓库成功记录：

- `docs/deployments/tsv-mcp/runs/20261029-production-main-a8bfc93/`：14 笔核心库、Factory、实现与代理的成功 EOA 创建。
- `docs/deployments/tsv-mcp/runs/20261030-legal-share-adapters/`：6 笔成功 Adapter 创建，其中 3 笔重复。每批 JSON 与交易 input 可逐项核对。

这些是历史证据，不是下一次部署的参数模板。提交和查询使用 MCP；链上核验使用公开 RPC，不加载本地签名私钥。

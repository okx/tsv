---
name: tsv-mcp-deploy
description: 使用 PMBoss MCP 构建、提交并核验 TSV 合约的 EOA 创建部署，归档成功部署的请求、状态和链上证据。适用于 TSV 首次部署或升级实现部署，不执行 Factory 调用、业务配置或代理升级。
---

# TSV MCP 部署

先确认本次已授权的网络、源码版本、部署范围、部署账户与初始管理员；沿用会话中已确认的参数。固定完整 commit 和依赖 gitlink，以该版本源码和 ABI 决定构造参数，不照搬历史地址。

## 构建与依赖

- 在独立干净 worktree 构建，记录 solc、优化、viaIR、EVM、metadata 设置、ABI 和库链接。先部署不依赖其他新地址的合约；链上确认后，才能用实际地址构建下一批。
- PMBoss 此流程只做 EOA CREATE。`calldata` 是 creation bytecode 加 ABI 编码构造参数，不是 runtime bytecode 或普通方法 calldata。代理构造内的 initialize 属于同一创建交易。
- 批量 tasks 各自部署、各自状态，不保证按数组顺序执行或整批原子成功。不要在一批里放尚未确认地址的依赖。批次数量随当前版本依赖图变化。
- 区分部署人、合约 owner、Registry 初始管理员及升级角色，按构造参数和初始化代码确定归属。
- 用目标网络 RPC 对完整创建 input 模拟和估算 gas，核对费用、账户余额和链 ID；链接地址或构造参数改变后重新构建。

## 提交与状态

提交前阅读 [PMBoss 请求说明](references/pmboss.md)，通过工具发现读取当前接口 schema。使用 `create_evm_contract_deployment_task`，按 uuid 使用 `query_evm_contract_deployment_task_status` 查询。只在用户授权范围内提交，不因加载此 Skill 自动执行部署。

每次新提交前，每个任务生成新的 UUID（例如 Python `uuid.uuid4()`）；查询与核对仍使用已提交的原 UUID。先保存实际提交 JSON，再调用工具。不得只保存摘要而丢失完整 calldata。

HTTP 500、审批存在、任务暂不存在或响应丢失均不能证明没有部署。保留原 UUID 在工作目录核对后台任务、发送方 nonce 和链上交易；结果不明时停止重发，向用户报告。仅在确认未执行且本次重试已获授权时生成新 UUID，避免历史中出现过的重复部署。部分成功时只处理未完成项。

## 成功标准与归档

工具接受任务不代表部署成功。逐项核对最终状态、交易 hash、目标链、from、to=null、input 与请求一致、receipt.status=1、contractAddress、非空 runtime code、库和 immutable 参数。代理另核对实现槽及 initialize 的读回结果、角色归属；记录核验区块和确认数，不把部署成功写成业务已配置完成。

`docs/deployments/tsv-mcp/runs/<date>-<scope>-<commit>/` 只保存成功的 MCP 部署：

- `manifest.json`：固定版本/构建信息、部署来源、任务 UUID、hash、地址、用途与核验结果。
- `batch-*/request.json`：实际提交的完整 JSON；`status.json`：最终成功状态原文。请求批次若部分成功，只归档成功任务并注明是从原请求提取的子集，不能称为完整原请求。
- `transactions/<hash>.json`：交易、receipt、runtime 或核验结果；合约 ABI 和必要登记资料。
- `SHA256SUMS.json`：当前归档文件相对路径及 SHA-256，不包含自身。

失败、等待审批、计划、轮询中间状态、重试过程、Lark 通知、审计/review 和非 MCP 交易不进入 deployments。执行过程可在本地临时工作目录保留待核对信息，完成后不随成功记录提交。成功但重复的部署仍须记录，并注明 canonical/unused duplicate，不能遗漏真实交易。

用 `python3 .agents/skills/tsv-mcp-deploy/scripts/validate_records.py <run-dir>` 校验归档。该脚本检查现有证据的一致性，不代替 RPC 链上核验。不得记录签名私钥、API 凭据或带鉴权的 RPC URL。

## TSV 边界

Hook proxy 需 Factory CREATE2 权限位地址，不能伪装为本 MCP 的 EOA 创建。为用户提供从当前 Factory ABI 得到的 implementation、initData、salt、预测地址和调用 calldata，交由独立授权渠道执行；其交易不混入 MCP 成功部署归档。

升级实现部署应重新链接新版库；部署新库本身不会让旧实现改用它。代理升级、创建 W、bindComponents、角色、SBT、资产准入、额度和建池属于单独操作。完成时说明已部署内容与后续操作，不将其自动包含在部署授权中。

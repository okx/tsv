# TSV MCP 部署全过程留痕

状态：仅建立计划与记录规范，尚未选择部署链、源码版本、部署账户及管理员地址，未调用 MCP 创建部署任务，未广播交易。

## 当前范围

沿用本次讨论的口径：15 个直接创建任务，按依赖分为 5 批；另有 1 次调用 HookProxyFactory 创建 Hook proxy。不包括创建 W，不包括资产登记、业务角色授权、额度及建池配置。代理构造时嵌入的 initialize 属于部署本身，必须记录。PoolManager、Permit2、WETH/WOKB、Descriptor、SBT、U 和 Issuer Checker 等外部依赖需记录其实际地址及验证依据，但不在此计划中新部署。

当前部署 MCP 的 create 工具只提交创建任务，tasks 数组不代表批内按顺序执行；每项任务都有独立 uuid、审批签名和状态。Hook Factory 的普通调用需要可用的交易执行渠道，不能伪装成直接创建任务。本规范不假定已经存在该普通调用工具。

## 每次部署使用独立记录目录

```text
runs/<run-id>/
  manifest.json                 固定源码、网络、依赖、部署人、管理员和最终地址
  plan.json                     本次采用的任务图、5批依赖及排除范围
  events.jsonl                  按时间追加事件，不覆盖历史状态
  approvals/                    审批记录引用、签名地址、审批内容与摘要
  requests/<uuid>.json          每项请求的可审阅参数与规范化摘要
  responses/<uuid>/<time>.json  创建响应及每次状态查询的经过筛选的响应
  transactions/<txhash>.json    实际交易内容和回执
  verification/<task-id>.json   部署地址、字节码、代理、初始化、权限的核对证据
  summary.md                    每批结果、失败/重试、最终合约及权限对照
  checksums.sha256              归档文件的 SHA-256 摘要
```

模板包含空值，不得把模板当作已审批、已部署或链上已验证的证据。

## 每项任务必须记录的阶段

1. **构建固定**：选择实际使用的 audit 修复线或 main-audit 的完整 commit；记录每个 submodule gitlink、编译器完整版本、优化/viaIR/EVM 设置、源码树是否干净、ABI/creation bytecode/库链接/immutable 参数及对应 hash。不能用分支名替代 commit。
2. **请求准备**：在调用 MCP 前写入该项 uuid、所属批次、依赖、chain_id、privilege_address、gas/value、完整 creation calldata、构造参数和 initializer 的解码说明及 hash。明确预期 DEFAULT_ADMIN/UPGRADE_ADMIN，不能默认等于部署交易发送方。
3. **审批依据**：记录审批单或平台引用、审批地址、审批时间、被批准内容的精确摘要和审批结果。完整审批签名如只在平台保存，记录引用与摘要，不虚构已归档原文。参数更改须重新关联相应审批，不能将旧审批当作新请求的审批。
4. **MCP 提交及查询**：保存实际调用时间、工具名、输入摘要和任务响应；记录每次按 uuid 查询的原始状态及已识别含义。状态字段以真实工具返回为准，不臆造平台任务 ID、审批字段或返回地址字段。
5. **链上确认**：任务提交成功不等于部署成功。记录 chainId、from、to/null、nonce、交易 input/value、tx hash、receipt.status、blockNumber/blockHash、gasUsed、最终创建地址和目标链采用的确认/最终性标准。区块变化或 receipt 被移除时更新日志并重新核验。
6. **链上核验**：核对实际代码与构建版本，读取 proxy 的 tsvImplementation、各组件 immutable/Registry getter，核对 initialize 的实际效果，以及 Registry 的 DEFAULT_ADMIN_ROLE/UPGRADE_ADMIN_ROLE 归属。记录链上读数所在区块；未初始化业务角色或未配置业务必须明确标记为未执行，不以部署成功宣称系统已可交易。
7. **批次归档**：本批依赖合约均成功且核验通过后，才能使用其实际地址生成下一批参数；保留成功与失败项明细。库链接和含地址构造参数发生变化时重新生成 calldata/hash/审批记录。

## Hook proxy 单独记录

记录 HookFactory 地址及 codehash、Hook implementation、完整 initData、salt、initCodeHash、预测地址、权限位 0x3FFF、实际调用交易及 HookProxyDeployed 日志。Factory 调用交易的 receipt.contractAddress 通常不是新 Hook proxy 地址，应从事件/预计算和实际链上代码一起核对。Factory 地址不需要登记为 TSV Hook，后续业务使用 Hook proxy 地址。

Proxy 初始化在创建构造函数里执行时，记录同一个创建 tx hash，不虚构一笔额外 initializer 交易。构建 artifact 中未解析的 library/immutable 占位符不能直接当作最终 runtime codehash；需使用解析后的预期代码或对应源代码验证结果。

## 失败和重试规则

所有失败、驳回、超时、状态不明、取消及重试均留记录。MCP 响应丢失或结果不明时，先按原 uuid 查询并核对链上交易；不得直接换 uuid 重复部署。失败任务的后续尝试需关联原任务、原因和新请求摘要，原记录不删除。部分批次成功不整体重跑，先列出已成功地址并验证依赖。

## 记录保护与共享

不记录私钥、助记词、密码、API key、JWT 或带鉴权的 RPC URL。审批签名、请求/响应按实际授权保存；公开摘要与平台原始证据的存放位置分开说明。initCode 和链上交易参数可完整记录，但不得包含秘密。

文件留痕先保存在仓库目录；实际执行时逐项生成记录，按批次归档到指定版本分支。飞书/GitLab 等外部同步位置尚未指定，此处不视为已创建外部日志。可在确定目的地后同步同一 run-id、审批引用、tx hash 和最终校验结果。

摘要/追加日志有助于检查遗漏及变动，但本地 hash 文件可被一起改写，不宣称天然不可篡改。需要更强审计保证时，将最终摘要提交到经过审阅的 Git 记录或指定外部存证位置，并保留对应引用。

## 模板

- run-manifest.template.json：一次完整部署的总清单。
- task-record.template.json：单任务完整生命周期。
- deployment-plan.json：本次讨论的15项直接部署及Hook Factory调用依赖。
- planning-receipt.json：建立该计划的时间和内容摘要；不是实际部署回执。

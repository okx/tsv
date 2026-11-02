# TSV 生产部署 — 更新 main 后重新构建

源码：a8bfc93aa2cf40142e6511e5069d90f65b59f420，独立工作树 .production-tsv-main-a8bfc93-20261029。业务源码与 foundry.toml 无修改，未复用旧版本 bytecode。

Solc 0.8.26 / Cancun / optimizer 200 / viaIR / bytecode_hash none；部署入口 172 个文件编译成功，有警告，非全仓库测试。导出 12 个合约 ABI/字节码/链接引用，所有 runtime 模板尺寸均不超过 24576 字节。LPManager 构造参数已从旧版本 8 个变为 7 个，移除 Registry；首次批量不包含 LPManager。CLI 增加全局 Uniswap v4-core 导入映射。v4-periphery / SBT 均使用与源码 gitlink 一致的本地干净源码路径；OpenZeppelin 5.5.0 使用本地依赖副本。

首批：PermissionedValidationLib、TSVLPManagerLib、LPPositionMath、PermissionsAdapterFactory、TSVHookProxyFactoryV1、TSVVolumeLedgerV1 实现、TSVHookV1 实现。全部重新生成 calldata，Factory 构造参数使用已确认 PoolManager，由 cast ABI 编码；其余六项无构造参数。链上 estimateGas 和 eth_call 创建模拟各 7 项均通过。gas limit=ceil(estimate*1.2)+50000，不指定 gas_price。

使用用户指定的 request/deptName=Dex/tasks 结构，发送前新生成全部 UUID；审批地址 0x148828cA0b08f9882336794E4FE196c975C11aFc，signature 为空字符串。没有创建 W，没有业务配置，U 未提供所以资产专属 LegalShareAdapter 暂缓。

MCP 返回 10021：Approval instance already exists, please wait for approval，仍指向审批单 16539。7 个新 UUID 状态均为任务不存在，无已确认链上广播。不能把审批回执当作部署成功，亦不能证明底层部署接口已解析完整请求结构。

精确请求：requests/batch1-20261029T090858Z.json

原始回执：batch1-response-20261029T090858Z.json

查询回执：batch1-status-20261029T090858Z.json

requestId：NRI_2b5557d11a2a402889bd17f775af6e29

再次发送最新构建首批 7 项（全新 UUID）：本次返回 10020，成功生成新的审批单 16544，不再是此前 16539 的复用回执。7 个新 UUID 查询仍为任务不存在，无已确认广播。请求 requests/batch1-20261029T091000Z.json，回执 batch1-response-20261029T091000Z.json，查询 batch1-status-20261029T091000Z.json，requestId NRI_09f1006c387c4e3da1a4ecb043c5d978。

再次重试最新构建首批 7 项（全新 UUID）：返回 10020，生成新的审批单 16545。7 个新 UUID 查询均为任务不存在，无已确认广播。请求 requests/batch1-20261029T093450Z.json，回执 batch1-response-20261029T093450Z.json，查询 batch1-status-20261029T093450Z.json，requestId NRI_a7e2e0ff0732442fb82135282cf3026a。

单独提交最新 main 的 PermissionedValidationLib：新 UUID f27389d3-dfc4-4582-a18e-41cf27f12b95，返回 10020 并生成审批单 16546；查询为任务不存在。请求 requests/single-permissioned-validation-lib-20261029T093747Z.json，回执 single-permissioned-validation-lib-response-20261029T093747Z.json。

本次实际参数校验确认嵌套 request 层错误：服务端返回 tasks不能为空。按平台操作说明改为顶层 deptName=Dex、tasks=[...]，发送前全部换新 UUID 后成功创建任务 9084–9090。第一笔状态 TASK_BROADCASTED，其余初查 TASK_APPROVED；尚未返回交易哈希或部署地址，继续查询原 UUID，不重发。成功请求 requests/batch1-flat-20261029T104242Z.json，回执 batch1-flat-response-20261029T104242Z.json。

最新查询 2026-10-29 10:43:27 UTC：{"TASK_BROADCASTED": 5, "TASK_APPROVED": 2}。服务端尚未返回交易哈希或合约地址；不能认定链上部署成功，后续批次未发送。使用已创建任务的 UUID 继续查询，不再重发本批。

## 首批链上核验完成

7/7 任务状态均为 TASK_BROADCAST_SUCCESS_AND_TRANSACTION_SUCCESS。服务端 contract_address 为空，地址从交易回执提取。每笔均核实 receipt.status=1、chainId=196、直接创建交易、from 为指定部署地址、value=0、input 与本次提交 JSON 完全一致。部署 runtime 与编译产物匹配（按具体产物处理库自身地址与 immutable 补值），Factory PoolManager 和 Hook Factory flags 也已核验。最少确认数 209。

| 合约 | 地址 | 交易哈希 |
|---|---|---|
| PermissionedValidationLib | 0x8db3a851e94b38e258f801f835e2e7deeb217538 | 0xaafdde4c340db103a23d50383a5cf82539241779192822ef6244fde7c22c8af4 |
| TSVLPManagerLib | 0x1fb638662581dcdd02f3908459030c337f521114 | 0x65ecb02f8ab68328f151b820602abe0cd2c7f620357e1d62cd5b25c7d51d9ce1 |
| LPPositionMath | 0xe3334c3a8bf40cb9079ed0cb26cd8e696f76d6f4 | 0xe67b1655509e3ab671570e33e94ead8c93b0d6730fa5c4a8e8e84faab339cd84 |
| PermissionsAdapterFactory | 0x4c750656fca58da2a2e0402bd1ab0b39d134bdba | 0x095adb2cf02d432f4214d62532ca0bf6390a3b720903a51b84bf4992e2dce63b |
| TSVHookProxyFactoryV1 | 0xed28206bf9a16e4dc64b893563a48a1bb1e34c60 | 0x9e3824788a9e19d3804b8dd857d679ae5bae1fbc619cf5ddcaad4f4f201d170f |
| TSVVolumeLedgerV1 | 0x8f4c315e7b8627e8afbe4192ba95f81e1c37f0c3 | 0x68537719cd158d11cc8410491d508443903219683728805e9710743e4fe7204f |
| TSVHookV1 | 0x6422ef382cfe42b200aec323236c005c604550f7 | 0x13946a49b8be69e47d288bb055cb19955d94950b9c67c58773da155be699ef0e |

地址清单 addresses.json；链上交易与代码 transactions/；逐合约核验 verification/；汇总 batch1-chain-verification.json。尚未提交后续依赖批次，这不表示全套 TSV 已部署完成。

## Hook 手动部署确认与基础部署完成

用户交易 0xf5abf4076eeaf44a52fd26531cc924cd4e0b624ac6f677c110fdae0126c53501 于北京时间 2026-10-30T11:04:41+08:00 由 0xace2b3e7c752d5debca72210141d464371b3b9b1 调用既有 Factory。代理 0xF151416e74d6B4Ae00197e8D8E4f4765283B3fff，实现 0x6422ef382cfe42b200aec323236c005c604550f7，部署区块 74560445。

已核验回执成功、Factory 事件与 salt、完整 calldata、代理 runtime、实现槽、五个初始化依赖、重复初始化回滚。五个实现和五个代理的初始化均已锁定；初始管理员对五个代理进行同实现升级的 eth_call 模拟全部通过，部署钱包的升级模拟全部被拒绝；LP EIP712 domain 与代理地址和 chainId 一致。以上检查未发送写交易。

至此 15 个基础合约已部署并初始化。没有部署辅助中转合约。Registry 的五个业务绑定仍为零；下一阶段是 bindComponents、SBT/业务角色、资产、额度、池和流动性配置，不属于已完成的部署初始化。旧待部署登记资料已归档到 registration-history/。

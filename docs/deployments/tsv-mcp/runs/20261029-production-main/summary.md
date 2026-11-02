# 生产部署准备记录

状态：MCP 已登录；首批 7 项 CREATE 请求已发送，平台生成审批单 16539。7 个 UUID 均查询为任务不存在；没有已确认的交易或生产合约地址。

生产源码：远端 main / 90929552fd557fd67b9debafa905bafffb40ed86。此版本不含审计修复分支上的近期修改。

沿用预发的外部依赖，不沿用预发 TSV 合约：

| 依赖 | 地址 | 用途 |
|---|---|---|
| PoolManager | 0x360e68faccca8ca495c1b759fd9eee466db9fb32 | 池状态、交易及结算 |
| Permit2 | 0x000000000022d473030f116ddee9f6b43ac78ba3 | LP 侧代币授权转账 |
| PositionDescriptor | 0x9e9fbbef0e1bd752e83de5acff3d0c936a9e5a4b | LP 头寸 NFT 元数据 |
| WOKB | 0xe538905cf8410324e03a5a23c1c177a474d59b2b | 原生 OKB 的包装资产，不是 TSV 股票 W |

RPC：https://rpc.xlayer.tech；chainId 已读到 196。上述四地址在 external-code.json 指定区块均有代码。这只证明代码存在，不等于完整兼容性验证。

部署特权地址：0xeb84007545644e10c1a47502438377f7cd192904。Registry 初始 DEFAULT_ADMIN_ROLE 和 UPGRADE_ADMIN_ROLE 授予 0xace2b3e7c752d5debca72210141d464371b3b9b1；部署钱包不自动获得这些角色。

预发 LPManager 链上读取 unsubscribeGasLimit=200000、DELIVERY_GAS_LIMIT=500000：分别限制取消订阅通知回调和资产交付尝试使用的 gas，不是整笔部署交易的 gas limit。作为沿用预发的候选构造参数记录。

U 暂无：资产专属 LegalShareAdapter 暂缓，核心部署不依赖此 Adapter。原计划直接创建 15 个任务，暂缓该项后为 14 个；Hook proxy 的 Factory 调用仍需解决 MCP 调用通道，不能当作已支持。

此前 MCP 前置调用返回 Authentication required；现已登录并验证成功。用户指定 approval_address=0x148828cA0b08f9882336794E4FE196c975C11aFc，signature 为空字符串；按此准备，服务端是否接受尚未验证。现已使用明确提供的空签名调用 create，平台返回 Approval instance generated successfully（error_code=10020）。已分配 7 个 UUID 并保存请求，查询暂未找到任务；无已确认广播。

构建记录在 ../../production-main-build*.log。首次尝试遇到 Soldeer 不支持工作树外依赖符号链接的崩溃；改用依赖副本重试，保留原日志。生产业务源码未改动。CLI 添加全局 Uniswap v4-core 导入映射；部署入口构建重试成功并补充构建 PermissionsAdapterFactory，12 个合约的产物和链接信息保存于 artifacts/ 与 build-inventory.json；不是全仓库测试。

## 首批 MCP 回执

审批链接：https://pmboss.okg.com/newboss/okbossPlatform/approval/instance/16539?_region_=GLOBAL

本批包含 PermissionedValidationLib、TSVLPManagerLib、LPPositionMath、PermissionsAdapterFactory、TSVHookProxyFactoryV1、TSVVolumeLedgerV1 实现、TSVHookV1 实现。链上 estimateGas 均成功；gas limit=ceil(estimate*1.2)+50000。未固定 gas_price，使用平台定价。请求、回执、查询分别为 batch1-prepared-request.json、batch1-mcp-create-response.json、batch1-mcp-status.json。

平台审批是本次服务端返回的实际流程；不是额外人工文字确认要求。后续先处理审批，再按原 UUID 查询，不能盲目重新提交。后续依赖批次未提交。

最新复查：7 个原 UUID 仍全部返回“任务不存在”。审批单 16539 浏览器返回 403 Forbidden，无法核实审批状态；不能据此认定审批未通过或被拒绝。没有已确认交易哈希，未重复创建。详细时间见 manifest.latestCheck。

用户补充完整请求结构为 {"request":{"deptName":"Dex","tasks":[...]}}。修正版保存在 batch1-request-with-dept.json，7 项任务、calldata 与 UUID 均保持原值。batch1-prepared-request.json 是此前实际传入 MCP 的参数，不覆盖。当前已暴露 MCP 创建接口仅声明顶层 tasks，不含 request/deptName，因此修正版尚未提交。不能仅据缺失字段就认定先前任务不存在的原因。

用户要求每次发送创建请求前替换全部任务 UUID。当前待提交修正版已换新 UUID，旧内容归档在 requests/，映射保存在 uuid-refresh 记录；尚未发送。实际发送前再次生成新 UUID 并保存精确请求。查询使用各次发送记录中的 UUID；新 UUID 不代表此前审批或部署被取消，重试前仍须核对旧请求。

实际已尝试用户指定的完整 request/deptName/tasks 结构；工具调用接受并返回服务端回执，纠正此前“必须更新接口定义才能调用”的判断。发送前 7 个 UUID 全部重新生成，本次精确请求见 requests/batch1-20261029T072433Z.json。服务器 error_code=10021：Approval instance already exists, please wait for approval，仍指向审批单 16539。没有新任务或交易哈希；本次请求与旧请求均保留。

审批解释更正：这两次是同一部署首批 7 项的两次发送，不是依赖部署的第一批和第二批。10020/10021 只证明平台创建或复用审批 16539，不能证明底层部署接口解析或接受了第二次 request/deptName 结构。UUID 已换新仍复用审批，说明实际审批没有仅按新任务 UUID 独立生成；具体审批去重键及其是否为 MCP 调用授权审批，当前无权威说明。已阅读 PMBoss 操作说明（Y26NdBx1JofeoNx51w6lmn1LgEc），其中描述 deptName 用于 Lark 审批分流，未说明上述去重规则。该文档示例为顶层 deptName/tasks；与用户要求的 request 外层不同，尚未更改或再次发送。

单任务测试：只提交 PermissionedValidationLib，使用新 UUID 9d67f662-ed03-402b-880a-5a8ce2424fe0，其余部署参数保留，request.deptName=Dex。服务端仍返回 10021/审批单 16539，UUID 查询仍为任务不存在。该结果表明仅把 tasks 数量从 7 改为 1 没有触发新审批，不能据此确定完整去重规则。请求和回执分别为 requests/single-permissioned-validation-lib-20261029T074340Z.json 与 single-permissioned-validation-lib-response-20261029T074340Z.json。

用户明确要求再次单任务发送：新 UUID 52b0593b-0c97-4885-9895-f5d74b9bd4b3，返回仍为 10021/已有审批单 16539；查询为任务不存在。本次请求 requests/single-permissioned-validation-lib-20261029T081109Z.json，回执 single-permissioned-validation-lib-response-20261029T081109Z.json。

再次批量提交首批 7 项：全新 UUID，request.deptName=Dex；返回仍为 10021/审批单 16539，7 个新 UUID 查询均为任务不存在。请求 requests/batch1-20261029T090131Z.json，回执 batch1-mcp-response-20261029T090131Z.json，查询 batch1-mcp-status-20261029T090131Z.json。

源码更新：用户要求重新拉取 main，主工作区已快进到 a8bfc93aa2cf40142e6511e5069d90f65b59f420，与此次 fetch 的 origin/main 一致。本目录的原部署构建和已发送 JSON 继续对应旧 commit 90929552fd557fd67b9debafa905bafffb40ed86，保留作为历史，不能当作新版本部署数据复用。新 main 必须独立重新构建、检查构造参数、生成 calldata、UUID 和审批材料后提交；此次没有发送新 MCP 请求。

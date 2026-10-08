# X Layer 固定区块 DEX 流程

运行 `make test-xlayer`，默认连接 [官方公开 RPC](https://web3.okx.com/onchainos/dev-docs/xlayer/developer/rpc-endpoints/rpc-endpoints) `https://rpc.xlayer.tech`；可用环境变量 `XLAYER_RPC_URL` 指定同链 archive RPC。固定区块 **72,271,000**、chainId **196**，不随 latest 自动移动。

`DexRouterFlow.t.sol` 使用链上真实入口 `0x7c5bee2a8091c3ef39072f64f18fac913060aeaf`、执行模块、TokenApproveProxy 与 TokenApprove。部署清单固定八个依赖的 codehash；测试校验版本、授权关系及链/区块。未改写这些合约代码、白名单或管理员状态；无需生产账户签名。

流程为：测试用户 approve 链上 TokenApprove → 链上 DEX 转入测试 Adapter → Adapter 从 DEX 追加的认证标记取得原始交易者 → TSV Router 校验该身份的 SBT → Hook/V4 交换、精确结算与额度记账 → 输出交付、未使用输入退款。多跳中间资金先返回 DEX，下一跳仍按原始交易者身份检查。

11 项覆盖：双向单跳、拆单、跨两池/两股票 Currency 的多跳、指定收款人、合约钱包身份、不能借用持证 tx.origin、DEX 最低输出失败全回滚、部分成交退款、Adapter 撤权/交易暂停、交易与 LP 完整生命周期、部署依赖校验。成功后测试 Token 在 DEX、Adapter、TSV Router/LP Manager 无本笔残留，Adapter 对 TSV Router 的授权归零。

边界：DEX 和授权组件是真实链上实例；TSV 六组件及真实 V4 PoolManager 在 fork 内新建，股票/Wrapped/SBT 使用行为 mock。此套件证明 DEX→TSV 的集成流程，不代表真实发行方资产、生产 SBT、生产 TSV 部署或多签已经验收，也不覆盖 DEX 自身全部协议、native/permit/佣金/RFQ 路径。正式 Adapter 尚未作为生产合约交付。

默认 `make test` 运行不联网的 unit/local；fork 由独立 xlayer profile 执行。RPC 缺失、错链、代码哈希不符或流程失败会直接失败，不自动 skip。

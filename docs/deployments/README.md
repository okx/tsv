# TSV 部署说明

部署与升级应固定源码版本、依赖、编译设置和目标网络，并对实际链上结果独立核验。

## 发布和部署顺序

1. 完成合约修改及审核，固定完整 source commit。
2. 按[部署准备清单](../DEPLOYMENT_CHECKLIST_V1.md)确定构造参数、代理初始化、外部依赖、角色和库链接。
3. 使用固定编译设置构建目标合约，模拟创建或升级调用，核对 Chain ID、发起方、目标地址、gas 和转账金额。
4. 执行部署或升级，逐项确认交易回执成功、代码及实现槽正确，再读回初始化状态、角色和组件绑定。
5. 更新[环境地址清单](../../deployment/README.md)和发布说明，记录源码版本、核验区块、交易 hash 和验证边界。
6. 发布版本快照；后续修改使用新的版本，不覆盖已发布 Tag。

完整发布规则见[开发与发布流程](../REPOSITORY_BRANCHES.md)。参数化操作工具要求显式选择配置，参见[操作器说明](../../script/xlayer/README.md)。

## 地址与验证范围

- 合约地址统一见 [pre](../../deployment/pre/addresses.json) 和 [prod](../../deployment/prod/addresses.json)。pre 和 prod 均为 X Layer 主网环境，应核对具体目标。
- ABI 与存储布局见 [artifacts](../artifacts/README.md)。当前源码产物不能自动代替历史部署的构建产物。
- 地址清单应区分当前实现、历史实现和未采用部署；核验范围以每份清单的 verification 字段为准。
- 合约创建成功不表示角色、SBT、资产准入、额度或池配置已经完成；发布版本也不等于业务已经验收。

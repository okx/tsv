来源：[DEX - TSV 合约审计报告](https://okg-block.sg.larksuite.com/docx/NYPSdzQruohPBOx90CUlFrTegbd)

报告审计 Commit：`6402443e9fc372e8aa52c9ba82cd3e84cb846493`；分支：`main`。

原文快照：2026-10-27T09:27:51Z（文档最后修改时间）。以下保留报告原文，截图为原图；仅转换排版，不代表已复核当前代码或确认修复状态。

## 报告原文

### No.5: 低风险【中心化风险】（所有审计人员）

| 位置 | 文件 | 风险状态 | 风险类型 | 风险级别 |
|---|---|---|---|---|
| Line -- | src/v1/governance/TSVGoverned.sol<br>src/v1/core/TSVRegistryV1.sol<br>src/v1/core/TSVVolumeLedgerV1.sol<br>src/v1/periphery/TSVSwapRouterV1.sol<br>src/v1/periphery/TSVLPManagerV1.sol | ❌  | 中心化风险 | 低风险 |

风险描述及修改建议

风险描述

协议依赖多个特权角色及外部合规依赖正确运作；关键账户失陷、误配置或不可用，可能影响资产准入、交易额度、暂停恢复、合约升级与强退。低风险评级描述既有信任模型，不代表关键权限失陷的潜在损失较低。

DEFAULT_ADMIN_ROLE：在 Registry 管理角色、绑定核心组件及配置 SBT 身份权限；Router 同时依赖该角色管理可提交交易的 Adapter。UPGRADE_ADMIN_ROLE：授权升级 Registry、Hook、Router、LPManager 及 Ledger 等业务代理。

SYMBOL_ADMIN_ROLE：管理证券、底层资产、报价币、档位及池生命周期等配置。POOL_CREATOR_ROLE：授权初始化池子。HALT_REPORTER_ROLE：管理证券级业务暂停。EMERGENCY_PAUSER_ROLE／EMERGENCY_RESUMER_ROLE：启用／解除全局紧急暂停。

VOLUME_ORACLE_ROLE：设置每日额度及覆盖已用额度，直接影响后续交易可用性

FORCE_EXIT_ADMIN_ROLE：调用 TSV 强退入口；强退仍受代码中的资产退出资格及结算条件约束。发行方、权限适配器及 SBT 的外部治理同样是合规与持续可用性的信任依赖。

修改建议

关键特权采用多签机制并遵循最小权限原则；分离日常配置、升级、暂停和恢复职责，持续监控角色与关键配置变更。对非紧急升级及高影响参数变更采用适当时间锁；为紧急操作保留经过演练的受控流程。核对部署后的实际权限持有人、升级实现及外部合规依赖，及时撤销闲置授权。

问题反馈

| 项目方（产研）反馈 |  |
|---|---|
| 审计反馈 |  |

---
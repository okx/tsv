# 报告与 Issue 对照

报告：https://okg-block.sg.larksuite.com/docx/NYPSdzQruohPBOx90CUlFrTegbd

- No.1：[[审计｜中风险｜No.1] 订阅回调可使强制退出的余额差计算下溢](https://gitlab.okg.com/web3-dex/tsv/-/work_items/9)
- No.2：[[审计｜中风险｜No.2] SBT 身份列表无长度上限，权限校验可能耗尽 gas](https://gitlab.okg.com/web3-dex/tsv/-/work_items/10)
- No.3：[[审计｜低风险｜No.3] 强退事件读取 W 余额，漏报实际收到的 U 资产](https://gitlab.okg.com/web3-dex/tsv/-/work_items/11)
- No.4：[[审计｜优化建议｜No.4] 不同合约的升级暂停检查不一致](https://gitlab.okg.com/web3-dex/tsv/-/work_items/12)
- No.5：[[审计｜低风险｜No.5] 中心化风险](https://gitlab.okg.com/web3-dex/tsv/-/work_items/13)
- No.6.1：[[审计｜优化建议｜No.6.1] 评估主合约 reserve gap 的必要性](https://gitlab.okg.com/web3-dex/tsv/-/work_items/14)
- No.6.2：[[审计｜优化建议｜No.6.2] 明确 constructor 与 initialize 的 Registry 配置来源](https://gitlab.okg.com/web3-dex/tsv/-/work_items/15)
- No.6.3：[[审计｜优化建议｜No.6.3] 使用具名常量表示强退活动状态](https://gitlab.okg.com/web3-dex/tsv/-/work_items/16)
- No.6.4：[[审计｜优化建议｜No.6.4] 简化 _candidateUnderlying 的 Adapter 读取](https://gitlab.okg.com/web3-dex/tsv/-/work_items/17)
- No.6.5：[[审计｜优化建议｜No.6.5] 删除未支持的结算分支](https://gitlab.okg.com/web3-dex/tsv/-/work_items/18)
- No.6.6：[[审计｜优化建议｜No.6.6] 减少 checkSettlementAction 的重复拒绝检查](https://gitlab.okg.com/web3-dex/tsv/-/work_items/19)
- No.6.7：[[审计｜优化建议｜No.6.7] 删除 registerPool 重复的 listed 检查](https://gitlab.okg.com/web3-dex/tsv/-/work_items/20)
- No.6.8：[[审计｜优化建议｜No.6.8] 明确双向交易额度的手续费统计口径](https://gitlab.okg.com/web3-dex/tsv/-/work_items/21)
- No.6.9：[[审计｜优化建议｜No.6.9] 评估 _validateMultiplierSnapshot 重复调用](https://gitlab.okg.com/web3-dex/tsv/-/work_items/22)
- No.6.10：[[审计｜优化建议｜No.6.10] 简化 participantSbt 重复校验](https://gitlab.okg.com/web3-dex/tsv/-/work_items/23)
- No.6.11：[[审计｜优化建议｜No.6.11] 删除 pauseMode 范围冗余检查](https://gitlab.okg.com/web3-dex/tsv/-/work_items/24)
- No.6.12：[[审计｜优化建议｜No.6.12] 删除 registerPermissionedCurrency 重复检查](https://gitlab.okg.com/web3-dex/tsv/-/work_items/25)
- No.6.13：[[审计｜优化建议｜No.6.13] 确认是否保留未使用的 TSVDirectSettlementLib](https://gitlab.okg.com/web3-dex/tsv/-/work_items/26)
- No.6.14：[[审计｜优化建议｜No.6.14] swap 结束后清理 active 状态变量](https://gitlab.okg.com/web3-dex/tsv/-/work_items/27)
- No.6.15：[[审计｜优化建议｜No.6.15] approve 增加 spender/operator 的 SBT 检查](https://gitlab.okg.com/web3-dex/tsv/-/work_items/28)
- 问题1：[[审计｜未评级｜问题1] 累计本金超出单次资产增量上限，可能导致强退失败](https://gitlab.okg.com/web3-dex/tsv/-/work_items/29)

- 审计版本与 main 差异：[[审计差异｜未评级] 审计基线 6402443 与 main 9092955 的变更及增量复核范围](https://gitlab.okg.com/web3-dex/tsv/-/work_items/30)

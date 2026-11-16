# TSV 合约地址

所有环境的合约地址清单统一放在本目录：

| 环境 | 地址清单 | 核验范围 |
| --- | --- | --- |
| pre（X Layer 主网预发） | [pre/addresses.json](pre/addresses.json) | 清单的 verification、核验区块及来源说明 |
| prod（X Layer 主网生产） | [prod/addresses.json](prod/addresses.json) | 当前实现、组件绑定及所记录的升级交易 |

两套环境均为 Chain ID 196，pre 不是测试网。`proxies` 为业务入口，`implementations` 为核验区块的实际实现，`libraries`、`factories`、`dependencies` 和资产／Adapter 分组分别维护。历史配置和未采用部署须单独标记，不能冒充当前绑定。公共地址本身不表示业务权限和配置已经完成。

生产核心组件已于 2026-11-16 完成本次代理升级。`currentCoreSourceCommit` 标识当前核心源码基线，`upgradeHistory` 保留前后地址和升级交易。`initialDeploymentCommit` 及旧 `releaseBranch` 字段描述初始发布，不用于推断后续版本状态。版本变化和验证范围见 [V0.0.2 发布说明](../docs/releases/V0.0.2.md)。

地址记录只描述其核验区块。代币及外部集成条目保留各自的历史核验日期，不将全部条目宣称为当前已启用。pre 初始实现的源码版本尚未确认时应保留为 null，不根据当前 main 反推已部署源码。

公开部署步骤见[部署说明](../docs/deployments/README.md)，当前源码 ABI 见[生成产物](../docs/artifacts/README.md)。脚本配置是执行输入，使用前须与目标链实现、绑定和角色独立核对；发现冲突时应先查明实际状态。

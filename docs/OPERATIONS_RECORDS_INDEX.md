# TSV 运维记录的位置

操作原始记录及内部 MCP 工作流维护于 `ops/deployment`。main 保留合约、测试、公开接入说明、构建工具及已核验的环境地址，不分发历史操作输出。

| 内容 | main 中的入口 |
| --- | --- |
| 分支职责与发布同步 | [REPOSITORY_BRANCHES.md](REPOSITORY_BRANCHES.md) |
| 公开部署步骤 | [deployments/README.md](deployments/README.md) |
| pre / prod 地址与历史登记资料 | [deployment/README.md](../deployment/README.md) |
| 后端池查询与 W/U 接入 | [POOL_MONITORING_AND_WU_LOOKUP_V1.md](POOL_MONITORING_AND_WU_LOOKUP_V1.md) |

历史归档位于运维分支 commit `298ee17bd657a7fb57106b19c3a0a24628226320`，路径为 `outputs/`、`docs/deployments/tsv-mcp/` 和 `.agents/skills/tsv-mcp-deploy/`。`outputs/rwa-market-maker/` 包含做市和监控程序，保留在该分支继续维护，不作为 main 的构建依赖。

归档文件仅代表记录的日期或区块，不代表实时状态；本地模拟和测试不代表已经广播或完成生产配置。地址清单中的 `archivedSources` 指向固定归档 commit，查询证据时应使用对应版本。

2026-11-04 补充归档的 Skills、历史会话工具、配置和原始文档版本固定保留于运维 commit `73e18cc0a0c49932fe78bcc12a259e4e8f05c25e`，归档索引位于该版本的 `docs/operations/PUBLICATION_ARCHIVE_20261104.md`。公开版本采用显式配置和自行编写的技术说明，不依赖归档文档。

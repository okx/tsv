# 分支职责与发布流程

| 分支 | 维护内容 | 规则 |
| --- | --- | --- |
| `main` | 合约、测试、公开技术文档、ABI、构建与集成代码、pre/prod 地址和发布信息 | 所有合约修复先进入 main |
| `ops/deployment` | 同步 main 的代码，另保留 MCP 工作流、部署原始证据、运行日志和做市工具 | 不将整个分支合并回 main |
| `release/prod/<version>-<YYYYMMDD>` | 指定 main commit 的正式发布快照 | 发版时创建并冻结；不以创建分支代替部署验收 |

运维专属文件由 [operations-only-paths.txt](../script/operations-only-paths.txt) 统一列出，包括内部开发 Skills、历史工具、原始证据和实际运行配置。main 的忽略规则和公开文件检查防止这些内容重新进入当前文件树；这不改变既有历史或访问权限。

## 日常修改

合约、测试、通用构建和 SDK 修复通过 MR 进入 main。MCP 和运维工具在运维分支维护；发现通用修复时单独向 main 提 MR，不把内部文件随整分支合并回去。公开部署步骤和地址信息保留在 main，原始请求和回执保留在运维分支。

## 运维分支同步 main

main 将删除运维专属路径，直接合并可能把这些删除带入运维分支。因此同步时必须保留合并前的运维文件。应在干净的运维工作树中操作，先将 SOURCE_COMMIT 设置为已核实的 main/release 完整 commit：

```sh
# 在 ops/deployment 的干净工作树中执行；此处仅展示流程。
git fetch origin main ops/deployment
git merge --no-ff --no-commit "$SOURCE_COMMIT"
# HEAD 仍是合并前的运维 commit，从它恢复运维专属路径。
git restore --source=HEAD --staged --worktree --pathspec-from-file=script/operations-only-paths.txt
# 检查差异并解决其余冲突，验证构建和测试后再提交本次同步。
```

清单仅包含运维专属路径，不覆盖 main 中保留的通用操作脚本或 SDK。不得从旧运维版本恢复 `src/` 或其他合约文件覆盖 main 的修复。需要新增被 main 忽略的运维记录时，在确认归档范围后显式添加对应文件，不使用全目录强制添加。main 的公开文档检查针对 main 内容；运维分支的内部链接和归档需使用其对应的校验流程。

## 正式发布

固定并验证 main commit 后，创建 `release/prod/<version>-<YYYYMMDD>` 并记录 source commit、编译参数和验证结果。部署采用该版本构建，部署证据由运维分支归档。后续修复继续回到 main，生成新版本，不覆盖已发布分支或 tag。

本流程不重写既有 Git 历史。若未来对外发布要求历史中也不含内部文件，需要另外导出干净的公开历史。

# Claude bridge 上游归属

## 来源

- 上游仓库：[dnakov/alleycat](https://github.com/dnakov/alleycat)
- 原迁移分支：[gaixianggeng/alleycat](https://github.com/gaixianggeng/alleycat)
- 导入 commit：`1bb754687990a308dcc330f369820ff42d7c3289`
- 原发布 tag：`claude-bridge-v0.2.1`
- 导入日期：2026-07-18

本目录是上述 commit 的收窄快照，只包含 Mimi Remote 实际依赖的 `claude-bridge`、`bridge-core` 和 `codex-proto`。为适配 Mimi Remote，原分支包含以下两个提交：

- `c50256dc9cc71f5130a176e32bb6fd33b1e06f74`：补齐移动端审批兼容；
- `1bb754687990a308dcc330f369820ff42d7c3289`：过滤 Claude 本地命令记录。

## 版权与修改边界

相关源码的历史贡献者包括 dnakov、Benjamin Western、Thomas Zarebczan、Franklin、xk44 和 landy。上游完整提交历史仍可通过上述仓库与 commit 查阅。

导入后对 workspace 路径、构建配置、安装说明和 Mimi Remote 兼容性的修改应在本仓库 Git 历史中明确记录。首次导入同时隔离了 Codex resolver 测试的 PATH，避免开发机已安装的 ChatGPT / Codex 污染测试候选。不得删除上游版权、作者归属或 GPLv3 条款。

## 协议

本目录使用 `GPL-3.0-only`，完整正文见 [LICENSE](LICENSE)。仓库根目录 `LICENSE` 中由 Mimi Remote copyright holders 提供的 App Store / Google Play 额外许可，不适用于本目录中其他上游贡献者拥有版权的代码。

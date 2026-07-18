# Claude bridge

## 目标

这个目录包含 Mimi Remote 的 Claude Code 实验通道。`agentd` 启动 `alleycat-claude-bridge` 子进程，把 iOS 使用的 Codex app-server JSON-RPC 映射到 Claude Code headless `stream-json`。

只保留运行该通道需要的三个 Rust crate：

- `crates/claude-bridge`：Claude Code 进程、审批、会话和事件转换；
- `crates/bridge-core`：JSON-RPC framing、进程池和共享 bridge 基础设施；
- `crates/codex-proto`：移动端与 bridge 共用的 app-server wire types。

Amp、Pi、OpenCode、Droid、Hermes 和 Alleycat daemon 不属于 Mimi Remote 当前范围，因此没有一并导入。

## 构建与验证

从仓库根目录执行：

```bash
cargo test --locked \
  -p alleycat-codex-proto \
  -p alleycat-bridge-core \
  -p alleycat-claude-bridge

cargo install --locked \
  --path bridges/claude/crates/claude-bridge \
  --force \
  --bin alleycat-claude-bridge
```

安装完成后：

```bash
command -v alleycat-claude-bridge
alleycat-claude-bridge --version
```

## 来源与协议

代码来源、导入 commit 和本地修改见 [UPSTREAM.md](UPSTREAM.md)。本目录保留上游 [GNU GPLv3-only](LICENSE)，不适用仓库根目录为自有 iOS / Go 代码提供的 App Store / Google Play 分发例外。

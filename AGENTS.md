# 仓库模块索引

- `src/broker.ts`：共享 Broker、状态所有权、资源调度与 IPC 命令分发。
- `src/cli.ts`：`bcu` 公共命令面、参数解析、输出与退出码。
- `src/platform/`：macOS、Windows 后端及平台中立接口。
- `native/`：macOS Swift helper 与 Windows Rust bridge。
- `skills/`：供 Agent Skills 体系安装的 bcu 使用说明和参考表。
- `scripts/`：构建、基准、打包、跨平台检查与回归入口。

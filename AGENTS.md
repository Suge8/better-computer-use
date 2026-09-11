# 仓库模块索引

- `src/cli.ts`：`bcu` 公共命令面、参数解析、输出与退出码。
- `src/broker.ts`：共享 Broker、IPC 命令分发、helper 诊断与权限 setup。
- `src/session.ts`：operation state、资源调度、状态存取与工具执行入口。
- `src/roots.ts`、`src/root-refs.ts`：根发现、目标选择、pairing 与稳定 `@r` 身份。
- `src/observe.ts`：observation 采集、结果组装与缓存查询（search/expand/inspect/read-text/wait-for）。
- `src/projection.ts`：outline → `ProjectedNode[]` 投影与文本渲染，文本视图与 `--json` 的唯一事实源。
- `src/contract.ts`、`src/errors.ts`：命令参数与结果契约、稳定错误码与退出码。
- `src/act.ts`：动作事务、投递策略、后置条件校验与后继状态。
- `src/macos/`：macOS helper 客户端、backend 与 helper 线协议。
- `native/macos/`：Swift helper（Accessibility、ScreenCaptureKit、输入投递、agent 光标）。
- `skills/`：Better Computer Use Agent Skill 及 bcu 命令参考。
- `scripts/`：构建、打包、基准与回归检查入口；共享测试脚手架在 `scripts/lib/`。

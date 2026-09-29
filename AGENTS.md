# 仓库模块索引

- `src/cli.ts`：`bcu` 公共命令面、参数解析、输出与退出码。
- `src/broker.ts`：共享 Broker、IPC 命令分发、helper 诊断与权限 setup。
- `src/session.ts`：operation state、资源调度、状态存取与工具执行入口。
- `src/roots.ts`、`src/root-refs.ts`：根发现、目标选择与稳定 `@r` 身份。
- `src/observe.ts`：observation 采集、结果组装与缓存查询（search/expand/inspect/read-text/wait-for）。
- `src/projection.ts`：outline → `ProjectedNode[]` 投影与文本渲染，文本视图与 `--json` 的唯一事实源。
- `src/contract.ts`、`src/errors.ts`：命令参数与结果契约、稳定错误码与退出码。
- `src/act.ts`：动作事务、投递梯子、后置条件校验与后继状态。
- `src/actions.ts`、`src/view.ts`、`src/state.ts`、`src/runtime.ts`：动作校验与准备、状态间差异、保存状态与资源调度。
- `src/macos/`：macOS helper 客户端、backend 与 helper 线协议。
- `Package.swift`、`Sources/BCUCore/`：SwiftPM 包的纯逻辑库（大纲、投影、变化、搜索、契约类型、错误、动作校验与准备、CLI 解析与渲染），不依赖 AppKit，是运行时收口为一个 Swift 进程（ADR 0002）后的唯一实现；`Tests/BCUCoreTests/` 用 `Golden/` 金标逐字节对照，金标由 `scripts/generate-swift-golden.mjs` 从 TS 实现生成。
- `Sources/BCUPlatform/`：全部平台能力（Accessibility、ScreenCaptureKit、OCR、输入投递、agent 光标），`Platform` 是进程内门面，请求与结果类型在 `API.swift`；`HelperServer.swift` 与 `WireProtocol.swift` 是 helper 的 socket 与线协议；`Act.swift` 是动作事务与投递梯子，`SkyLight.swift` 是后台原始输入所用的私有接口，`LookOutline.swift` 是 look 大纲节点与 OCR 行挂载规则；单元测试在 `Tests/BCUPlatformTests/`。
- `Sources/bridge/`：helper 可执行文件入口（`serve` 模式），只启动 `HelperServer`。
- `skills/better-computer-use/SKILL.md`：Agent Skill 源文件，`~/.agents/skills/operations/better-computer-use` 软链到它。
- `scripts/`：构建、打包与行为门；每个 `check-*.mjs` 文件头写明它保护什么，共享脚手架在 `scripts/lib/`，真机 outline fixture 在 `scripts/fixtures/`。

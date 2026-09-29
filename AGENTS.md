# 仓库模块索引

- `Package.swift`：SwiftPM 包的目标划分与目录归属（ADR 0002）。
- `Sources/BCUCore/`：纯逻辑库（大纲、投影、变化、搜索、契约类型、错误、动作校验与准备、CLI 解析与渲染），不依赖 AppKit；`Tests/BCUCoreTests/` 用 `Golden/` 金标逐字节对照，金标就是契约，行为变更先单独提交手改的金标。
- `Sources/BCURuntime/`：常驻进程与客户端的运行时核心，不碰平台：socket 线协议、connect-or-start、状态库、按 pid 的调度与 epoch、根注册表、截图 artifact；测试在 `Tests/BCURuntimeTests/`。
- `Sources/BCUPlatform/`：全部平台能力（Accessibility、ScreenCaptureKit、OCR、输入投递、agent 光标），`Platform` 是进程内门面，请求与结果类型在 `API.swift`；`Act.swift` 是动作事务与投递梯子，`SkyLight.swift` 是后台原始输入所用的私有接口，`LookOutline.swift` 是 look 大纲节点与 OCR 行挂载规则；单元测试在 `Tests/BCUPlatformTests/`。
- `Sources/BCUDaemon/`：常驻进程的命令处理器，`makeRequestHandler` 是它与可执行文件之间的接缝。
- `Sources/bcu/`：唯一的可执行文件。客户端解析参数、连接或经 `open` 启动 `bcu.app`、打印结果；`bcu serve` 在 AppKit 主运行循环里运行常驻进程；配置文件与 `BCU_*` 环境变量在这里解析。
- `scripts/install.sh`：构建、组装、签名并安装 `bcu.app`，链接 `bcu`。
- `scripts/check-*.mjs`：黑盒门，每个文件头写明它保护什么；共享脚手架在 `scripts/lib/`，真机 fixture 与金标用的 outline fixture 在 `scripts/fixtures/`。
- `skills/better-computer-use/SKILL.md`：Agent Skill 源文件，`~/.agents/skills/operations/better-computer-use` 软链到它。

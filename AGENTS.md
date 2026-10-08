# bcu 开发地图

## 命令

- `npm test`：`swift test` 加不需要权限的 CLI 黑盒门。只跑金标：`swift test --filter projection`；Thread Sanitizer：`swift test --sanitize=thread`。
- `scripts/install.sh`：Developer ID 签名构建并替换 `/Applications/bcu.app`。常驻进程必须是经 LaunchServices 启动的 `bcu.app`，系统按签名身份和 bundle id 记辅助功能与屏幕录制授权，所以开发安装和发版用同一个签名。
- `BCU_LIVE=1 npm run test:smoke`：真机门，驱动已安装的 `bcu.app`，要解锁的桌面；Swift 改动后先跑 `install.sh`。
- `swift build --product bcu` 得到的调试客户端不在 app 里：要设 `BCU_APP_PATH=/Applications/bcu.app`，它驱动的是已安装的常驻进程，改了请求或结果的形状要先重装，否则解码失败。
- `scripts/release.sh X.Y.Z [--dry-run]`：本机发版，步骤和一次性的 `bcu-notary` 凭据写在脚本头。版本只来自 git tag；Suge8/homebrew-tap 的 `Casks/bcu.rb` 由它生成，不手改。

## 约束

- `Tests/BCUCoreTests/Golden/` 逐字节就是契约：行为变更先单独提交手改的金标，再改代码。
- `scripts/check-*.mjs` 每个文件头写明它保护的行为。改坏一个门，要么是回归，要么是契约变更，后者在同一提交里更新这个门。
- 目标边界：`BCUCore` 纯逻辑、不依赖 AppKit；`BCURuntime` 是线协议、状态库、调度、根注册表、截图 artifact，不碰平台；`BCUPlatform` 是全部平台调用，经 `Platform` 门面，元素以 `Handle` 交出；`BCUDaemon` 是常驻进程的命令处理，用 `Desktop.swift` 这个接缝接平台，`Tests/BCUDaemonTests/` 用假平台测；`Sources/bcu/` 是唯一的可执行文件（客户端与 `bcu serve`），配置文件和 `BCU_*` 在这里解析。
- 平台调用会阻塞、可在任意线程：共享状态放在锁后面，元素以 `Sendable` 的 `Handle` 传递；唯一的 `@unchecked Sendable` 在 `Handle.swift`，理由写在那里。
- 测试共用的临时目录：套件加 `.temporaryRoot`（`Tests/Support/`）。

## 什么时候读什么

- 改投递、判定、投影、状态或根模型前读 `docs/architecture.md`；代码注释按小节名引用它。
- 从上游 `injaneity/pi-computer-use` 移植引擎改动前读 `docs/adr/0001-upstream-tracking-fork.md`。
- 加或改配置项、`BCU_*` 变量：同一改动更新 `docs/configuration.md`。
- 命令、参数、输出格式或动作字段变了：同一改动更新用法 skill，它是用法的唯一事实源，在 `~/Project/friedbun/skills/operations/better-computer-use/SKILL.md`（仓库 Suge8/friedbun）。README 只讲是什么、怎么装，不写用法细节。

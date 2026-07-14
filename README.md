# Better Computer Use

`bcu` 是面向 AI agent 的桌面操控 CLI。只要 agent 能运行 shell，就能用它观察和操作 macOS、Windows 应用，无需注入一组常驻工具 Schema。

`bcu` 可以查找窗口、读取界面结构、搜索控件、点击、输入、滚动、等待界面变化，也能通过 CDP 操作浏览器页面。状态、并发调度和截图文件由同一个用户级 Broker 管理。

## 适用场景

当目标应用没有可靠的 API、命令行或 MCP 接口时使用 `bcu`。如果已有直接接口，优先使用直接接口。

支持环境：

- macOS 14 或更高版本
- Windows 交互式桌面会话
- Node.js 20.6 或更高版本

## 安装

当前仓库尚未发布 npm 包。克隆后执行：

```bash
npm install
npm run build
npm link
which bcu
```

`which bcu` 应指向 npm link 创建的全局命令。

macOS 首次使用前运行：

```bash
bcu setup
```

按提示在“系统设置 → 隐私与安全性”中为 `/Applications/bcu.app` 打开：

- 辅助功能
- 屏幕录制（新版 macOS 显示为“屏幕与系统音频录制”）

Windows 不需要这套 TCC 授权流程。包内已包含 Windows helper，运行时不需要 Rust 或 Cargo。

## 快速开始

已知目标应用且窗口唯一时直接观察：

```bash
bcu observe-ui --app TextEdit --mode semantic --image never
```

目标不确定或有多个窗口时，先运行 `bcu find-roots --app TextEdit`，再用返回的 `@r` 执行 `observe-ui --root @r1`。

命令会返回 `stateId` 和界面 outline。后续查询与操作必须使用该状态中的 `stateId` 和 `@e` ref：

```bash
bcu search-ui --state <stateId> --text Save

echo '[{"action":"press","ref":"@e12"}]' |
  bcu act-ui --state <stateId> --expect-text Saved --timeout 3000 -
```

`act-ui` 返回的新 `stateId` 是下一次操作的输入。状态过期时重新执行 `observe-ui`。

需要截图时显式请求：

```bash
bcu observe-ui --app TextEdit --image always
```

截图写入 `~/Library/Caches/bcu/shots/`，stdout 只返回文件路径和尺寸，不输出 base64。

## 诊断与服务状态

```bash
bcu status        # 只检查，不启动 Broker
bcu doctor        # 启动并检查 Broker、helper、权限和配置
bcu stop          # 停止 Broker；macOS helper 保留授权身份并继续按系统管理
```

普通命令会自动连接或按需启动 Broker。agent 不需要先调用 `status`。

## 文档

- [CLI 使用手册](./docs/usage.md)
- [配置](./docs/configuration.md)
- [故障排查](./docs/troubleshooting.md)
- [架构](./docs/architecture.md)
- [开发](./docs/development.md)

## License

MIT

最后核对：2026-07-14

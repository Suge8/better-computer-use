# Better Computer Use

`bcu` 是面向 AI agent 的 macOS 桌面操控 CLI。只要 agent 能运行 shell，就能用它观察和操作 macOS 应用，无需注入一组常驻工具 Schema。

`bcu` 可以查找窗口、读取界面结构、搜索控件、点击、输入、滚动、等待界面变化。状态、并发调度和截图文件由 `bcu.app` 里的一个常驻进程管理，`bcu` 命令是它的客户端。

网页自动化不属于 `bcu`，由 `better-browser-use` 负责；浏览器窗口对 `bcu` 只是普通的无障碍窗口。

## 适用场景

当目标应用没有可靠的 API、命令行或 MCP 接口时使用 `bcu`。如果已有直接接口，优先使用直接接口。

支持环境：

- macOS 14 或更高版本
- 从源码构建需要 Swift 6.2 工具链（Xcode 或 Command Line Tools）

## 安装

```bash
brew install --cask suge8/tap/bcu
bcu setup
```

`bcu.app` 经过 Developer ID 签名和公证；`brew upgrade` 之后下一条命令会自动换成新版本的常驻进程，授权不需要重新打开。

`bcu setup` 会按提示在“系统设置 → 隐私与安全性”中为 `/Applications/bcu.app` 打开：

- 辅助功能
- 屏幕录制（新版 macOS 显示为“屏幕与系统音频录制”）

给 agent 装上用法 skill（[friedbun](https://github.com/Suge8/friedbun) 里的 `better-computer-use`）：

```bash
npx skills add Suge8/friedbun --skill better-computer-use
```

## 快速开始

已知目标应用且窗口唯一时直接观察：

```bash
bcu observe-ui --app TextEdit
```

目标不确定或有多个窗口时，先运行 `bcu find-roots --app TextEdit`，再用返回的 `@r` 执行 `observe-ui --root @r1`。

命令会返回 `stateId` 和投影后的界面元素列表：每行是一个 `@e` ref、一个短角色词、名称、值和可用能力。后续查询与操作必须使用该状态中的 `stateId` 和 `@e` ref：

```bash
bcu search-ui --state <stateId> --text Save

echo '[{"action":"press","ref":"@e12"}]' |
  bcu act-ui --state <stateId> --expect-text Saved --timeout 3000 -
```

`act-ui` 返回的新 `stateId` 是下一次操作的输入，并只列出相对上一状态的变化。结果行的 `worked` 表示有证据证明动作生效；`unverified` 表示动作已投递但没有可读的证据（菜单命令、快捷键常见），退出码仍为 0，需要确认时加 `--expect-*`。只有被证明无效或后置条件未满足时才以 `action_failed` 失败。状态过期时重新执行 `observe-ui`。

动作打开的菜单、sheet、popover、对话框连同视图随结果返回（`opened`，带 `stateId` 与 ref），选下拉框的选项就是两条命令：按下拉框，再按返回视图里的选项。动作项也可以不写 ref，用 `find`（角色和名称，可加 `nth`、`root`）在该步执行时现找，并带自己的 `expect`，一次数组走完“打开对话框 → 填写 → 确认”：

```bash
echo '[{"action":"press","find":{"role":"button","name":"New note..."}},
       {"action":"setText","text":"Report","find":{"role":"textfield","name":"Name","root":"opened"}},
       {"action":"press","find":{"role":"button","name":"Create","root":"opened"},"expect":{"text":"note: Report","root":"state"}}]' |
  bcu act-ui --state <stateId> -
```

每条命令的完整参数用 `bcu <命令> --help` 查看，`--json` 返回同一份结果的结构化形式。

默认不取图（自动读屏的窗口除外，见下文）。需要截图时显式请求：

```bash
bcu observe-ui --app TextEdit --image always   # 或 --mode fused
```

截图写入 `~/Library/Caches/bcu/shots/`，stdout 只返回文件路径和尺寸，不输出 base64。

窗口几乎没有无障碍内容时（微信、Qt、游戏这类自绘界面），`observe-ui` 自动识别屏幕文字（中英文），每行文字成为一个 `ocr` 节点，可以直接 press；这次截的图也随结果返回路径，没有文字的区域（例如空输入框）看图按坐标点。

## 开发者构建

`scripts/install.sh` 用 Developer ID 签名构建 `/Applications/bcu.app` 并替换旧的常驻进程。命令行入口 `bcu` 由 brew 的链接提供；没装 brew 版时自己链一个：`ln -s /Applications/bcu.app/Contents/MacOS/bcu ~/.local/bin/bcu`。详见 [开发](./docs/development.md)。

## 诊断与服务状态

```bash
bcu status        # 只检查，不启动常驻进程
bcu doctor        # 按需启动并检查常驻进程、权限和配置
bcu stop          # 停止常驻进程；下一条命令会重新启动它
```

普通命令会自动连接或按需启动常驻进程，它空闲 10 分钟后退出。agent 不需要先调用 `status`。

## 文档

- 命令参考：`bcu --help` 与 `bcu <命令> --help`
- [配置](./docs/configuration.md)
- [故障排查](./docs/troubleshooting.md)
- [架构](./docs/architecture.md)
- [开发](./docs/development.md)
- [ADR：把上游 macOS engine 当引擎参考](./docs/adr/0001-upstream-tracking-fork.md)
- [ADR：运行时收口为一个 Swift 进程](./docs/adr/0002-single-swift-process.md)

## License

MIT。macOS 引擎源自 [injaneity/pi-computer-use](https://github.com/injaneity/pi-computer-use)（MIT）。后台输入投递（SkyLight）移植自 [trycua/cua](https://github.com/trycua/cua)（MIT）。

# 配置

`bcu` 读取一份用户级配置，`~/.config/bcu/config.json`。环境变量覆盖文件，命令参数覆盖单次调用。`bcu doctor --json` 打印生效值、文件路径和解析错误。

```json
{
  "headless": false,
  "cursor_overlay": true
}
```

`headless`（默认 `false`）把动作钉在后台无障碍语义上：禁用原始键鼠、窗口激活和前台回退。代价是很多应用的输入只有真实事件能触发，动作会更容易失败。单次收紧用 `bcu act-ui --headless`；全局开启后没有放宽它的参数，`act-ui --foreground` 在 `headless` 下以 `invalid_arguments` 拒绝。

`cursor_overlay`（默认 `true`）在指针动作时画一个不接收输入的 agent 光标。它不移动系统指针，也不延迟动作；`headless` 会关掉它。光标由常驻进程画，它启动时读取这项设置，改了之后运行 `bcu stop`，下一条命令按新设置启动。

环境变量：`BCU_HEADLESS`、`BCU_CURSOR_OVERLAY` 接受 `1/0`、`true/false`、`yes/no`、`on/off`、`enabled/disabled`。

`bcu` 通过 LaunchServices 启动常驻进程，系统不会把调用方的环境交给它，所以 `bcu` 把全部 `BCU_*` 变量显式转交过去。测试与开发用的变量：

- `BCU_SOCKET_PATH`：常驻进程的 socket，默认 `~/Library/Caches/bcu/resident.sock`；不同路径各自一个常驻进程。
- `BCU_IDLE_MS`：空闲多少毫秒后退出，默认 600000。
- `BCU_APP_PATH`：按需启动的 app，默认 `/Applications/bcu.app`。

运行时路径：常驻进程 socket `~/Library/Caches/bcu/resident.sock`，截图 `~/Library/Caches/bcu/shots/`，app `/Applications/bcu.app`。常驻进程按需启动，空闲 10 分钟退出。

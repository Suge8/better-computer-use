# 配置

`bcu` 读取一份用户级配置，`~/.config/bcu/config.json`。环境变量覆盖文件，命令参数覆盖单次调用。`bcu doctor --json` 打印生效值、文件路径和解析错误。

```json
{
  "headless": false,
  "cursor_overlay": true
}
```

`headless`（默认 `false`）把动作钉在后台无障碍语义上：禁用原始键鼠、窗口激活和前台回退。代价是很多应用的输入只有真实事件能触发，动作会更容易失败。单次收紧用 `bcu act-ui --headless`；全局开启后没有放宽它的参数。

`cursor_overlay`（默认 `true`）在指针动作时画一个不接收输入的 agent 光标。它不移动系统指针，也不延迟动作；`headless` 会关掉它。

环境变量：`BCU_HEADLESS`、`BCU_CURSOR_OVERLAY` 接受 `1/0`、`true/false`、`yes/no`、`on/off`、`enabled/disabled`。`BCU_DELIVERY_POLICY`（`default` / `background` / `foreground` / `ax_only`）只用于诊断投递梯子，日常调用用 `headless`。

运行时路径：Broker socket `~/Library/Caches/bcu/broker.sock`，截图 `~/Library/Caches/bcu/shots/`，helper `/Applications/bcu.app`。Broker 按需启动，空闲 10 分钟退出。

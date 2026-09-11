# 配置

`bcu` 只读取一份用户级配置：

```text
~/.config/bcu/config.json
```

环境变量覆盖配置文件。命令参数只覆盖当前调用。

## 配置示例

```json
{
  "headless": false,
  "cursor_overlay": true
}
```

运行 `bcu doctor --json` 可以查看生效值、配置文件路径和解析错误。

## 选项

### `headless`

默认值：`false`

设为 `true` 后，动作只能使用后台无障碍语义。原始键鼠事件、前台聚焦和焦点回退全部禁用。

单次调用可用 `bcu act-ui --headless` 收紧限制。CLI 不提供把全局 `headless: true` 临时放宽为 false 的参数。

### `cursor_overlay`

默认值：`true`

执行指针动作时显示一个不接收输入的 agent 光标动画。它不会移动系统指针，也不延迟动作。`headless: true` 会关闭动画。

## 环境变量

```bash
BCU_HEADLESS=0
BCU_HEADLESS=1
BCU_CURSOR_OVERLAY=0
BCU_CURSOR_OVERLAY=1
BCU_DELIVERY_POLICY=default
BCU_DELIVERY_POLICY=foreground
```

布尔变量接受 `1/0`、`true/false`、`yes/no`、`on/off`、`enabled/disabled`。

`BCU_DELIVERY_POLICY` 只用于底层投递诊断。正常调用使用 `headless` 配置或 `act-ui --headless`。

## 运行时路径

| 内容 | 路径 |
| --- | --- |
| Broker IPC | `~/Library/Caches/bcu/broker.sock` |
| 截图 | `~/Library/Caches/bcu/shots/` |
| native helper | `/Applications/bcu.app` |

Broker 默认按需启动，空闲 10 分钟后退出。`status` 只检查现状；普通命令自动连接或启动。

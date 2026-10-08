# 配置

`bcu` 读取一份用户级配置，`~/.config/bcu/config.json`。环境变量覆盖文件，命令参数覆盖单次调用。`bcu doctor --json` 打印生效值、文件路径和每个来源设置了什么。文件不是合法 JSON、有未知的键、取值类型或取值不对，或 `BCU_*` 变量取值不对时，每条命令都以 `invalid_arguments` 失败，并说明允许的键或取值。

```json
{
  "headless": false,
  "cursor_overlay": true,
  "cursor_motion": {
    "style": "signature_arc",
    "timing": "native",
    "effects": { "trail": false }
  }
}
```

`headless`（默认 `false`）把动作钉在后台无障碍语义上：禁用原始键鼠、窗口激活和前台回退。代价是很多应用的输入只有真实事件能触发，动作会更容易失败。单次收紧用 `bcu act-ui --headless`；全局开启后没有放宽它的参数，`act-ui --foreground` 在 `headless` 下以 `invalid_arguments` 拒绝。

`cursor_overlay`（默认 `true`）在指针动作时画一个不接收输入的 agent 光标。它不移动系统指针，也不延迟动作；`headless` 会关掉它。光标由常驻进程画，它启动时读取这项设置，改了之后运行 `bcu stop`，下一条命令按新设置启动。

`cursor_motion` 选 agent 光标怎么移动，同样在常驻进程启动时读取：

- `style`（默认 `signature_arc`）：`signature_arc` 一段带轻微冲过的弧线；`spring_settle` 弧线落点回弹一次；`magnetic` 靠近目标时减速再被吸入；`comet_swoop` 大弧线带拖尾；`adaptive` 小目标慢慢靠近、远距离大弧线、其余走最小加加速度路径；`classic` 原来的 Dubins 滑行加落点弹簧。
- `timing`（默认 `native`）：`native` 用样式自己的时长；`fitts` 按菲茨定律 `150 + 120·log2(距离/目标短边 + 1)` 毫秒，限制在 300–1000；`fixed` 每次 1430 毫秒。目标尺寸未知时按 24 pt 的方框算。
- `effects`：`trail` 彗星拖尾（从箭头身体拖出）、`glow` 随速度变大的光晕、`magnet` `magnetic` 吸附时目标周围的光晕、`ripple` 点击落下时的涟漪、`squish` 点击时箭头缩一下。没写的效果用样式自己的默认：`signature_arc` 开 glow/ripple/squish，`spring_settle` 开 glow/squish，`magnetic` 开 magnet/ripple，`comet_swoop` 开 trail/ripple，`adaptive` 开 squish，`classic` 全关。

系统设置里开了"减弱动态效果"时，每次移动都是 120 ms 的直线滑行，没有效果。光标从不等动作，动作也不等光标：动作照常立即投递，光标随后到达目标并在那里播放点击效果。

`headless`、`cursor_overlay` 与各效果在文件里写 JSON 布尔值，也接受下面这些字符串和 `1/0`。环境变量：`BCU_HEADLESS`、`BCU_CURSOR_OVERLAY` 接受 `1/0`、`true/false`、`yes/no`、`on/off`、`enabled/disabled`。`BCU_CURSOR_MOTION_STYLE`、`BCU_CURSOR_MOTION_TIMING` 覆盖 `style`、`timing`；`BCU_CURSOR_MOTION_EFFECTS` 写成 `trail=on,glow=off`，逐项覆盖文件里的效果。

`bcu` 通过 LaunchServices 启动常驻进程，系统不会把调用方的环境交给它，所以 `bcu` 把全部 `BCU_*` 变量显式转交过去。测试与开发用的变量：

- `BCU_SOCKET_PATH`：常驻进程的 socket，默认 `~/Library/Caches/bcu/resident.sock`；不同路径各自一个常驻进程。
- `BCU_IDLE_MS`：空闲多少毫秒后退出，默认 600000。
- `BCU_APP_PATH`：按需启动的 app，默认 `/Applications/bcu.app`。

运行时路径：常驻进程 socket `~/Library/Caches/bcu/resident.sock`，截图 `~/Library/Caches/bcu/shots/`，app `/Applications/bcu.app`。常驻进程按需启动，空闲 10 分钟退出。

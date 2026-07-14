# 性能基线

本文件冻结 G1 完成时的本机 helper 性能，后续优化使用同一脚本和目标窗口复测。

## 环境

- 日期：2026-07-14
- Commit：`75ae878b57ce189339717f3e910648e355155484`
- Helper：`/Applications/bcu.app`，arm64，本地身份 `bcu Local Signing (com.sugeh.bcu)`
- 目标窗口：TextEdit `bcu-benchmark.txt`

```text
ProductName:		macOS
ProductVersion:		26.4.1
BuildVersion:		25E253
```

## 结果

| 指标 | 基线 |
|---|---:|
| diagnostics RTT 中位数（10 次） | 0.27 ms |
| look.captureMs | 177 ms |
| look.describeMs | 40 ms |
| look.readTextMs | 243 ms |
| look 端到端 RTT | 484.22 ms |
| helper 空闲 RSS | 31.81 MiB |
| daemon 冷启动 | 103.71 ms |

Diagnostics RTT 原始样本（ms）：`0.44, 0.30, 0.29, 0.31, 0.27, 0.27, 0.21, 0.24, 0.16, 0.16`。

## 测量口径

- diagnostics RTT：冷启动完成后串行请求 10 次，每次新建 Unix socket 连接，取中位数。
- look：脚本打开固定 TextEdit 文本，以 `readText: "always"` 执行一次真实窗口观察；分段值来自 helper 返回的 `timings`，端到端 RTT 在 Node 调用侧测量。
- 空闲 RSS：diagnostics 请求全部完成、没有请求在途时，通过 `ps` 读取 helper RSS。
- 冷启动：先通过协议关闭已有 daemon，从调用 LaunchServices `open` 前开始计时，到新 daemon 首次返回协议版本正确的 diagnostics 为止。
- 冷启动和 look 各为单次样本，用于同机回归对比，不代表跨机器统计结论。

## 复测

确保 bcu 已获得辅助功能和屏幕录制权限，然后运行：

```bash
node scripts/bench.mjs
```

脚本会重启 helper、打开固定 TextEdit 基准文档，并以 JSON 输出同一组指标。

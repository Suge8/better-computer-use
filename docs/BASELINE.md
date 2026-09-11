# 性能基线

本文件记录 G1 helper 性能、G3 Broker 复测和 G5 真实任务基线。后续优化沿用相同口径。

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

## G3 Broker 复测

共享 broker 与 helper 长连接落地后，内核启动锁分支复测的 `client → broker → helper diagnostics` 往返中位数为 **1.09 ms**（目标 < 5 ms）。原始样本（ms）：`1.34, 1.02, 1.49, 0.94, 0.88, 1.09, 1.57, 1.10, 0.48, 1.48`。

复测使用当前工作区构建产物（基于 `cafabd4`），以隔离 socket 启动 broker；握手并预热一次 helper 长连接后，在同一 broker IPC 连接上串行采样 10 次。该口径包含 broker JSON-lines 往返和 broker 到持久 helper 连接的完整开销。

## v1 任务基线

测量日期为 2026-07-14。测量时 HEAD 为 `cafabd4`，工作区包含 G2–G5 实现。每轮指一次 `bcu` CLI 调用，包括失败与恢复调用；wall time 从首个 bcu 调用开始，到最终行为取证结束。outline 字节数是所有成功响应中文本视图的 UTF-8 字节总和。该口径来自旧的 `text + details` 结果契约；投影层落地后同一窗口的文本视图显著更小，两代数字不可直接比较。

| 真实任务 | 结果 | 调用轮数 | Wall time | Outline 输出字节 | 证据 |
|---|---|---:|---:|---:|---|
| TextEdit 输入文本并验证 | 成功 | 4 | 28.42 s | 2,241 | `setText` 返回 `worked`，`--expect-text` 返回 `verified` |
| Finder 重命名文件 | 失败 | 35 | 976.97 s | 662,660 | column view 产生大量占位节点；文件仍为 `before-g5.txt`，helper 经 `stop`/`doctor` 恢复 |
| 系统设置切换开关 | 成功 | 8 | 160.26 s | 31,508 | `AX_SHOW_WINDOW_TITLEBAR_ICONS` 截图验证 off → on → off，原值已恢复 |
| Finder 新建文件夹 | 成功 | 3 | 101.60 s | 19,160 | `Cmd-Shift-N` 后文件系统出现 `未命名文件夹` |
| 浏览器打开 URL 并点击 | 成功 | 5 | 80.90 s | 432 | 从 `example.com` 点击到 IANA；恢复观察得到 `Example Domains` 和目标 URL |
| 备忘录新建笔记 | 成功 | 6 | 84.02 s | 22,087 | 新笔记写入 `bcu G5 baseline 2026-07-14`，后置条件 verified，计数 176 → 177 |
| **合计** | **5/6（83.3%）** | **61** | **1,432.17 s** | **738,088** | 验收线为至少 5/6 |

这组数字是任务级 v1 绝对基线，不是理想值。Finder 重命名暴露 outline 膨胀；系统设置、Finder 新建文件夹、浏览器和备忘录还出现“动作已发生但 CLI 返回失败或超时”的假阴性。后续优化先保持成功率，再减少轮数和输出量。

## G1→G5 对比

| 指标 | G1 / 前序事实 | G5 | 结论 |
|---|---:|---:|---|
| client → broker → helper diagnostics RTT 中位数 | Flow 参考值 16.6 ms；G3 实测 1.09 ms | **1.02 ms** | 低于 `<5 ms` 门；仓库 G1 的 0.27 ms 是 helper 直连，不是同口径 |
| semantic observe CLI wall time 中位数（5 次） | 未测 | **255.93 ms** | TextEdit，`semantic + image never + read-text never` |
| semantic observe outline | 未测 | **1,371 B** | 5 次输出一致 |
| helper 空闲 RSS | 31.81 MiB | **32.23 MiB** | 同为基准脚本冷启动后的空闲口径 |
| broker 空闲 RSS | 无 Broker | **51.73 MiB** | 隔离 Broker，握手、预热和 diagnostics 后取样 |
| broker + helper 空闲 RSS | 无 Broker | **83.96 MiB** | 两个进程 RSS 相加 |

G5 diagnostics RTT 原始样本（ms）：`1.07, 0.97, 1.80, 0.75, 1.11, 1.17, 0.80, 0.86, 0.89, 1.43`。

Semantic observe wall time 原始样本（ms）：`395.53, 245.72, 242.33, 255.93, 345.40`。每次 outline 均为 `1,371 B`。

同次 `node scripts/bench.mjs` 还测得 raw helper look 端到端 `771.50 ms`（capture `327 ms`、describe `29 ms`、readText `385 ms`）和冷启动 `250.26 ms`。首次 G5 复测曾在 raw `look` 路径超时 20 秒；不改代码复查 semantic 与 fused 路径后，连续两次完整复测通过。该单次抖动保留为已知风险。

## 测量口径

- diagnostics RTT：冷启动完成后串行请求 10 次，每次新建 Unix socket 连接，取中位数。
- look：脚本打开固定 TextEdit 文本，以 `readText: "always"` 执行一次真实窗口观察；分段值来自 helper 返回的 `timings`，端到端 RTT 在 Node 调用侧测量。
- G5 semantic observe：脚本复用隔离 Broker，通过构建后的 public CLI 先执行一次 `find-roots`，再串行执行 5 次 `observe-ui --mode semantic --image never --read-text never`；wall time 包含每次 CLI 进程与完整 Broker 往返，字节数取 `result.text` 的 UTF-8 长度。
- 空闲 RSS：diagnostics 请求完成且没有请求在途时，通过 `ps` 在 semantic workload 前读取 broker 与 helper RSS。
- 冷启动：先通过协议关闭已有 daemon，从调用 LaunchServices `open` 前开始计时，到新 daemon 首次返回协议版本正确的 diagnostics 为止。
- 冷启动和 look 各为单次样本，用于同机回归对比，不代表跨机器统计结论。

## 复测

确保 bcu 已获得辅助功能和屏幕录制权限，然后运行：

```bash
node scripts/bench.mjs | tee /tmp/bcu-bench.json
python3 -c "import json;x=json.load(open('/tmp/bcu-bench.json')); assert x['semanticObserve']['medianWallMs'] > 0; assert x['semanticObserve']['medianOutlineBytes'] > 0; assert len(x['semanticObserve']['samples']) == 5"
```

脚本会重启 helper、打开固定 TextEdit 基准文档，并以 JSON 输出 diagnostics RTT、semantic observe、raw look、空闲 RSS 和冷启动指标。

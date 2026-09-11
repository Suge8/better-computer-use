# 架构

`bcu` 由薄 CLI、用户级 Broker 和 macOS native helper 组成。

```text
任意有 shell 的 agent
        │
        ▼
   bcu CLI（无状态）
        │ Unix domain socket
        ▼
   用户级 Broker
   ├─ StateStore
   ├─ ResourceScheduler
   └─ screenshot artifacts
        │
        ▼
   /Applications/bcu.app（Swift helper）
```

## 运行时模块

Broker 内的工具运行时按职责分四块：

- `src/session.ts`：operation state、资源调度、保存状态的读写与工具执行入口；
- `src/roots.ts` 与 `src/root-refs.ts`：根发现、目标选择、pairing 与稳定 `@r` 身份；
- `src/observe.ts`：observation 采集、结果渲染与全部缓存查询；
- `src/act.ts`：动作事务、投递升级、后置条件校验与后继观察。

## 职责边界

### CLI

CLI 只负责：

- 解析参数和 stdin；
- 连接或按需启动 Broker；
- 渲染文本或 JSON；
- 把稳定错误码和恢复动作写入 stderr。

CLI 不保存 UI 状态，也不直接连接 native helper。平台守卫只在 CLI 入口执行一次：非 macOS 立即返回 `unsupported_platform`。

### Broker

Broker 是运行时单一事实源，拥有：

- 不可变 observation；
- 每个资源的 epoch；
- 同资源串行调度；
- native helper 长连接；
- 截图文件生命周期；
- helper 诊断和权限 setup。

IPC 使用 Unix domain socket，目录权限为 `0700`，socket 权限为 `0600`。Broker 按需启动，空闲 10 分钟后退出。

### Native helper

helper 负责系统事实和输入投递：

- Accessibility、ScreenCaptureKit、Vision；
- element grounding、遮挡检查、动作验证；
- 全局物理键鼠互斥。

helper 必须保留 `.app` 身份。TCC 授权绑定 bundle id 和代码签名身份，AppKit 也需要自己的主运行循环。把这部分合并进 Node 进程会让授权归因到启动终端。

## 启动与退出

普通命令执行 connect-or-start：

1. 连接现有 IPC；
2. 失败后获取用户级启动锁；
3. 锁内再次检查；
4. 唯一胜者启动 `bcu __serve`；
5. Broker 监听成功后通过私有 ready fd 发事件；
6. CLI 发出请求。

启动路径不使用 sleep 或重试轮询。`status` 只连接现有 Broker，`stop` 只停止现有 Broker。

Broker 退出时关闭状态与调度器。helper 继续由系统管理，以保留稳定的 TCC 身份和下次调用的低延迟。

## 状态模型

标准数据流是：

```text
find-roots → observe-ui → cached query → act-ui → successor state
```

`find-roots` 返回 `@r`。`observe-ui` 生成不可变 `stateId` 和属于该状态的 `@e`。每个请求从 `stateId` hydrate 一份 request-local operation state，不存在跨请求共享的“当前窗口”。

StateStore 有四道容量边界：

- 最大记录数；
- 最大总字节数；
- 单条最大字节数；
- TTL。

写入时清理过期和超容量记录。单条状态超过上限时显式返回 `state_too_large`，不会截断后假装成功。

保存桌面状态时只保留图片的宽、高和 MIME 元数据。JPEG/PNG 字节写入截图文件，不进入 StateStore。

## 截图 artifact

helper 通过 native 协议返回 base64。Broker 在响应 CLI 前完成以下步骤：

1. 解码图片；
2. 写入 `shots/<stateId>.jpg`；
3. 设置目录 `0700`、文件 `0600`；
4. 删除结果中的 base64；
5. 返回路径、MIME 和尺寸。

清理在新截图写入时执行，不创建后台清理 timer。同一 artifact 目录的写入与清理由 Broker 内 Promise 队列串行化，避免并发 agent 在枚举、stat、删除之间互相破坏；不同目录仍可并行。只有性能数据证明 native 直写文件有显著收益时，才需要改 helper 协议。

## 并发与 stale state

ResourceScheduler 按物理资源维护单调递增 epoch：

- 资源按应用进程 PID 分 lane；
- 缓存查询不进入调度器；
- 不同 lane 可并行；
- 同一 lane 的实时工作顺序执行。

mutation 必须携带 observation 对应的 epoch。两个调用从同一状态并发写入时，第一个调用先递增 epoch；第二个调用在投递前收到 `stale_state`。不确定是否已经执行的物理动作不会自动重放。

全局物理键鼠仍由 native helper 串行保护，因为一个桌面会话只有一个指针和键盘焦点。不同应用的无障碍语义操作可以并行。

## Observation

observation 包含：

- 根节点身份和窗口几何；
- Accessibility outline；
- 可选图片和 OCR；
- helper timings；
- 完整序列化 outline。

首次结果返回折叠后的完整视图。`search-ui`、`expand-ui`、`inspect-ui` 查询完整缓存。截断节点需要扩展时，Broker 在相同 epoch 上做 scoped look，不能把并发 mutation 后的数据 graft 到旧状态。

`observe-ui` 默认 `fused`。`semantic` 默认不取图、不做 OCR。`act-ui` 的后继观察默认 `semantic + no-image`，显式 `--image always` 才生成截图。

## Action transaction

`act-ui` 接收一个动作数组。数组内步骤共享同一 base state 和资源锁，按顺序验证。能够表达完成条件时，调用方把 `--expect-text`、`--expect-role` 或 `--expect-value` 附在同一事务中，避免独立等待和额外模型轮次。

helper 返回 `worked`、`didnt` 或 `unknown`，并附投递与验证证据。只有 `worked` 能作为 CLI 成功结果；`didnt`、`unknown` 和后置条件失败统一变成 `action_failed`，stdout 为空，调用方必须重新观察。可信的小变更返回 successor diff；根替换、身份置信度不足或变更过大时返回完整折叠视图。

`headless` 是严格边界。启用后禁止窗口激活、焦点切换、原始键鼠和前台回退。

## 浏览器窗口

浏览器窗口是普通的 AX 窗口，没有专用代码路径。页面级自动化由 `flow-browser-use` 负责。

## 错误契约

Broker 把 native、运行时和 IPC 错误归一到 [`src/errors.ts`](../src/errors.ts) 的稳定代码。CLI 失败时 stdout 为空，stderr 输出：

```text
error <code>: <message>
recovery: <next action>
```

真实失败不会降级为成功。调用方根据错误码决定重新观察、重新授权、修复 helper 或停止任务。

# 运行时收口为一个 Swift 进程

现状是三个进程、两层协议：Node CLI → Node Broker（Unix socket）→ Swift helper（Unix socket）。AX 元素句柄只能活在 helper 里，所以同一份事实被存了几遍：

- 根身份两套：helper 的窗口引用表，Broker 的 `@r` 表（没有窗口 id 时靠标题加几何猜同一个窗口）；
- 观察记录两套生命周期：helper 保留最近 8 次 look，Broker 的 StateStore 另按条数、字节、TTL 淘汰，Broker 仍有效的 stateId 在 helper 那边可能已被丢掉；
- helper 的元素引用表只增不减，常驻进程内存随使用增长；
- 线协议类型 Swift 发一份、TS 手写解析一份；helper 的错误码经 `ERROR_CODE_ALIASES` 再映射成 CLI 错误码。

决定：运行时收口为 `bcu.app` 里的一个 Swift 常驻进程，`bcu` CLI 是同一个可执行文件的客户端模式。

- 常驻进程拥有全部运行时事实：状态库（stateId → 一次观察，含 AX 句柄与投影）、根注册表、按 pid 串行的调度、投递梯子、投影与变化计算。元素引用属于生成它的状态，随状态一起淘汰，不再有全局引用表。
- CLI 只解析参数、连接或按需启动常驻进程（`open -n -g bcu.app --args serve`，保留 TCC 授权绑定的 bundle 身份）、打印结果。请求与结果类型只在 Swift 里定义一份（Codable），客户端与常驻进程共用。
- 用 SwiftPM 构建：纯逻辑（大纲模型、投影、搜索、变化、契约类型、错误、CLI 解析与渲染）是一个不依赖 AppKit 的库目标，用 swift-testing 测；平台部分（AX、截图、OCR、SkyLight 投递、agent 光标）按职责拆文件，不再是单个大文件。
- 真机门保留为 Node 脚本，只通过 CLI 黑盒调用，收口前后必须同样全绿；白盒的 TS 单元门随对应 TS 模块一起换成 Swift 测试。Node 从运行时依赖降为只在跑真机门时需要的开发依赖。
- 分发从 npm link 改为仓库内安装脚本：`swift build -c release`、装进 `/Applications/bcu.app`、用本机稳定证书签名、把 `bcu` 链接到 PATH。

分两步落地，每步独立可验收：

1. 纯逻辑移植：建 SwiftPM 包与纯逻辑库，用当前 TS 实现在现有 fixture 上生成金标输出，Swift 实现必须逐字节一致。这一步不改变运行时。
2. 运行时切换：Broker 的职责并入 Swift 常驻进程，CLI 换成 Swift 客户端，删除 Node Broker、TS 源码、esbuild 构建与只测中间层的门。黑盒真机门与 CLI 错误门原样全绿即通过。

拒绝：保留 Node Broker、只让 helper 做唯一状态源。改动小，但中间层和两份类型定义都还在，协议版本仍要两边同步。

拒绝：保持现状只修引用泄漏与淘汰对齐。那是给双事实源打补丁，下一次两边再分叉时还会出同类问题。

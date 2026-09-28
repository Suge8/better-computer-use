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

Broker 内的工具运行时按职责分块：

- `src/session.ts`：operation state、资源调度、保存状态的读写与工具执行入口；
- `src/roots.ts` 与 `src/root-refs.ts`：根发现、目标选择、pairing 与稳定 `@r` 身份；
- `src/observe.ts`：observation 采集、结果组装与全部缓存查询；
- `src/projection.ts`：唯一的 agent 视图——把 outline 投影为 `ProjectedNode[]`，并渲染文本行；
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

根的身份由 helper 的 root reference 承载，`look` 只按它定位。窗口 id 是窗口的一个属性，仅用于截图；菜单栏、菜单、sheet 和 popover 往往没有窗口 id，只能通过 root reference 观察。root reference 失效时 helper 直接返回 `root_not_found`，不会退回到应用的其他窗口。

每个有菜单栏的应用暴露一个 `kind: "menubar"` 根（指向 AXMenuBar），它是应用全部命令的入口：`observe-ui --root @rN` 返回菜单栏项的投影，press 其中一项就打开对应菜单。菜单栏只在前台应用身上生效，背景应用的菜单栏项接受 AXPress 却不做事，因此 helper 把它当作 `foreground_required`，由投递梯子激活应用后重试。菜单栏和桌面一样：可以被指名观察，bcu 不会替 agent 默选它，也不会出现在无过滤的 `find-roots` 里。

菜单栏的 observation 故意遍历全部子菜单（TextEdit 约 350 节点、450 ms）：闭合菜单里的项因此能被 `search-ui` 找到并直接 press，一步就能执行一条菜单命令，不必先打开父菜单再观察一次。这份遍历只发生在被指名观察菜单栏根时。

StateStore 有四道容量边界：

- 最大记录数；
- 最大总字节数；
- 单条最大字节数；
- TTL。

写入时清理过期和超容量记录。单条状态超过上限时显式返回 `state_too_large`，不会截断后假装成功。

保存桌面状态时只保留图片的宽、高和 MIME 元数据。JPEG/PNG 字节写入截图文件，不进入 StateStore。

## 截图 artifact

helper 通过 native 协议返回 base64。只有显式要求图片时，Broker 在返回结果前完成以下步骤：

1. 解码图片；
2. 写入 `shots/<stateId>.jpg`；
3. 设置目录 `0700`、文件 `0600`；
4. 结果只带 `image: {path, mime, width, height}`，不含 base64。

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

完整 outline 只存在 StateStore 里；命令返回的是它的投影。`search-ui`、`expand-ui`、`inspect-ui` 仍然查询完整缓存，因此被投影省略或折叠的节点照样可达。截断节点需要扩展时，Broker 在相同 epoch 上做 scoped look，不能把并发 mutation 后的数据 graft 到旧状态。

`observe-ui` 默认 `--mode semantic --read-text auto`：窗口有无障碍内容时不取图、不做 OCR，延迟与只走无障碍一样（TextEdit、Chrome、Ghostty 实测 captureMs 与 readTextMs 均为 0）。窗口的无障碍内容少于 2 个节点时，helper 自动截图并做 OCR，这样微信、Qt、游戏这类自绘窗口仍能用同一个 observe → act 循环操作。计数不含红绿灯按钮和标题栏自己的图标与标题文字，只数有名称或可操作的节点。阈值按 macOS 27 实测标定：微信、IINA、自绘按钮夹具都是 0，Ghostty 终端 3，TextEdit 约 40，Chrome 窗口 16 以上。`--read-text never` 关掉它，`always` 总是做。`--mode fused` 或 `--image always` 才产生截图文件。`act-ui` 的后继观察沿用同一策略，自绘窗口按完之后仍看得到 OCR 节点。

OCR 用 Vision 识别简体、繁体中文与英文（不设语言时只识别拉丁文字，中文界面会是空的）。同一行文字已被无障碍说出（某个相交节点的标题、值或描述包含它）时丢弃；其余每行成为一个独立节点，挂在包含它中心点的最深节点下。实测（M 系列，热启动）：微信主窗口截图约 60 ms、OCR 约 190 ms，`observe-ui` 端到端约 0.4 s，得到 47 个 OCR 节点；IINA 窗口 OCR 约 80 ms。

## 投影

`src/projection.ts` 是 agent 看到的唯一视图，文本与 `--json` 渲染同一组 `ProjectedNode`：

- role 用短词表，去掉 `AX` 前缀，subrole 更具体时优先（`AXWindow/AXStandardWindow` → `window`）；
- caps 只能取固定词表（press、toggle、setText、typeText、menu、open、expand、scroll、increment、decrement、raise），其余 AX action 一律不外泄；
- 从屏幕读出的文字 role 固定为 `ocr`，caps 只有 `press`：它没有无障碍元素，只能按坐标点击，不能 setText 或 typeText；`search-ui --role ocr` 与 `inspect-ui` 看到的是同一个节点；
- name 取 title、description，其次是被包裹的文本，最后才是非内部标识的 identifier；
- 没有名称、能力和状态的节点消失；结构性容器把子节点提升；只包裹文本的条目折成一行并合并能力；
- 首屏按字节预算逐层展开：焦点所在的子树始终展开，其余用 `▸ N hidden: role×n` 概括，可用 `expand-ui` 继续打开；`--json` 的 `nodes` 与文本视图展示的是同一组节点，被折叠的后代只由 `hidden: {count, roles}` 概括。

caps 是对该 ref 的承诺。条目折叠会把子节点的能力合并到外层 ref 上，这时投影同时记录 `owners`（capability → 真正执行它的 ref）。`act-ui` 收到语义动作时按 `owners` 解析到拥有者再投递，坐标类动作仍用渲染 ref 的几何；`inspect-ui` 输出同一份 `owners` 映射。

## 投递梯子

同一个动作按代价从低到高投递，越靠前越不打扰用户：

1. 后台无障碍语义（`ax_only`）——直接对元素执行 AX 动作，不激活窗口、不动指针；原生文本视图等需要真实指针放置插入点的角色由 helper 判定并要求升级，元素身份始终跟着动作走，动作结果才有证据可依；
2. 后台原始输入（`pid`）——经 SkyLight 私有接口 `SLEventPostToPid` 把事件投递给目标进程（移植自 [trycua/cua](https://github.com/trycua/cua)，MIT），不抢前台、不动真实指针、不改窗口层叠；
3. 前台原始输入（`hid`）——激活窗口后走系统事件流，只在前两级失败或动作本身需要真实焦点时使用。

为输入而激活、置顶或切换 key window 是 bcu 自己做的，这些变化在投递前计入基线，不算动作的证据；窗口"持有焦点"也不算点击落点的证据。对于没有 AX 元素可读回的 OCR/坐标点击，投递后在最多 600 ms 内重新截图，排除标题栏后比较内容区：超过 0.5% 像素的通道变化（通道差超过 30）记为 `worked`，证据为 `source: screen`，CLI 写作 `screen changed`。截图不含真实鼠标和 agent 光标覆盖层。没有变化仍是 `unknown`，不会重放。屏幕证据可能被无关动画、通知或新消息误判，因此只用于没有 AX 读回的目标，且阈值和上限固定。

升级只有一条规则：某一级证明自己什么都没改变（`didnt`），或 helper 明确要求 `foreground_required`，才交给下一级。`unknown` 不升级：那一级已经投递，再投一次可能让动作生效两次——Chromium 的 AXPress 本身就会派发 mousedown、mouseup 与 click，对不可聚焦元素再点一次实测会触发两次。`unknown` 以 `action_failed` 结束，recovery 提示动作可能已经生效、先重新观察再决定是否重试。这条规则在 helper 内部（ax → pid）和 Broker 里（后台 → 前台）是同一条。`headless` 把梯子钉死在第一级。

第二级为什么用私有接口：公开的 `CGEvent.postToPid` 不经过 WindowServer 的活动监视，Chromium 不把这类事件当真实输入。SkyLight 这一级做三件事：

- 键盘事件在 macOS 15+ 附上 `SLSEventAuthenticationMessage`（Chromium 据此信任后台按键）；带 command 的组合键不附，否则会绕过菜单快捷键的派发路径；
- 网页坐标点击走 SkyLight；原生自绘窗口先用 `SLPSPostEventRecordTo` 借用目标窗口的 AppKit 激活状态，再走 SkyLight 点击。实测即使 `acceptsFirstMouse` 为 false 的自绘夹具也能收到点击，且 Finder 仍保持 WindowServer 前台、窗口层叠不变。结果用上面的屏幕证据判定；无变化是 `unknown`，不再自动重放或升级到前台。私有接口不可用时仍返回 `foreground_required`。
- 网页里的滚动用滚轮：Chromium 不给可滚动元素暴露滚动动作，祖先的滚动动作滚的是整页，所以在元素上方发一次带窗口路由的滚轮事件。滚动的证据是元素内容相对元素的位置变化；Chromium 把直接子元素的 frame 裁剪到滚动区域，只有更深的后代会移动；
- 点击按 Chromium 配方投递：先在目标点发 mouseMoved，再在屏外 (-1,-1) 按下抬起一次通过用户激活检查，最后在目标点按下抬起；每个事件写入目标 pid、窗口 id 与同一个点击组 id，窗口坐标相对窗口左上角；
- 投递给进程的输入只到达它的 key window。目标窗口不是 key window 时，先向该进程发 yabai 的 focus-without-raise 事件记录（`SLPSPostEventRecordTo`），让它成为 key window 而不激活应用、不置顶窗口；这次切换计入动作前的基线，不会被当成动作本身的效果。

任一私有符号解析失败时，第二级直接返回 `foreground_required`，没有公开接口的回退路径。

## Action transaction

`act-ui` 接收一个动作数组。数组内步骤共享同一 base state 和资源锁，按顺序验证。能够表达完成条件时，调用方把 `--expect-text`、`--expect-role` 或 `--expect-value` 附在同一事务中，避免独立等待和额外模型轮次。

helper 返回 `worked`、`didnt` 或 `unknown`，并说明理由。判定按证据强弱排序：

1. 目标元素自身的事实移动了——AXValue、AXSelected、AXFocused、选区或插入点——`worked`，`verification.evidence` 记下是哪个字段、从什么变成什么；
2. 指针确实落在该元素上（命中测试通过）且动作后它持有键盘焦点——`worked`；只移动插入点的点击没有别的痕迹；
3. 根森林发生变化（菜单打开、sheet 出现、窗口易主）——`worked`；
4. 元素是有值的切换类控件（checkbox、radio、segment、switch、disclosure）而值没动——`didnt`，错误信息带上停在哪个值；
5. 其余——`unknown`，不伪装成成功。

投影里带 `toggle` 能力的元素就是 helper 按第 4 条判定的那一类，两侧取同一组 role 与 subrole。文本视图把证据接在结果行上，例如 `worked via ax · value 0→1`。

只有 `worked` 能作为 CLI 成功结果；`didnt`、`unknown` 和后置条件失败在 `src/act.ts` 内直接抛出 `action_failed`，stdout 为空，调用方必须重新观察。`--scope @eN` 把后置条件限定在一个子树内。变化行必须说出变了什么：值和名字按原格式，状态写成它变成了什么（`~ @e51 onscreen`、`~ @e51 focused`）。只是 offscreen↔onscreen 翻转、而该节点本来就不在首屏视图里的变化不输出。

可信的小变更返回 successor diff（`changes`）；根替换、身份置信度不足或变更过大时返回完整折叠视图（`nodes`）。

动作打开的根跟结果一起回来：helper 已经为判定 outcome 等过根森林的变化，`act-ui` 把新出现的根经 `src/root-refs.ts` 铸成稳定 `@r`，以 `roots: [{ref, kind, app, title}]` 返回，文本视图写作 `+ root @r12 menu "文件"`。按完菜单栏项的 agent 直接 `observe-ui --root @r12`，不需要再 `find-roots`，也就没有“动作刚发出、发现还没看到新根”的竞态。

`headless` 是严格边界。启用后禁止窗口激活、焦点切换、原始键鼠和前台回退。

## 已知局限

- 网页内容里判定只看无障碍证据。可聚焦的元素按下后获得焦点，这就是按下的证据；不可聚焦、按下后自身无变化的元素结果是 `unknown`，调用方用 `--expect-*` 表达完成条件或重新观察。
- 第二级依赖未公开的 SkyLight 接口，macOS 升级可能改变它们的行为；`BCU_LIVE=1 node scripts/check-web-background.mjs` 在真实 Chrome 上逐格验证按钮、输入框、打字、按键、坐标点击、滚动、多窗口打字都在后台完成，无证据的按下恰好生效一次并如实失败。

## 测量

首屏视图大小用 fixture 复现，不需要真机：

```bash
node scripts/check-projection.mjs
```

它渲染 `scripts/fixtures/` 里两份真机 outline（TextEdit 一个文档窗口、Finder 一个文件夹窗口）。投影层落地前同样两个窗口的文本视图是 1517 和 4683 字节（基线 `b97686f`），现在是 491 和 704 字节。

端到端时延直接量命令本身：

```bash
time bcu observe-ui --app TextEdit
```

## 浏览器窗口

浏览器窗口是普通的 AX 窗口，没有专用代码路径：网页里的按钮、输入框、打字和按键走同一条投递梯子，在后台完成。页面级自动化（DOM、网络、脚本）由 `better-browser-use` 负责。

## 结果契约

每条命令返回一个顶层 JSON 对象，没有 `ok`/`result`/`text`/`details` 外壳；类型定义在 [`src/contract.ts`](../src/contract.ts)。除 `find-roots` 外都带 `stateId`。文本视图由 CLI 从同一个对象渲染，Broker 不再传第二份视图。

## 错误契约

每个失败路径在抛出点就带明确错误码（`BcuError`，或 helper 的 code 经 `ERROR_CODE_ALIASES` 映射）。没有码的错误一律是 `internal_error`，代表真实缺陷。CLI 失败时 stdout 为空，stderr 输出：

```text
error <code>: <message>
recovery: <next action>
```

真实失败不会降级为成功。调用方根据错误码决定重新观察、重新授权、修复 helper 或停止任务。recovery 默认由错误码决定，经 Broker 原样传到 CLI；act-ui 投递途中 helper 失联时仍报 `helper_unavailable`，但 recovery 改为说明动作可能已经生效、修好 helper 后先重新观察再决定是否重试。

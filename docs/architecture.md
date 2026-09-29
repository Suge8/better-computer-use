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
- `src/roots.ts` 与 `src/root-refs.ts`：根发现、目标选择与稳定 `@r` 身份；
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

`find-roots` 返回 `@r`；`--app` 有精确名称匹配的应用时只取它们（`Google Chrome` 不带上 `Google Chrome for Testing`），否则按包含匹配。`observe-ui` 生成不可变 `stateId` 和属于该状态的 `@e`。`stateId` 是 8 位十六进制随机 id：每条命令都带它，所以要短；StateStore 铸造时避开仍保存着的 id，32 位随机数也让 Broker 重启前的旧 id 几乎不可能撞上新状态。每个请求从 `stateId` hydrate 一份 request-local operation state，不存在跨请求共享的“当前窗口”。

根的身份由 helper 的 root reference 承载，`look` 只按它定位。窗口 id 是窗口的一个属性，仅用于截图；菜单栏、菜单、sheet 和 popover 往往没有窗口 id，只能通过 root reference 观察。root reference 失效时 helper 直接返回 `root_not_found`，不会退回到应用的其他窗口。

每个有菜单栏的应用暴露一个 `kind: "menubar"` 根（指向 AXMenuBar），它是应用全部命令的入口：`observe-ui --root @rN` 返回菜单栏项的投影，press 其中一项就打开对应菜单。菜单栏只在前台应用身上生效：背景应用的菜单栏项、以及菜单栏下（包括闭合菜单里）的菜单项都接受 AXPress 却不做事，因此 helper 对它们返回 `foreground_required`，由投递梯子激活应用后再按；`headless` 不能激活，直接以 `action_failed` 结束。AppKit 只在菜单打开时校验菜单项，闭合菜单里的项报告的是上次的启用状态，按一个实际已禁用的项同样被接受后丢弃；所以按闭合菜单里的项之前，helper 先逐级打开它上面的菜单（等 `AXMenuOpened`），项仍禁用时以 `action_failed` 报出并关掉菜单，否则按下，菜单随之关闭。

激活和打开菜单都是 bcu 自己做的，不算动作的证据：根基线在激活完成后才取，事件游标越过 bcu 打开菜单的通知，根的变化等 bcu 打开的菜单关上后才比较。菜单项的 AXSelected 是高亮，AppKit 会把它留在最后按过的项上，不作证据；菜单栏项的 AXSelected 是它的菜单已打开，仍作证据。别的应用接管前台也不作证据：激活回让和用户操作都会产生它。菜单栏和桌面一样：可以被指名观察，bcu 不会替 agent 默选它，也不会出现在无过滤的 `find-roots` 里。

菜单栏的 observation 故意遍历全部子菜单（TextEdit 约 350 节点、450 ms）：闭合菜单里的项因此能被 `search-ui` 找到并直接 press，一步就能执行一条菜单命令，不必先打开父菜单再观察一次。这份遍历只发生在被指名观察菜单栏根时。

StateStore 有四道容量边界：

- 最大记录数；
- 最大总字节数；
- 单条最大字节数；
- TTL。

写入时清理过期和超容量记录。单条状态超过上限时显式返回 `state_too_large`，不会截断后假装成功。

保存桌面状态时只保留图片的宽、高和 MIME 元数据。JPEG/PNG 字节写入截图文件，不进入 StateStore。

## 截图 artifact

helper 通过 native 协议返回 base64，只在显式要求图片（`--image always`、`--mode fused`）或它自动读屏时回传。收到图片时，Broker 在返回结果前完成以下步骤：

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

`observe-ui` 默认 `--mode semantic --read-text auto`：窗口有无障碍内容时不取图、不做 OCR，延迟与只走无障碍一样（TextEdit、Chrome、Ghostty 实测 captureMs 与 readTextMs 均为 0）。窗口的无障碍内容少于 2 个节点时，helper 自动截图并做 OCR，这样微信、Qt、游戏这类自绘窗口仍能用同一个 observe → act 循环操作。计数不含红绿灯按钮和标题栏自己的图标与标题文字，只数有名称或可操作的节点。阈值按 macOS 27 实测标定：微信、IINA、自绘按钮夹具都是 0，Ghostty 终端 3，TextEdit 约 40，Chrome 窗口 16 以上。`--read-text never` 关掉它，`always` 总是做。截了图的观察都把截图文件交给 agent（结果带 `image`，文本视图末行 `image <path> (WxH)`）：OCR 读不到空输入框这类无字区域，agent 要看图按坐标点；没截图的窗口不会为此多截。`act-ui` 的后继观察沿用同一策略，自绘窗口按完之后仍看得到 OCR 节点和截图。

OCR 用 Vision 识别简体、繁体中文与英文（不设语言时只识别拉丁文字，中文界面会是空的）。同一行文字已被无障碍说出（某个相交节点的标题、值或描述包含它）时丢弃；其余每行成为一个独立节点，挂在包含它中心点的最深容器下；红绿灯按钮和已有名称的叶子控件不算容器，压在它们上面的文字挂到持有它们的元素下。实测（M 系列，热启动）：微信主窗口截图约 60 ms、OCR 约 190 ms，`observe-ui` 端到端约 0.4 s，得到 47 个 OCR 节点；IINA 窗口 OCR 约 80 ms。

## 投影

`src/projection.ts` 是 agent 看到的唯一视图，文本与 `--json` 渲染同一组 `ProjectedNode`：

- role 用短词表，去掉 `AX` 前缀，subrole 更具体时优先（`AXWindow/AXStandardWindow` → `window`）；
- caps 只能取固定词表（press、toggle、setText、typeText、menu、open、expand、scroll、increment、decrement、raise），其余 AX action 一律不外泄；
- 网页内容（AXWebArea 及其后代）和菜单项、菜单栏项不带 `menu`：Chromium 给每个网页节点都挂 AXShowMenu，每个菜单项都答 AXPick，它们不打开 agent 会选的东西；
- 网页里的滚动容器带 `scroll`：Chromium 不给它暴露滚动动作，但把不含可聚焦内容的滚动容器设为可聚焦，所以网页里可聚焦、不能按、不收文本的节点（webarea 本身除外）就是它，`act-ui` 在它上方发一次滚轮。含可聚焦子元素的滚动容器在无障碍树里认不出来，不带 `scroll`，对它 scroll 照样能滚；
- 从屏幕读出的文字 role 固定为 `ocr`，caps 只有 `press`：它没有无障碍元素，只能按坐标点击，不能 setText 或 typeText；`search-ui --role ocr` 与 `inspect-ui` 看到的是同一个节点；
- name 取 title、description，其次是被包裹的文本，最后才是非内部标识的 identifier；
- 没有名称、能力和状态的节点消失；结构性容器把子节点提升；只包裹文本的条目折成一行并合并能力；
- 文本输入框（textarea、textfield 等）的值已经说出了它的文字，它下面只由文字组成的后代（编辑器按行、按段拆出的 text 与包着它们的结构容器）不逐行投影，折成一句 `▸ N lines, read-text @eN`，`--json` 里是该节点的 `lines: N`；链接、按钮等非文字后代照常显示。折掉的行仍由输入框代表，`search-ui` 搜到它们时返回输入框，全文用 `read-text`；
- 首屏按字节预算逐层展开：焦点所在的子树始终展开，其余用 `▸ N hidden: role×n` 概括，可用 `expand-ui` 继续打开；`--json` 的 `nodes` 与文本视图展示的是同一组节点，被折叠的后代只由 `hidden: {count, roles}` 概括。

caps 是对该 ref 的承诺。条目折叠会把子节点的能力合并到外层 ref 上，这时投影同时记录 `owners`（capability → 真正执行它的 ref）。`act-ui` 收到语义动作时按 `owners` 解析到拥有者再投递，坐标类动作仍用渲染 ref 的几何；`inspect-ui` 输出同一份 `owners` 映射。`search-ui --action` 按同一份 caps 过滤，只收词表里的能力词。

## 投递梯子

同一个动作按代价从低到高投递，越靠前越不打扰用户：

1. 后台无障碍语义（`ax_only`）——直接对元素执行 AX 动作，不激活窗口、不动指针；原生文本视图等需要真实指针放置插入点的角色由 helper 判定并要求升级，元素身份始终跟着动作走，动作结果才有证据可依；
2. 后台原始输入（`pid`）——经 SkyLight 私有接口 `SLEventPostToPid` 把事件投递给目标进程（移植自 [trycua/cua](https://github.com/trycua/cua)，MIT），不抢前台、不动真实指针、不改窗口层叠；
3. 前台原始输入（`hid`）——激活窗口后走系统事件流，只在前两级失败或动作本身需要真实焦点时使用。

为输入而激活、置顶或切换 key window 是 bcu 自己做的，这些变化在投递前计入基线，不算动作的证据；窗口"持有焦点"也不算点击落点的证据。

坐标先落到元素上：命中点的元素沿父链最多上溯三层，取第一个可 AXPress 的控件作为动作的主体（最深的命中通常是控件里的文字标签）；系统级命中测试落在别的进程或只落在窗口上时，改在目标根里取包含该点的最小元素。在原生的离散控件（按钮、复选框、单选、弹出按钮、菜单项、展开三角）上的一次普通左键单击，与按它的 ref 走同一条梯子，从后台 AXPress 开始；网页内容保留指针，因为 Chromium 的指针路径精确，而它的 AXPress 分不出是否生效。

证据按主体取，不按投递方式取。主体有按下会移动的 AX 事实（值、选中状态、文本选区）时，只用 AX 读回判定。主体没有这类事实时（OCR 节点、自绘区域、没有值的普通按钮），元素证据和根变化都没有结论后，才用屏幕证据：投递后在最多 600 ms 内每 80 ms 截一次图，排除标题栏后比较内容区，超过 0.5% 像素的某个通道变化超过 30，记为 `worked`，证据为 `source: screen`，CLI 写作 `screen changed`。截图不含真实鼠标和 agent 光标覆盖层；标题栏按窗口实际缩放比例排除。屏幕证据可能把焦点环、无关动画、通知或新消息误判为动作效果，这是它排在最后、且只用于没有 AX 读回的主体的原因。

升级只有一条规则：某一级证明自己什么都没改变（`didnt`），或 helper 明确要求 `foreground_required`，才交给下一级。`unknown` 不升级：那一级已经投递，再投一次可能让动作生效两次——Chromium 的 AXPress 本身就会派发 mousedown、mouseup 与 click，对不可聚焦元素再点一次实测会触发两次。`unknown` 也不算失败，结果写作 unverified（见下节）。这条规则在 helper 内部（ax → pid）和 Broker 里（后台 → 前台）是同一条。`headless` 把梯子钉死在第一级。

第二级为什么用私有接口：公开的 `CGEvent.postToPid` 不经过 WindowServer 的活动监视，Chromium 不把这类事件当真实输入。SkyLight 这一级做三件事：

- 键盘事件在 macOS 15+ 附上 `SLSEventAuthenticationMessage`（Chromium 据此信任后台按键）；带 command 的组合键不附，否则会绕过菜单快捷键的派发路径；
- 坐标指针事件走 SkyLight。原生窗口先用 `SLPSPostEventRecordTo` 只告诉目标进程它处于激活状态，再投递点击（yabai 与 cua 的做法会先让当前前台进程失焦，实测会让用户的前台应用交出 key window 与激活状态，用户接着打的字会丢，所以不发这一半）：`acceptsFirstMouse` 为 false 的视图因此也收得到后台窗口上的第一次点击，而 WindowServer 前台、用户前台应用的 key window 和窗口层叠都不变（真机门用一个记录自己失去 key 的前台应用验证）；
- 网页里的滚动用滚轮：Chromium 不给可滚动元素暴露滚动动作，祖先的滚动动作滚的是整页，所以在元素上方发一次带窗口路由的滚轮事件。滚动的证据是元素内容相对元素的位置变化；Chromium 把直接子元素的 frame 裁剪到滚动区域，只有更深的后代会移动；
- 点击按 Chromium 配方投递：先在目标点发 mouseMoved，再在屏外 (-1,-1) 按下抬起一次通过用户激活检查，最后在目标点按下抬起；每个事件写入目标 pid、窗口 id 与同一个点击组 id，窗口坐标相对窗口左上角；
- 投递给进程的输入只到达它的 key window。目标窗口不是 key window 时，先向该进程发 yabai 的 focus-without-raise 事件记录（`SLPSPostEventRecordTo`），让它成为 key window 而不激活应用、不置顶窗口；这次切换计入动作前的基线，不会被当成动作本身的效果。

任一私有符号解析失败时，第二级直接返回 `foreground_required`，没有公开接口的回退路径。

## Action transaction

`act-ui` 接收一个动作数组。数组内步骤共享同一 base state 和资源锁，按顺序验证。数组只放互不依赖中间 UI 的动作：某步 `unknown` 时继续下一步，某步 `didnt` 时中止。能够表达完成条件时，调用方把 `--expect-text`、`--expect-role` 或 `--expect-value` 附在同一事务中，避免独立等待和额外模型轮次。

helper 返回 `worked`、`didnt` 或 `unknown`，并说明理由。判定按证据强弱排序：

1. 目标元素自身的事实移动了——AXValue、AXSelected、AXFocused、选区或插入点——`worked`，`verification.evidence` 记下是哪个字段、从什么变成什么；
2. 指针确实落在该元素上（命中测试通过）且动作后它持有键盘焦点——`worked`；只移动插入点的点击没有别的痕迹；
3. 根森林发生变化（菜单打开、sheet 出现、窗口易主）——`worked`；
4. 元素是有值的切换类控件（checkbox、radio、segment、switch、disclosure）而值没动——`didnt`，错误信息带上停在哪个值；
5. 其余——`unknown`：已经投递，但没有证据判定，既不伪装成成功，也不当成失败。

投影里带 `toggle` 能力的元素就是 helper 按第 4 条判定的那一类，两侧取同一组 role 与 subrole。文本视图把证据接在结果行上，例如 `worked via ax · value 0→1`。

只有被证明无效的动作才失败：`didnt` 和后置条件未满足在 `src/act.ts` 内抛出 `action_failed`，退出码 9，stdout 为空。`unknown` 退出 0，结果行写作 `unverified via ax`，照常返回后继状态和变化，没有变化时写出 `(no element changes)`；`--json` 的 `outcome` 仍是 `"unknown"`。菜单命令、没有可读效果的快捷键、自绘窗口里的按下都落在这里，它们大多已经生效，逼 agent 为每一个再观察一轮得不偿失。带 `--expect-*` 且条件满足时结果是 `worked`：后置条件就是那份缺失的证据。`--scope @eN` 把后置条件限定在一个子树内。变化行必须说出变了什么：值和名字按原格式，状态写成它变成了什么（`~ @e51 onscreen`、`~ @e51 focused`）。只是 offscreen↔onscreen 翻转、而该节点本来就不在首屏视图里的变化不输出。

可信的小变更返回 successor diff（`changes`）；根替换、身份置信度不足或变更过大时返回完整折叠视图（`nodes`）。

动作打开的根跟结果一起回来：helper 已经为判定 outcome 等过根森林的变化，`act-ui` 把新出现的根经 `src/root-refs.ts` 铸成稳定 `@r`，以 `roots: [{ref, kind, app, title}]` 返回，文本视图写作 `+ root @r12 menu "文件"`。按完菜单栏项的 agent 直接 `observe-ui --root @r12`，不需要再 `find-roots`，也就没有“动作刚发出、发现还没看到新根”的竞态。

动作让它所在的根消失——按 sheet、对话框、popover 或菜单里关掉自己的按钮——本身就是证据：结果是 `worked`，证据为 `{source: "root", field: "closed"}`，文本写作 `root closed`，退出 0。判定根已消失有两条来源：helper 在动作里看到该根关闭，或读回该根失败后它已不在应用的根列表里。动作针对的根始终是保存状态里的那个根，前面冒出来的模态根作为新根报告，不会替换它，否则判定会落到别的根上。结果以 `closed: {root}` 写出关掉的根（文本 `- root @r44 sheet "警告"`，紧跟结果行），后继状态改为观察这个应用此刻会被选中的根（排除刚关掉的那个），以 `next` 写出它（文本 `next root @r12 window "…"`）并给出它的完整折叠视图；应用已没有可观察的根时不带 `stateId`，文本写 `no root of <app> remains; run find-roots`。数组里某步关掉了根，后续步骤不再投递，`closed.skipped` 记下跳过几步（文本 `skipped 1 later step: its root closed`）。根关掉后后置条件无处可查：`--expect-gone` 视为满足，其余以 `action_failed` 报出。

视图外的 offscreen 元素增删不逐条列出：一个节点本身或其祖先 offscreen、且不在对应视图里（新增看后继视图，删除看基线视图），就只计入 `offscreen: {added, removed}`，文本用一行 `… offscreen elements outside the view: 30 added` 概括。bcu 为按下菜单项而打开、关上菜单时（helper 在结果里报 `openedMenus`），AppKit 可能顺手重建菜单（帮助菜单会换成带搜索框的新菜单），这次动作里菜单及其内部节点的增删同样只计数，即使它们的占位行在视图里；菜单栏项本身不在菜单里，照常列出。结果行之后先是 `- root`、`+ root` 这些根的变化，再是元素变化。

`headless` 是严格边界。启用后禁止窗口激活、焦点切换、原始键鼠和前台回退。

## 已知局限

- 网页内容里判定只看无障碍证据。可聚焦的元素按下后获得焦点，这就是按下的证据；不可聚焦、按下后自身无变化的元素结果是 unverified，需要确认时用 `--expect-*` 表达完成条件。
- 第二级依赖未公开的 SkyLight 接口，macOS 升级可能改变它们的行为；`BCU_LIVE=1 node scripts/check-web-background.mjs` 在真实 Chrome 上逐格验证按钮、输入框、打字、按键、坐标点击、滚动、多窗口打字都在后台完成，无证据的按下恰好生效一次并报告 unverified。

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

每条命令返回一个顶层 JSON 对象，没有 `ok`/`result`/`text`/`details` 外壳；类型定义在 [`src/contract.ts`](../src/contract.ts)。除 `find-roots` 外都带 `stateId`；唯一的例外是动作关掉了应用最后一个根的 `act-ui`。文本视图由 CLI 从同一个对象渲染，Broker 不再传第二份视图。

## 错误契约

每个失败路径在抛出点就带明确错误码（`BcuError`，或 helper 的 code 经 `ERROR_CODE_ALIASES` 映射）。没有码的错误一律是 `internal_error`，代表真实缺陷。CLI 失败时 stdout 为空，stderr 输出：

```text
error <code>: <message>
recovery: <next action>
```

真实失败不会降级为成功。调用方根据错误码决定重新观察、重新授权、修复 helper 或停止任务。recovery 默认由错误码决定，经 Broker 原样传到 CLI；act-ui 投递途中 helper 失联时仍报 `helper_unavailable`，但 recovery 改为说明动作可能已经生效、修好 helper 后先重新观察再决定是否重试。

# 架构

`bcu` 是一个可执行文件，运行时只有一个进程：`/Applications/bcu.app` 里的 `bcu serve` 常驻进程持有平台能力和全部运行时状态，命令行里的 `bcu` 是它的客户端。

```text
任意有 shell 的 agent
        │
        ▼
   bcu（客户端，无状态）
        │ Unix domain socket，JSON lines
        ▼
   bcu.app：bcu serve（常驻进程）
   ├─ 状态库（观察 + 平台句柄）
   ├─ 根注册表（@r）
   ├─ 按 pid 分道的调度
   ├─ 截图 artifact
   └─ 平台：Accessibility、ScreenCaptureKit、Vision、输入投递、agent 光标
```

## 运行时模块

- `Sources/BCUCore/`：纯逻辑——大纲、投影、变化、搜索、契约类型、错误、动作校验与准备、CLI 解析与渲染；
- `Sources/BCURuntime/`：线协议、connect-or-start、状态库、调度与 epoch、根注册表、截图 artifact，不碰平台；
- `Sources/BCUPlatform/`：进程内的 `Platform` 门面，元素与根以 `Handle` 交给调用方保存；
- `Sources/BCUDaemon/`：常驻进程的命令处理——根发现与选择、观察与缓存查询、动作事务与投递梯子、权限；
- `Sources/bcu/`：可执行文件入口——客户端、`bcu serve`、配置与环境变量。

## 职责边界

### 客户端

`bcu` 客户端只负责：

- 解析参数和 stdin，在发出前校验动作数组；
- 连接或按需启动常驻进程；
- 渲染文本或 JSON；
- 把稳定错误码和恢复动作写入 stderr。

它不保存 UI 状态，也不碰 Accessibility。配置文件和 `BCU_*` 环境变量在客户端入口解析：配置了 `headless` 时客户端把每次 `act-ui` 标成 headless。

### 常驻进程

`bcu serve` 是运行时单一事实源，拥有：

- 不可变的观察，连同其中元素的平台句柄；
- 每个 pid 的 epoch 和同一 pid 的串行调度；
- 根注册表；
- 截图文件生命周期；
- 权限诊断与 setup。

它必须作为 `bcu.app` 经 LaunchServices 启动。TCC 授权绑定 bundle id 和代码签名身份，并归属于经 LaunchServices 启动的 app；从终端直接运行的进程，授权会归到终端。AppKit 占用主线程的运行循环，agent 光标画在那里。平台调用是阻塞的，每个处理器把它们放到独立线程执行，不占用 Swift 并发线程池。

IPC 使用 Unix domain socket（默认 `~/Library/Caches/bcu/resident.sock`），目录权限为 `0700`，socket 权限为 `0600`。连接先交换一次 hello，协议版本不一致时客户端直接报 `resident_unavailable`；`stop` 不受版本限制，版本不符的常驻进程也能停掉。常驻进程空闲 10 分钟后退出。

全局物理键鼠在平台内由一把锁串行，因为一个桌面会话只有一个指针和键盘焦点。

## 启动与退出

普通命令执行 connect-or-start：

1. 连接现有 socket，成功就发请求；
2. 失败后获取用户级启动锁，锁内再连一次；
3. 仍然没有常驻进程时，唯一胜者执行 `open -n -g bcu.app --args serve`，把调用方的 `BCU_*` 环境变量用 `--env` 转交过去（LaunchServices 不继承调用方环境）；
4. 常驻进程在暂存路径上 listen、设好 `0600` 后改名发布 socket；客户端监听 socket 所在目录的文件系统事件，socket 出现就连上。

启动路径不使用 sleep 或重试轮询。另一个实例已在监听时，新启动的实例直接退出。`status` 只连接现有常驻进程，`stop` 只停止现有常驻进程：它先摘掉 socket 再应答，所以 `stop` 之后的 `status` 必然看到没有在运行。

## 状态模型

标准数据流是：

```text
find-roots → observe-ui → cached query → act-ui → successor state
```

`find-roots` 返回 `@r`；`--app` 有精确名称匹配的应用时只取它们（`Google Chrome` 不带上 `Google Chrome for Testing`），否则按包含匹配。`observe-ui` 生成不可变 `stateId` 和属于该状态的 `@e`。`stateId` 是 8 位十六进制随机 id：每条命令都带它，所以要短；状态库铸造时避开仍保存着的 id，32 位随机数也让常驻进程重启前的旧 id 几乎不可能撞上新状态。每条命令都从自己的 `stateId` 取出那次观察，不存在跨请求共享的“当前窗口”。

`@r` 由根注册表发放，身份由平台判定：同一个 AX 元素是同一个根，没有 AX 元素的弹出菜单按它的窗口 id 认。标题和几何变化不影响 `@r`；注册表有容量上限，最久未用的 `@r` 被淘汰，淘汰后不再复用。观察只按根的句柄定位；窗口 id 是窗口的一个属性，只用于截图，菜单栏、菜单、sheet 和 popover 往往没有它。根已消失时直接报错，不会退回到应用的其他窗口。

每个有菜单栏的应用暴露一个 `kind: "menubar"` 根（指向 AXMenuBar），它是应用全部命令的入口：`observe-ui --root @rN` 返回菜单栏项的投影，press 其中一项就打开对应菜单。菜单栏只在前台应用身上生效：背景应用的菜单栏项、以及菜单栏下（包括闭合菜单里）的菜单项都接受 AXPress 却不做事，因此平台对它们要求前台，由投递梯子激活应用后再按；`headless` 不能激活，直接以 `action_failed` 结束。AppKit 只在菜单打开时校验菜单项，闭合菜单里的项报告的是上次的启用状态，按一个实际已禁用的项同样被接受后丢弃；所以按闭合菜单里的项之前，平台先逐级打开它上面的菜单（等 `AXMenuOpened`），项仍禁用时以 `action_failed` 报出并关掉菜单，否则按下，菜单随之关闭。

激活和打开菜单都是 bcu 自己做的，不算动作的证据：根基线在激活完成后才取，事件游标越过 bcu 打开菜单的通知，根的变化等 bcu 打开的菜单关上后才比较。菜单项的 AXSelected 是高亮，AppKit 会把它留在最后按过的项上，不作证据；菜单栏项的 AXSelected 是它的菜单已打开，仍作证据。别的应用接管前台也不作证据：激活回让和用户操作都会产生它。菜单栏和桌面一样：可以被指名观察，bcu 不会替 agent 默选它，也不会出现在无过滤的 `find-roots` 里。

菜单栏的 observation 故意遍历全部子菜单（TextEdit 约 350 节点、450 ms）：闭合菜单里的项因此能被 `search-ui` 找到并直接 press，一步就能执行一条菜单命令，不必先打开父菜单再观察一次。这份遍历只发生在被指名观察菜单栏根时。

状态库里的一条状态是一次观察：观察到的根、大纲连同大纲 ref 背后的平台句柄，以及坐标所用的几何。元素引用属于生成它的状态，状态被淘汰时句柄随之释放，没有全局元素引用表。`expand-ui` 在同一个 `stateId` 下把补读的子树嫁接进这次观察，新节点的 ref 之后照样可用。

状态库有四道容量边界：

- 最大记录数；
- 最大总字节数；
- 单条最大字节数；
- TTL。

写入时清理过期和超容量记录。单条状态超过上限时显式返回 `state_too_large`，不会截断后假装成功。

图片字节不进状态库，写成截图文件。

## 截图 artifact

平台只在显式要求图片（`--image always`、`--mode fused`）或自动读屏时截图。有图片时，常驻进程在返回结果前完成以下步骤：

1. 写入 `shots/<stateId>.jpg`；
2. 设置目录 `0700`、文件 `0600`；
3. 结果只带 `image: {path, mime, width, height}`，不含图片字节。

清理在新截图写入时执行，不创建后台清理 timer。同一 artifact 目录的写入与清理串行执行，避免并发 agent 在枚举、stat、删除之间互相破坏。

## 并发与 stale state

调度按 pid 分道，每道维护单调递增的 epoch：

- 同一 pid 的实时工作顺序执行，不同 pid 并行；
- 缓存查询只读保存的状态，不进道：`inspect-ui`、`search-ui`，以及 `expand-ui` 展开已经读到的子树；
- 观察保存在它所在道的当前 epoch 上；
- 要读实时界面的查询在状态所在的道里执行，要求 epoch 没变，也不推进它：`read-text`、`wait-for`、`expand-ui` 补读截断的子树、`search-ui` 补做 OCR。epoch 变了就是 `stale_state`。

`act-ui` 先整体校验并准备动作数组，全部通过后 epoch 才前进，然后投递。被拒绝的请求（参数错误、目标不在状态里、坐标越界）不推进 epoch，原 `stateId` 照样可用；已经开始投递的动作即使中途失败，epoch 也已前进，之前的状态一律失效。两个调用从同一状态并发写入时，第一个先推进 epoch，第二个在投递前收到 `stale_state`。不确定是否已经执行的物理动作不会自动重放。

## Observation

一次观察包含：

- 根的身份和窗口几何；
- Accessibility 大纲，以及每个节点背后的平台句柄；
- 可选的图片和 OCR 行。

完整大纲只存在状态库里；命令返回的是它的投影。`search-ui`、`expand-ui`、`inspect-ui` 查询完整大纲，因此被投影省略或折叠的节点照样可达。节点被平台截断时，`expand-ui` 在该状态所在 pid 的道里、以相同 epoch 补读这棵子树，不会把并发动作之后的数据嫁接到旧状态上。

`observe-ui` 默认 `--mode semantic --read-text auto`：窗口有无障碍内容时不取图、不做 OCR，延迟与只走无障碍一样（TextEdit、Chrome、Ghostty 实测 captureMs 与 readTextMs 均为 0）。窗口的无障碍内容少于 2 个节点时，平台自动截图并做 OCR，这样微信、Qt、游戏这类自绘窗口仍能用同一个 observe → act 循环操作。计数不含红绿灯按钮和标题栏自己的图标与标题文字，只数有名称或可操作的节点。阈值按 macOS 27 实测标定：微信、IINA、自绘按钮夹具都是 0，Ghostty 终端 3，TextEdit 约 40，Chrome 窗口 16 以上。`--read-text never` 关掉它，`always` 总是做。截了图的观察都把截图文件交给 agent（结果带 `image`，文本视图末行 `image <path> (WxH)`）：OCR 读不到空输入框这类无字区域，agent 要看图按坐标点；没截图的窗口不会为此多截。`act-ui` 的后继观察沿用同一策略，自绘窗口按完之后仍看得到 OCR 节点和截图。

OCR 用 Vision 识别简体、繁体中文与英文（不设语言时只识别拉丁文字，中文界面会是空的）。截图低于每点 2 像素（1 倍缩放的外接屏）时先放大到每点 2 像素再识别：Vision 在每点 1 像素下会把界面字号的中文读成别的字或漏掉（自绘夹具 20 pt 的"发送""静默"读成"無准""攜蝶"，列表行全部丢失），放大后与 Retina 截图一样读对；合成到白底不能稳定修好。代价实测：440×412 点的夹具窗口 `observe-ui` 端到端从约 150 ms 升到约 175 ms，1320×824 的截图 Vision 识别从约 146 ms 升到约 158 ms；Retina 截图不放大，没有变化。同一行文字已被无障碍说出（某个相交节点的标题、值或描述包含它）时丢弃；其余每行成为一个独立节点，挂在包含它中心点的最深容器下；红绿灯按钮和已有名称的叶子控件不算容器，压在它们上面的文字挂到持有它们的元素下。实测（M 系列，热启动）：微信主窗口截图约 60 ms、OCR 约 190 ms，`observe-ui` 端到端约 0.4 s，得到 47 个 OCR 节点；IINA 窗口 OCR 约 80 ms。

## 投影

`Sources/BCUCore/Projection.swift` 是 agent 看到的唯一视图，文本与 `--json` 渲染同一组 `ProjectedNode`：

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

1. 后台无障碍语义（`ax_only`）——直接对元素执行 AX 动作，不激活窗口、不动指针；原生文本视图等需要真实指针放置插入点的角色由平台判定并要求升级，元素身份始终跟着动作走，动作结果才有证据可依；
2. 后台原始输入（`pid`）——经 SkyLight 私有接口 `SLEventPostToPid` 把事件投递给目标进程（移植自 [trycua/cua](https://github.com/trycua/cua)，MIT），不抢前台、不动真实指针、不改窗口层叠；
3. 前台原始输入（`hid`）——激活窗口后走系统事件流，只在前两级失败或动作本身需要真实焦点时使用。

为输入而激活、置顶或切换 key window 是 bcu 自己做的，这些变化在投递前计入基线，不算动作的证据；窗口"持有焦点"也不算点击落点的证据。

坐标先落到元素上：命中点的元素沿父链最多上溯三层，取第一个可 AXPress 的控件作为动作的主体（最深的命中通常是控件里的文字标签）；系统级命中测试落在别的进程或只落在窗口上时，改在目标根里取包含该点的最小元素。在原生的离散控件（按钮、复选框、单选、弹出按钮、菜单项、展开三角）上的一次普通左键单击，与按它的 ref 走同一条梯子，从后台 AXPress 开始；网页内容保留指针，因为 Chromium 的指针路径精确，而它的 AXPress 分不出是否生效。

证据按主体取，不按投递方式取。主体有按下会移动的 AX 事实（值、选中状态、文本选区）时，只用 AX 读回判定。主体没有这类事实时（OCR 节点、自绘区域、没有值的普通按钮），按下以及落在坐标上的滚轮和拖拽在元素证据和根变化都没有结论后，才用屏幕证据：投递后在最多 600 ms 内每 80 ms 截一次图，排除标题栏后比较内容区，超过 0.5% 像素的某个通道变化超过 30，记为 `worked`，证据为 `source: screen`，CLI 写作 `screen changed`。截图不含真实鼠标和 agent 光标覆盖层；标题栏按窗口实际缩放比例排除。屏幕证据可能把焦点环、无关动画、通知或新消息误判为动作效果，这是它排在最后、且只用于没有 AX 读回的主体的原因。

升级只有一条规则：某一级证明自己什么都没改变（`didnt`），或平台明确要求前台（`ForegroundRequired`），才交给下一级。`unknown` 不升级：那一级已经投递，再投一次可能让动作生效两次——Chromium 的 AXPress 本身就会派发 mousedown、mouseup 与 click，对不可聚焦元素再点一次实测会触发两次。`unknown` 也不算失败，结果写作 unverified（见下节）。一个动作数组里先点击、再不带 ref 打字或按键时，打字落在点击留下的焦点上，同样从后台开始：没有 ref、目标又无 AX 读回的打字结果是 `unknown`，不升级。能建立焦点的点击是点中可编辑元素的点击，以及一切落到坐标上的点击类动作——press 一个 OCR 节点或没有 AX 元素的节点、x/y click。这条规则在平台内部（ax → pid）和动作事务里（后台 → 前台）是同一条。`headless` 把梯子钉死在第一级。`act-ui --foreground` 让数组里每个动作直接从第三级开始，用于调用方已知应用只在前台才响应的场合（见已知局限）；它与 `headless` 矛盾，同时给出时以 `invalid_arguments` 拒绝。

第二级为什么用私有接口：公开的 `CGEvent.postToPid` 不经过 WindowServer 的活动监视，Chromium 不把这类事件当真实输入。SkyLight 这一级做三件事：

- `typeText` 投递字符本身而不是打出它的按键：每个字符一对 keycode 0 的键盘事件，附上该字符的 Unicode 串，修饰键清零。物理键码会被用户当前的输入法（拼音、假名）组合成别的文字，Unicode 串不会；前台一级同样如此。`keypress` 仍发物理键码，它的语义就是按键。输入法只为前台应用组合：实测（微信输入法，中文模式）同样的字母键投递给后台应用时原样到达，前台一级才被组合成候选；
- 键盘事件在 macOS 15+ 附上 `SLSEventAuthenticationMessage`（Chromium 据此信任后台按键）；带 command 的组合键不附，否则会绕过菜单快捷键的派发路径；
- 坐标指针事件走 SkyLight。原生窗口先用 `SLPSPostEventRecordTo` 只告诉目标进程它处于激活状态，再投递点击（yabai 与 cua 的做法会先让当前前台进程失焦，实测会让用户的前台应用交出 key window 与激活状态，用户接着打的字会丢，所以不发这一半）：`acceptsFirstMouse` 为 false 的视图因此也收得到后台窗口上的第一次点击，而 WindowServer 前台、用户前台应用的 key window 和窗口层叠都不变（真机门用一个记录自己失去 key 的前台应用验证）；
- 滚轮按格投递：`scrollX`/`scrollY` 是滚轮格数（-50…50，正数向下、向右），每格一个按行计的滚轮事件，间隔 15 ms，和实体鼠标滚轮一样。Qt（微信 4 用它）把每个按行计的事件算作一格，而把精确像素增量按每像素 1/60 格累积，不满一格不滚，所以按像素投递的 5 在 Qt 列表上一行都不动；AppKit 与 Chromium 每格滚一行。有无障碍滚动动作的元素走第一级，只看方向，每次一页；
- 网页里的滚动用滚轮：Chromium 不给可滚动元素暴露滚动动作，祖先的滚动动作滚的是整页，所以在元素上方发带窗口路由的滚轮事件。滚动的证据是元素内容相对元素的位置变化；Chromium 把直接子元素的 frame 裁剪到滚动区域，只有更深的后代会移动；
- 点击按 Chromium 配方投递：先在目标点发 mouseMoved，再在屏外 (-1,-1) 按下抬起一次通过用户激活检查，最后在目标点按下抬起；每个事件写入目标 pid、窗口 id 与同一个点击组 id，窗口坐标相对窗口左上角；
- 拖拽带同样的路由：先在起点发 mouseMoved，按下，沿路径每约 10 点发一个 dragged 事件（每段最多 30 个），停 50 ms 让 Chromium 处理完最后一个 dragged 再抬起；全部事件共用一个点击组 id。视图靠按下与抬起之间的 dragged 事件跟踪拖拽，只发按下和抬起、或不带路由的事件，自绘视图和网页都收不到；
- 投递给进程的输入只到达它的 key window。目标窗口不是 key window 时，先向该进程发 yabai 的 focus-without-raise 事件记录（`SLPSPostEventRecordTo`），让它成为 key window 而不激活应用、不置顶窗口；这次切换计入动作前的基线，不会被当成动作本身的效果。

任一私有符号解析失败时，第二级直接要求前台，没有公开接口的回退路径。

## Action transaction

`act-ui` 接收一个动作数组。数组内步骤共享同一 base state 和资源锁，按顺序验证。数组只放互不依赖中间 UI 的动作：某步 `unknown` 时继续下一步，某步 `didnt` 时中止。能够表达完成条件时，调用方把 `--expect-text`、`--expect-role` 或 `--expect-value` 附在同一事务中，避免独立等待和额外模型轮次。

平台对每次投递判定 `worked`、`didnt` 或 `unknown`，并说明理由。判定按证据强弱排序：

1. 目标元素自身的事实移动了——AXValue、AXSelected、AXFocused、选区或插入点——`worked`，`verification.evidence` 记下是哪个字段、从什么变成什么；
2. 指针确实落在该元素上（命中测试通过）且动作后它持有键盘焦点——`worked`；只移动插入点的点击没有别的痕迹；
3. 根森林发生变化（菜单打开、sheet 出现、窗口易主）——`worked`；
4. 元素是有值的切换类控件（checkbox、radio、segment、switch、disclosure）而值没动——`didnt`，错误信息带上停在哪个值；
5. 其余——`unknown`：已经投递，但没有证据判定，既不伪装成成功，也不当成失败。

投影里带 `toggle` 能力的元素就是平台按第 4 条判定的那一类，两侧取同一组 role 与 subrole。文本视图把证据接在结果行上，例如 `worked via ax · value 0→1`。

只有被证明无效的动作才失败：`didnt` 和后置条件未满足在动作事务里抛出 `action_failed`，退出码 9，stdout 为空。`unknown` 退出 0，结果行写作 `unverified via ax`，照常返回后继状态和变化，没有变化时写出 `(no element changes)`；`--json` 的 `outcome` 仍是 `"unknown"`。菜单命令、没有可读效果的快捷键、自绘窗口里的按下都落在这里，它们大多已经生效，逼 agent 为每一个再观察一轮得不偿失。带 `--expect-*` 且条件满足时结果是 `worked`：后置条件就是那份缺失的证据。`--scope @eN` 把后置条件限定在一个子树内。变化行必须说出变了什么：值和名字按原格式，状态写成它变成了什么（`~ @e51 onscreen`、`~ @e51 focused`）。只是 offscreen↔onscreen 翻转、而该节点本来就不在首屏视图里的变化不输出。

可信的小变更返回 successor diff（`changes`）；根替换、身份置信度不足或变更过大时返回完整折叠视图（`nodes`）。

动作打开的根跟结果一起回来：平台已经为判定 outcome 等过根森林的变化，`act-ui` 把新出现的根经根注册表铸成稳定 `@r`，以 `roots: [{ref, kind, app, title}]` 返回，文本视图写作 `+ root @r12 menu "文件"`。按完菜单栏项的 agent 直接 `observe-ui --root @r12`，不需要再 `find-roots`，也就没有“动作刚发出、发现还没看到新根”的竞态。

动作让它所在的根消失——按 sheet、对话框、popover 或菜单里关掉自己的按钮——本身就是证据：结果是 `worked`，证据为 `{source: "root", field: "closed"}`，文本写作 `root closed`，退出 0。判定根已消失有两条来源：平台在动作里看到该根关闭，或读回该根失败后它已不在应用的根列表里。动作针对的根始终是保存状态里的那个根，前面冒出来的模态根作为新根报告，不会替换它，否则判定会落到别的根上。结果以 `closed: {root}` 写出关掉的根（文本 `- root @r44 sheet "警告"`，紧跟结果行），后继状态改为观察这个应用此刻会被选中的根（排除刚关掉的那个），以 `next` 写出它（文本 `next root @r12 window "…"`）并给出它的完整折叠视图；应用已没有可观察的根时不带 `stateId`，文本写 `no root of <app> remains; run find-roots`。数组里某步关掉了根，后续步骤不再投递，`closed.skipped` 记下跳过几步（文本 `skipped 1 later step: its root closed`）。根关掉后后置条件无处可查：`--expect-gone` 视为满足，其余以 `action_failed` 报出。

视图外的 offscreen 元素增删不逐条列出：一个节点本身或其祖先 offscreen、且不在对应视图里（新增看后继视图，删除看基线视图），就只计入 `offscreen: {added, removed}`，文本用一行 `… offscreen elements outside the view: 30 added` 概括。bcu 为按下菜单项而打开、关上菜单时（平台在结果里报 `openedMenus`），AppKit 可能顺手重建菜单（帮助菜单会换成带搜索框的新菜单），这次动作里菜单及其内部节点的增删同样只计数，即使它们的占位行在视图里；菜单栏项本身不在菜单里，照常列出。结果行之后先是 `- root`、`+ root` 这些根的变化，再是元素变化。

`headless` 是严格边界。启用后禁止窗口激活、焦点切换、原始键鼠和前台回退。

## 已知局限

- 有的界面只在应用处于前台时才出现，bcu 从外部识别不了。用户实测：微信搜索框里后台打字逐字正确，但搜索结果下拉只在微信处于前台时出现，后台时什么都不发生，结果是 unverified。bcu 的后台点击会让目标应用自认处于激活状态（`NSApp.isActive` 为真，但 WindowServer 的前台和用户的 key window 都没变），所以只看 `isActive` 的界面在后台照样出现，真机门用一个只在 `isActive` 时显示结果区的自绘输入验证这一点；微信用的是别的判断，而"输入到了、其余没反应"和"本来就没有东西可显示"从外部看是同一个样子。bcu 不猜：这一步已经投递，`unknown` 不升级，也不会为此自动换到前台重做。调用方已知需要前台时用 `act-ui --foreground` 显式从前台一级开始，代价是激活目标应用、抢走用户的前台和键盘焦点，指针类动作还会移动真实指针；`headless` 下不可用。
- 网页内容里判定只看无障碍证据。可聚焦的元素按下后获得焦点，这就是按下的证据；不可聚焦、按下后自身无变化的元素结果是 unverified，需要确认时用 `--expect-*` 表达完成条件。
- 第二级依赖未公开的 SkyLight 接口，macOS 升级可能改变它们的行为；`BCU_LIVE=1 node scripts/check-web-background.mjs` 在真实 Chrome 上逐格验证按钮、输入框、打字、按键、坐标点击、滚动、多窗口打字都在后台完成，无证据的按下恰好生效一次并报告 unverified。

## 测量

首屏视图大小由 `scripts/fixtures/` 里两份真机大纲（TextEdit 一个文档窗口、Finder 一个文件夹窗口）的投影金标锁定，`swift test --filter projection` 复现。投影层落地前同样两个窗口的文本视图是 1517 和 4683 字节（基线 `b97686f`），现在是 491 和 704 字节。

端到端时延直接量命令本身：

```bash
time bcu observe-ui --app TextEdit
```

## 浏览器窗口

浏览器窗口是普通的 AX 窗口，没有专用代码路径：网页里的按钮、输入框、打字和按键走同一条投递梯子，在后台完成。页面级自动化（DOM、网络、脚本）由 `better-browser-use` 负责。

## 结果契约

每条命令返回一个顶层 JSON 对象，没有 `ok`/`result`/`text`/`details` 外壳；类型定义在 `Sources/BCUCore/Contract.swift`，客户端与常驻进程共用这一份。除 `find-roots` 外都带 `stateId`；唯一的例外是动作关掉了应用最后一个根的 `act-ui`。文本视图由客户端从同一个对象渲染。JSON 一律由 Foundation 的编码器写出：紧凑、键按字典序，同一个值总是同样的字节；`inspect-ui` 的文本视图是它的缩进形式。名称和值按字符截断（名称 120、值 160 个字符，超出的加 `…`），空白按 Swift 的判定折叠。

## 错误契约

每个失败路径在抛出点就是带明确错误码的 `BCUError`，没有映射表。没有码的错误一律是 `internal_error`，代表真实缺陷。CLI 失败时 stdout 为空，stderr 输出：

```text
error <code>: <message>
recovery: <next action>
```

真实失败不会降级为成功。调用方根据错误码决定重新观察、重新授权、重启常驻进程或停止任务。recovery 默认由错误码决定；需要别的指引时由抛出点给出，原样传到客户端。

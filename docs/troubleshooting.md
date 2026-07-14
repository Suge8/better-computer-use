# 故障排查

先运行：

```bash
bcu doctor
```

`doctor` 检查 Broker、native helper、协议版本、macOS 权限和配置来源。错误输出中的 `recovery:` 给出下一步操作。

## `bcu` 不在 PATH

在仓库中重新构建并创建全局链接：

```bash
npm run build
npm link
which bcu
```

`package.json` 的 bin 入口应指向 `dist/bcu.mjs`。

## macOS helper 缺失

正常安装会把 helper 放到：

```text
/Applications/bcu.app
```

从源码修复安装：

```bash
node scripts/setup-helper.mjs --runtime
```

本地重建后安装：

```bash
npm run build:native
node scripts/setup-helper.mjs --force
```

验证签名：

```bash
codesign --verify --strict /Applications/bcu.app
```

## macOS 权限缺失

在交互式终端运行：

```bash
bcu setup
```

然后在“系统设置 → 隐私与安全性”中为 `bcu` 打开：

- 辅助功能
- 屏幕录制

`setup` 会重启 helper 再复查。macOS 会缓存进程权限；只打开开关但不重启 helper，旧进程仍可能报告缺失。

如果 helper 更新或重新签名后权限失效，先关闭再打开两个开关。仍无法恢复时重置当前 bundle id 后重新授权：

```bash
tccutil reset Accessibility com.sugeh.bcu
tccutil reset ScreenCapture com.sugeh.bcu
bcu setup
```

## 非交互环境无法 setup

授权需要用户操作系统设置。非交互 shell 中的 `bcu setup` 会返回：

```text
error permission_missing: …
recovery: Run 'bcu setup' in an interactive terminal, grant both permissions, then retry.
```

先在本机交互式终端完成授权，再运行 agent 任务。

## Broker 无法启动

```bash
bcu status
bcu stop
bcu doctor
```

普通命令会自动恢复失效的 socket。`status` 不启动 Broker，`stop` 在 Broker 未运行时也不会创建新进程。

macOS IPC 路径为 `~/Library/Caches/bcu/broker.sock`。目录权限应为 `0700`，socket 权限应为 `0600`。

## 状态或 ref 过期

`stateId`、`@e` ref 和坐标属于同一次观察。收到 `stale_state` 或 `element_not_found` 后：

1. 再次运行 `bcu observe-ui`；
2. 使用新状态返回的 `stateId` 和 ref；
3. 不要重放结果不确定的点击或输入。

## 找不到应用或窗口

先确认应用已打开，再查看当前根节点：

```bash
bcu find-roots
bcu find-roots --app TextEdit
```

应用查询会匹配显示名、bundle id 和 bundle id 尾段。窗口标题有歧义时同时指定应用和标题：

```bash
bcu observe-ui --app TextEdit --window-title Untitled
```

## 坐标被拒绝

坐标使用产生该状态的截图像素。以下变化会让坐标失效：

- 窗口尺寸或目标窗口改变；
- 新观察替换了原状态；
- 坐标超出截图边界；
- 状态没有图片尺寸元数据。

重新观察并显式请求图片：

```bash
bcu observe-ui --root @r1 --image always
```

## 截图没有出现在 stdout

这是预期行为。截图写入 `~/Library/Caches/bcu/shots/<stateId>.jpg`，stdout 只返回：

```text
screenshot: /…/shots/<stateId>.jpg (宽x高)
```

检查文件权限：

```bash
stat -f '%Sp %N' ~/Library/Caches/bcu/shots/*.jpg
```

## 浏览器命令失败

`bcu browser launch` 支持 Helium 和 Google Chrome，并使用固定应用路径。确认目标浏览器已安装，或用 `BCU_CDP_PORT` 连接已开启远程调试端口的 Chromium 浏览器。

若 macOS 桌面浏览器回退路径提示 Apple Events JavaScript 被禁用，请在浏览器中启用“Allow JavaScript from Apple Events”后重试。

## Windows

Windows 必须运行在已解锁的交互式桌面会话中。helper 路径为：

```text
%USERPROFILE%\.bcu\helpers\windows-bridge.exe
```

Windows 不使用 `/Applications/bcu.app`，也没有 macOS TCC 授权步骤。npm 包内含 `prebuilt/windows/windows-bridge.exe`，首次运行会直接安装该文件，不需要 Rust 或 Cargo。若 `bcu doctor` 报 helper 缺失，请重新安装包；打包门会拒绝缺少该二进制的 tarball。

# 故障排查

先运行 `bcu doctor`：它检查 Broker、helper、协议版本、权限和配置来源，失败时的 `recovery:` 就是下一步。下面只记 `doctor` 和错误输出讲不清的原因。

## 权限打开了却仍报缺失

macOS 把 Accessibility 和 Screen Recording 授权绑定在代码签名身份上，并按进程缓存。helper 更新或重新签名后，旧授权对新身份无效，运行中的旧 helper 进程也会继续报告缺失。

`bcu setup` 会重启 helper 再复查，所以先跑它；仍然缺失时在系统设置里把两个开关关掉再打开。还不行就重置当前 bundle id 的授权：

```bash
tccutil reset Accessibility com.sugeh.bcu
tccutil reset ScreenCapture com.sugeh.bcu
bcu setup
```

授权需要用户在系统设置里点击，非交互 shell 里的 `bcu setup` 会直接以 `permission_missing` 退出。先在本机交互式终端完成授权，再跑 agent 任务。

## 锁屏期间一切都找不到窗口

屏幕锁定时 Accessibility 不再枚举任何应用的窗口：`find-roots` 的 pairing 全变 `low`，观察会退化。这不是 bcu 或 helper 的故障，解锁后立即恢复。

## 从源码修复 helper

```bash
node scripts/setup-helper.mjs --runtime     # 重新安装缺失或被替换的 helper
npm run build:native && node scripts/setup-helper.mjs --force   # 本地改过 Swift 后
codesign --verify --strict /Applications/bcu.app
```

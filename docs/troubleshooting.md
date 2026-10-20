# 故障排查

先运行 `bcu doctor`：它检查常驻进程与版本、权限和配置来源，失败时的 `recovery:` 就是下一步。下面只记 `doctor` 和错误输出讲不清的原因。

## 权限打开了却仍报缺失

macOS 把 Accessibility 和 Screen Recording 授权绑定在代码签名身份（Developer ID）和 bundle id 上，并按进程缓存。签名身份不变时升级不影响授权；身份变了（例如从旧的自签名版本迁来）旧授权无效；授权刚打开时，已经在运行的常驻进程也会继续报告缺失。

`bcu setup` 会重启常驻进程再复查，所以先跑它；仍然缺失时在系统设置里把两个开关关掉再打开。还不行就重置当前 bundle id 的授权：

```bash
tccutil reset Accessibility com.sugeh.bcu
tccutil reset ScreenCapture com.sugeh.bcu
bcu setup
```

授权需要用户在系统设置里点击，非交互 shell 里的 `bcu setup` 会直接以 `permission_missing` 退出。先在本机交互式终端完成授权，再跑 agent 任务。

## 锁屏期间一切都找不到窗口

屏保启动或显示器休眠都会锁定会话，这时 Accessibility 不再如实报告窗口。需要界面的命令以 `screen_locked` 报错，不会转去前台输入；解锁后立即恢复。

## 重装 bcu.app

```bash
brew reinstall --cask suge8/tap/bcu
codesign --verify --deep --strict /Applications/bcu.app
```

`bcu.app is not installed` 表示 app 不在（或 `BCU_APP_PATH` 指错了）。从源码开发的机器用 `scripts/install.sh` 重装。

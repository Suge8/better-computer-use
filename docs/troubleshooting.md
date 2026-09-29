# 故障排查

先运行 `bcu doctor`：它检查常驻进程、协议版本、权限和配置来源，失败时的 `recovery:` 就是下一步。下面只记 `doctor` 和错误输出讲不清的原因。

## 权限打开了却仍报缺失

macOS 把 Accessibility 和 Screen Recording 授权绑定在代码签名身份上，并按进程缓存。换了签名身份后旧授权无效；授权刚打开时，已经在运行的常驻进程也会继续报告缺失。

`bcu setup` 会重启常驻进程再复查，所以先跑它；仍然缺失时在系统设置里把两个开关关掉再打开。还不行就重置当前 bundle id 的授权：

```bash
tccutil reset Accessibility com.sugeh.bcu
tccutil reset ScreenCapture com.sugeh.bcu
bcu setup
```

授权需要用户在系统设置里点击，非交互 shell 里的 `bcu setup` 会直接以 `permission_missing` 退出。先在本机交互式终端完成授权，再跑 agent 任务。

## 锁屏期间一切都找不到窗口

屏幕锁定时 Accessibility 不再如实报告窗口：`find-roots` 找不到目标窗口，窗口标题退化成应用名，观察会退化。这不是 bcu 的故障，解锁后立即恢复。

## 重装 bcu.app

```bash
scripts/install.sh                              # 在仓库里重新构建、签名并安装，停掉旧常驻进程
codesign --verify --strict /Applications/bcu.app
```

`bcu.app is not installed` 表示 `/Applications/bcu.app` 不在，运行安装脚本。安装脚本提示“creating the local signing identity”说明这台 Mac 第一次生成签名身份，或登录钥匙串里的身份被删了；之后需要重新 `bcu setup`。

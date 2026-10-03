# CommanderGuard

CommanderGuard 是 macOS 菜单栏里的 Desktop Commander 状态工具。它显示本机收到的命令、文件操作和单次调用耗时，也会用实际的远程 `ping` 检查命令通道。设备列表显示“在线”，不等于命令一定能到达这台 Mac；菜单会把这两种状态分开。

## 安装与更新

先安装并登录 [Remote Desktop Commander](https://github.com/desktop-commander/remote-desktop-commander)，确认它在本机运行。然后在本项目目录执行：

```bash
./build.sh
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --self-test
./install.sh
```

安装脚本会构建并签名 Guard，把它放到 `~/Applications/CommanderGuard.app`，创建桌面入口和登录自启项，并重新启动 **CommanderGuard**。脚本目前使用固定项目路径 `/Volumes/ExtSSD/Projects/CommanderGuard`。它不会重启、重新登录或修改已经运行的 Desktop Commander 服务。以后若启用自动恢复，Guard 可能在确认通道失效且满足安全条件时重启该服务；见下文。

菜单里的“自动恢复 MCP 通道”可以单独开关。首次安装、且没有既有设置文件时，默认开启。如果正在使用 Commander，想让 Guard 只监测、不执行自动重启，可以关闭这个选项。防休眠开关与自动恢复开关互不影响。

## 如何判断通道状态

Guard 启动 90 秒后开始定期发送无副作用的 MCP `ping`。收到针对本机设备、请求编号匹配的 `pong`，才确认命令通道可用。菜单栏的 `●` 表示近期确认可用，`!` 表示服务未运行或通道明确报错，`?` 表示尚未确认、结果过期或网络等原因导致无法判断。

当服务**连续三次明确返回“设备没有活动连接”**时，Guard 才会考虑自动恢复。普通超时、网络故障、登录失效以及无法识别的响应只会显示“状态未知”，不会触发重启。

在重启前，Guard 还会确认云端没有待执行或执行中的调用、本机日志没有未结束或状态不明的调用，并核对 Commander 进程树中没有额外子进程。检查失败、日志有缺口、自动恢复被关闭或处于冷却期时，都会暂缓重启。每次尝试前会保存五分钟冷却记录，防止 Guard 自己重启后反复尝试。重启后，只有服务进程号变化且新 `ping` 成功，才报告恢复成功。

这些检查旨在避免打断可观察到的工作，但无法保证识别所有独立运行的后台任务。通道恢复也不会重新执行命令、重试图片生成或继续发送聊天消息。

## 操作记录与状态

“执行日志…”显示本次运行中最多 100 次本机工具调用，包括经脱敏的命令预览、操作时间和耗时。一次 `start_process` 返回，仅表示启动调用结束；其后台进程可能仍在运行。本机调用返回也不能证明云端已收到结果或整轮聊天任务已完成。日志丢失、读取中断或调用无法匹配时，Guard 会标出“状态未确认”。

“暂停防休眠（仅影响本机睡眠）”只释放 Guard 的防空闲睡眠设置，日志观察继续运行。它不能恢复 ChatGPT 的回答流，也不能保证远程任务持续运行。

本机状态保存在 `~/Library/Application Support/CommanderGuard/`：

- `status.json`：当前服务、通道和调用状态。
- `timeline.jsonl`：脱敏事件时间线，最多 1 MiB，保留一个轮替副本。
- `channel-recovery.json`：自动恢复开关及最近尝试时间，不含登录凭据。

Guard 读取已有的本机登录信息来查询设备登记与待执行调用，并发送固定的 `ping`；它不写入或刷新登录凭据。状态和时间线不保存令牌、原始会话标识或命令结果。命令预览会隐藏常见凭据及内联脚本；自定义的秘密格式仍应避免放入命令行。

## 单独检查与卸载

离线自检不会启动 Guard 或操作 Commander 服务：

```bash
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --self-test
```

需要验证当前真实命令通道时，可手动运行一次只读探测；它不会执行自动恢复：

```bash
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --probe-channel
```

卸载 Guard：

```bash
./uninstall.sh
```

卸载脚本会移除 Guard 应用、桌面入口和登录启动项，保留项目源码及状态文件。

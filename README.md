# CommanderGuard

在 macOS 菜单栏里查看 Desktop Commander 正在电脑上做什么。

把任务交给 ChatGPT 后，你可以继续做自己的事。CommanderGuard 会显示本机正在执行的命令或文件操作，以及这次工具调用已经用了多久。点开执行日志，就能回看每一步的动作和耗时。

它适合已经通过 Desktop Commander 远程操作 Mac、希望随时看一眼执行情况的人。当前版本针对本机 Remote Desktop Commander 服务和日志路径编写。

## 与 Desktop Commander 的关系

[Remote Desktop Commander](https://github.com/desktop-commander/remote-desktop-commander) 是 Desktop Commander 的官方远程 MCP 服务，让 ChatGPT 等客户端能够连接你的电脑并调用本机工具。底层工具项目是 [DesktopCommanderMCP](https://github.com/wonderwhy-er/DesktopCommanderMCP)，提供终端执行、文件搜索和编辑等能力。

CommanderGuard 是单独运行的观察工具。Desktop Commander 负责接收和执行操作，CommanderGuard 读取已有日志并把执行情况显示在菜单栏里。安装本项目需要先有可用的 Remote Desktop Commander；安装脚本不会替你安装、登录、修改或重启它。

## 能看到什么

- 菜单栏显示当前动作和单次调用耗时。命令预览保留可读取的参数，例如 `python3` 后面的脚本、`grep` 的搜索条件和管道操作。
- 文件操作显示目录与文件名。长命令在菜单栏中缩短，完整的安全预览可以在悬浮提示和执行日志中查看。
- 执行日志按每次调用一条记录显示，最多保留本次运行中最近 100 个步骤，包含观察时间、动作、状态和耗时。
- 本机 Commander 服务状态直接显示在菜单中。App 连接事件、错误和服务器登记信息放在日志窗口的“故障详情…”中。

调用结束后，菜单栏会继续显示该动作和耗时 3 秒，方便看见很快完成的操作，随后恢复“当前无工具调用”。遇到日志缺失、读取中断或无法匹配的并发调用时，会显示“状态未确认”。

## 时间和状态怎么理解

计时对应一次本机工具调用，从观察到接收调用算到观察到返回。状态每秒最多刷新一次，时间按整秒显示；同一次采集中收到并结束的调用可能显示 `<1 秒`。这些是本机观察耗时，不是精确的服务端计时。

一次 `start_process` 返回后，它启动的进程可能仍在运行。因此，“调用结束”不能证明测试已经跑完、云端已经收到结果，或整轮 Chat 任务已经完成。“当前无工具调用”也只表示当前没有已确认的本机调用。

初次启动会从日志末尾开始观察。旧记录不会被当成正在执行的任务；在缺少新证据时，菜单栏可能暂时显示“状态未确认”。

部分 App 刷新和响应恢复事件能显示会话名称，但目前还不能把 Commander 的每条命令准确关联到某个会话，也没有整轮任务计时。公共更新连接的打开、关闭或重连，只描述 App 的共享连接。

## 安装与使用

需要 macOS 和可用的 Swift 编译工具链。先确保本机 Remote Desktop Commander 能正常运行，再在项目目录执行：

```bash
./build.sh
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --self-test
./install.sh
```

当前安装脚本使用固定项目路径 `/Volumes/ExtSSD/Projects/CommanderGuard`。应用安装到 `~/Applications/CommanderGuard.app`，同时创建登录自启项和桌面入口。菜单中的“执行日志…”会打开可复制文字、可滚动查看的原生窗口。

“暂停防休眠（仅影响本机睡眠）”允许电脑恢复自动空闲睡眠，日志观察仍继续运行。点击“恢复防休眠”可重新启用；防休眠只在 Commander 服务运行时生效，不保证云端连接或任务持续运行。

卸载：

```bash
./uninstall.sh
```

卸载脚本移除本工具的应用、桌面入口和登录启动项，保留源代码及本机状态文件。

## 能力边界

CommanderGuard 提供本机执行记录，不能预防或修复 ChatGPT 云端响应超时，也不能仅凭没有调用就判断模型卡住或任务完成。它不会自动续发消息、重试工具、切换模型，也不管理 Shadowrocket、TunnelSentinel 或网络节点。

服务器登记在线只表示设备的登记状态。防休眠可以避免本机因空闲睡眠影响执行，但不能恢复已经不可用的云端回答流。

## 记录与隐私

状态和时间线位于：

- `~/Library/Application Support/CommanderGuard/status.json`：当前状态、调用耗时和安全处理后的命令预览。
- `~/Library/Application Support/CommanderGuard/timeline.jsonl`：脱敏事件时间线，单文件最多 1 MiB，保留一个轮替副本。

执行步骤、悬浮提示和 `status.json` 共用最多 1000 字符的命令预览。已识别的凭据参数、环境变量、请求头、带凭据的网址、JWT 和 UUID 会隐藏；动态命令展开、未闭合引号、控制字符和未完整读取的命令会显示说明文字。`-c`、`-e` 和 heredoc 内联脚本正文也会隐藏。预览只用于显示，不执行命令；隐藏规则无法识别所有自定义格式的秘密。

时间线只保存固定事件、工具类别和时间，不保存命令正文、结果、URL、令牌或原始会话与调用标识。

<details>
<summary>日志读取与会话名称的技术说明</summary>

观察器增量读取最多 3 个日期目录、8 个 ChatGPT App 日志和 Commander 日志。每个来源每次最多读取 64 KiB；Commander 调用行最多读取 4 KiB，App 日志行最多读取 8 KiB。缺失、不可读、轮换、截断及读取间隔会标记覆盖状态。

App 事件需要匹配固定时间戳、`electron-message-handler` 来源和事件白名单。状态值只保留 `streaming`、`error`、`idle` 等固定类别；读取到 `idle` 不能证明任务成功结束。

会话名称来自本机 `~/Library/Application Support/CommanderGuard/conversation-labels.json`。文件最大 64 KiB，只包含 `verified_at` 和 SHA-256 会话标识到名称的映射。只有同一条原始事件包含 `conversationId` 且命中名录时，才显示名称。名录不自动刷新，改名或新增会话后可能过期；它仅用于 App 事件，不用于推测 Commander 调用的归属。

工具还会使用本机已有登录信息，只读查询 Commander 的服务器登记状态。该查询不修改服务或远端任务。

</details>

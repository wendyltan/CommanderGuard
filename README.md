<p align="center">
  <img src="Assets/AppIcon.png" width="112" alt="CommanderGuard icon">
</p>

<h1 align="center">CommanderGuard</h1>

<p align="center">macOS 菜单栏工具，检查 Desktop Commander 的命令连接、观察本机执行记录，并在符合安全条件时尝试恢复断链。</p>

<p align="center">中文 · <a href="README.en.md">English</a></p>

远端显示设备在线，却调用不了工具？CommanderGuard 在本机观察消息通道和工具执行，分别展示已有证据。云端主动探测默认关闭，避免闲置时持续发送可能扣额度的工具请求。它也能观察 ChatGPT App 的部分连接事件，并在概览里显示 Desktop Commander 云端 tool calls 用量。

本项目面向已经使用 [Remote Desktop Commander](https://github.com/desktop-commander/remote-desktop-commander) 的 macOS 用户。应用界面目前为中文。自动恢复依赖指定的本机服务与日志布局，安装前请看下方兼容条件。

## 能做什么

| 功能 | 你能看到或操作什么 |
|---|---|
| 实时状态 | 菜单栏图标及文字显示通道状态；主面板分别显示消息通道、工具执行和 ChatGPT 回答状态 |
| 可选主动探测 | 默认关闭；可选每 5、10、15、30 分钟或 1、2、3、6 小时发一次设备 `ping`，所有入口共享所选间隔 |
| 自动恢复 | 多次明确断链后，检查任务、日志、进程和冷却条件，再决定是否重启受管理的 Commander 服务 |
| 操作记录 | 最近最多 100 次本机调用，支持搜索、筛选和脱敏详情；上游提供可靠字段时显示匿名会话归属 |
| 云端用量 | 通过 Chrome 官方用量页同步已用、总量、剩余量、进度和最近成功同步时间 |
| ChatGPT 观察 | 从本机日志识别部分断流、续传和更新连接事件，区分当前状态与历史异常 |
| 保持唤醒 | Commander 服务运行时，可阻止系统因闲置而休眠 |

某一层正常，只能证明这一层的检查通过。设备登记在线、`ping` 成功、本机工具返回，以及 ChatGPT 回答完整结束，需要各自的证据。Guard 不会自动重发聊天消息或重试业务任务。

## 快速开始

### 1. 检查运行条件

你需要 macOS、可用的 Swift 编译器，以及已经安装、登录并配对的 Remote Desktop Commander。构建使用系统的 AppKit 和 IOKit，无需额外的 Swift 包依赖；如果缺少编译器，请先安装 Xcode Command Line Tools。

当前版本按以下布局读取本机服务。它还没有提供自定义路径或服务名设置：

| 项目 | 当前读取的位置 |
|---|---|
| 登录信息 | `~/.desktop-commander-device/device.json` |
| 受管理的 LaunchAgent | `com.wuwendi.remote-desktop-commander` |
| Commander 日志 | `~/Library/Logs/RemoteDesktopCommander/stdout.log`、`stderr.log` |
| Commander 程序 | `~/.local/share/remote-desktop-commander/node_modules/@wonderwhy-er/desktop-commander/dist/index.js` |
| ChatGPT App 日志 | `~/Library/Logs/com.openai.codex` |

如果你使用其他启动方式，Guard 可能无法识别服务或确认空闲，自动恢复也可能不可用。它不会自动把你的 Commander 改成这套布局。

### 2. 从源码构建并运行

下载或克隆本仓库，在项目目录执行：

```bash
./build.sh
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --self-test
```

构建完成后，在 Finder 打开 `build/CommanderGuard.app`。应用入口在菜单栏，点击图标打开主面板。源码构建使用本地临时签名，没有配置 Developer ID 公证。

“云端主动探测（可能消耗额度）”默认关闭，升级也不会自动开启。首次运行且没有旧配置时，“自动恢复本机 Commander”的许可默认开启，但主动探测关闭时恢复暂停；面板会说明。“防止闲置睡眠（Guard）”是独立开关，不需要探测。

### 3. 选择是否主动探测

默认观察本机日志、真实工具调用和设备登记状态，不发送 Guard 的 MCP 工具探针。想做设备回应检查时，先开启“云端主动探测（可能消耗额度）”，再点击“手动 ping（1次）”；这个按钮只发一次 ping。设备 ping 成功仍不证明本机工具层能执行。

在“探测频率”选择 **5、10、15、30 分钟，或 1、2、3、6 小时**，默认 1 小时。日常主动检查可选 15 分钟，长期轻量观察可选 1 小时；5 分钟适合临时排查。所有自动、手动、命令行和恢复后探测，共享从上次请求起算的最小间隔；超时、失败也要等到下一次，不会连发。切换开关、改变频率或重开 Guard 都保留上次请求时间，改变频率本身不发送请求。

固定的 6 次 / 24 小时上限已替换为上述间隔。持续按同一频率开启时，预计每天约 288、144、96、48、24、12、8、4 次请求，面板显示估计数量和下一次可探测时间；估计不是最近 24 小时的实际调用数。官方尚未明确承诺设备 ping 免费；已有对照只说明当次观察窗口未见扣额。额度用量读取不属于 MCP 工具探测，不占这个间隔。

关闭主动探测阻止新的 `tools/call`，暂停自动恢复；已发出的请求无法撤回。记录损坏、时钟回拨或记录无法安全保存时也暂停。日志观察、设备登记查询、ChatGPT 事件观察、额度同步和防闲置睡眠继续。不要把“未确认”当作空闲或健康。

### 可选：使用现有安装脚本

**`install.sh` 目前依赖 `/Volumes/ExtSSD/Projects/CommanderGuard`，并要求 `/Volumes/ExtSSD/Projects` 已存在。其他目录的用户请先使用上面的源码运行方式。**

适配这套目录布局后执行：

```bash
./install.sh
```

脚本会构建应用，安装到 `~/Applications/CommanderGuard.app`，创建桌面入口和登录自启项，并重新启动 CommanderGuard。安装步骤本身不会重启或修改 Remote Desktop Commander；启动后的自动恢复行为由 Guard 开关和安全条件决定。该登录自启项会在 Guard 异常退出后尝试重启，正常退出不会触发保活。

## 日常使用

主面板有三个页面，支持调整窗口大小和系统浅色、深色外观。顶部保留简短的状态与导航；概览集中显示当前结论、守护开关、用量和本机操作。重要时间同时显示时刻与距今多久。

| 页面 | 适合查看的内容 |
|---|---|
| 概览 | 当前最需要处理的状态、本机任务、用量；主要开关、主动探测频率、下次可检查时间，以及“手动 ping（1次）”入口 |
| 操作记录 | 按时间、操作、结果、耗时和会话查看；默认隐藏 `ping`，时间不详的较早记录单独展开。支持搜索和筛选，选中后查看脱敏详情；可靠会话标识以稳定颜色区分 |
| 故障与恢复 | 顶部保留简短状态；正文按时间呈现异常、探测、恢复结果，不重复守护开关 |

菜单栏会持续更新简短状态。消息通道显示最近一次实际探测结果及时间；“上次探测成功”保留的是历史证据，不保证此刻仍然连通。内部标记 `●` 表示消息通道近期明确回应，`!` 表示服务未运行或通道明确报错，`?` 表示尚未确认、证据过期或不足。等待下一次检查不等于已发生新故障。

开关表示你的许可，旁边的状态表示当前是否能执行。例如自动恢复已开启，但日志不完整、无法确认空闲时，仍会暂停恢复并说明原因。“未观察到正在执行的操作”也不等于已经证明空闲。ChatGPT 连接重建与原回答完整性分别显示。

### 连接云端用量

这是 Desktop Commander 云端 tool calls 用量，与 ChatGPT 的订阅额度无关。该功能可选，需要本机安装 Google Chrome。

1. 在“概览”点击“连接额度账户”，在 Guard 专用的浏览器窗口登录官方账户，支持 Google 登录。
2. 登录成功后回到 Guard 点击“完成登录并同步”，让 Guard 关闭它自己打开的专用浏览器进程并后台读取；也可以关闭专用窗口后点击“刷新”。日常 Chrome 可以照常使用。若资料被无法确认归属的浏览器占用，Guard 不会强制关闭它。
3. 在“后台自动同步”选择仅手动，或每 1、2、5、10、30、60 分钟。默认每五分钟，选择会保存，重开 Guard 后仍生效；改变频率不会立即发起请求。

自动同步使用 Chrome 的无头模式，不创建可见窗口，不切换日常浏览器标签或前台应用。只有你点击登录按钮才打开专用登录窗口；自动同步失败不会自行弹出登录窗口。

专用浏览器使用独立登录资料，不能直接沿用日常 Chrome 的 Google 登录，因此升级后需要在专用窗口重新登录一次。Guard 不复制日常浏览器的 Cookie 或账户资料。网页登录状态由专用 Chrome 资料保存；Guard 只接收经校验的用量数值、套餐和月份。

“暂停同步”停止后续请求，并取消正在进行的额度读取，不会退出账户。Pro 无限额度不显示有限进度条。临时失败保留上次成功值和真实同步时间；数据过期阈值随频率调整，至少十五分钟。登录失效时提示重新登录。

额度接口是官方网页当前使用的只读接口，并非承诺稳定的公开 API，网站改版可能影响同步。Chrome 的无窗口运行方式见[官方无头模式说明](https://developer.chrome.com/docs/automation-and-testing/headless)。

## 遇到异常时

### 控制台在线，工具却调用失败

控制台在线通常反映设备登记或心跳。先看本机异常和最近真实调用。需要主动验证设备回应时，可开启主动探测并手动 ping，一次请求受所选间隔约束。设备 `ping` 直接返回，不经过本机工具执行。

工具执行使用近期明确成功的真实调用；证据超过 120 秒就标为过期，不再自动发送 `list_sessions` 补证据。确需检查本机工具层时，可使用下方 `--probe-tool` 诊断命令；它同样受主动探测开关和间隔约束，可能消耗额度，结果正文会被丢弃。工具探针失败本身不会触发自动重启。

### “本机日志覆盖有缺口，无法安全确认空闲”

这表示 Guard 看不到完整的调用过程，例如日志被轮换、截断、丢失、读取失败，或尚未读完。它无法排除仍有任务运行，因此暂缓恢复。这个提示本身不证明 Commander 已经断链，也不证明任务已经结束。

### “云端实时服务连接池异常”

Guard 在日志里识别到了 `IncreaseConnectionPool`。这类云端容量异常会阻止本机自动重启。复查受所选主动探测间隔约束；故障退避不能绕过该间隔，关闭主动探测后暂停。

请结合最近一次检查结果和时间判断当前状态。旧的容量告警或控制台在线记录，都不能单独确认当前命令通道是否恢复。Guard 可以记录故障和复查经过，无法从本机扩容或修复云端连接池。相关说明见 [Realtime Error Codes](https://supabase.com/docs/guides/realtime/error_codes) 和 [Realtime Settings](https://supabase.com/docs/guides/realtime/settings)。

### ChatGPT 显示 “Connection interrupted” 或 “Message delivery timed out”

Guard 能观察本机日志中的部分回答恢复、刷新失败和更新连接事件，但当前日志没有每次屏幕超时提示对应的专属最终事件。因此，它可能没有识别到你看到的提示，也无法保证判断原回答是否完整恢复。

更新连接重建只证明该连接重建；“恢复完成”也只适用于对应恢复路径。Guard 不会控制 ChatGPT 的原回答流、自动续传、重发消息、重启 ChatGPT 或切换网络。技术复核见 [CHAT-LIVENESS-REVIEW.md](CHAT-LIVENESS-REVIEW.md)。

## 自动恢复的条件

恢复需要同时开启主动探测和自动恢复，且探测记录可安全读取和保存。关闭主动探测不会改变保存的自动恢复许可，但会暂停新恢复；面板明确显示原因。

Guard 在自动探测中累计收到 3 次明确的“设备没有活动连接”后，才进入恢复判断。较长间隔会推迟判断；例如每 3 小时检查一次，三次确认通常要跨越数小时。探测只检查当时的通道，Commander 自身的心跳和重连仍由 Commander 负责。中间的未知结果不会清零这些断链证据，明确健康的 `ping` 会清零。

开启这个开关表示允许 Guard 重启受管理的本机 Commander 服务。关闭后仍会监测和提示，但不会发起新的自动重启；已经开始的重启无法撤销。该设置会保存。它不会在服务本来未运行时无条件启动服务，也不会修复云端服务或重新登录。

重启前必须开启自动恢复，并同时确认：

- 本机调用已结束，日志覆盖完整且可读；
- Commander 进程树符合预期，没有额外子进程；
- 云端没有待执行或执行中的调用；
- 距离上次恢复尝试已满足五分钟冷却条件。

超时、登录失效、无法识别的响应、工具探针失败和云端容量异常，都不会单独触发重启。重启后验证也要等待所选探测间隔。等待期间显示“恢复尚未确认”；只有服务进程 PID 已变化且对应新服务的 `ping` 成功，才报告恢复成功。这个结果不代表原业务任务已继续完成。

这些检查仍不能保证覆盖所有独立后台任务。需要人工控制服务时，可以关闭自动恢复。

### 防止闲置睡眠

开启“防止闲置睡眠（Guard）”后，Guard 仅在识别到 Commander 服务运行时向 macOS 提交防闲置系统休眠请求，面板会区分正在生效、等待服务和请求未生效。关闭后释放 Guard 自己的请求；其他程序（包括 Commander 自带的防休眠进程）仍可能保持电脑唤醒。屏幕仍可息屏，手动睡眠、重启及其他强制睡眠情形不受此开关保护。这个偏好会跨 Guard 重启保存，和自动恢复互不影响。

## 数据与隐私

Guard 只读现有登录信息和日志，不写入或刷新 Commander 登录凭据。设备登记、待执行调用和固定探针查询使用已有授权；额度同步使用独立 Chrome 资料和无头浏览器，不控制日常 Chrome 窗口。

操作记录包含脱敏后的命令摘要、路径、时间和状态。常见凭据与内联脚本会被隐藏，但自定义秘密格式仍可能无法识别。不要在命令行中直接放置敏感值，分享记录前也应检查内容。

Guard 不读取聊天正文。探针和工具结果正文、原始错误响应、登录令牌、原始会话标识，以及额度账户的 Cookie、密码、令牌、邮箱和原始响应，不会写入它的状态或决策日志。

<details>
<summary>本机数据文件与会话归属</summary>

状态文件位于 `~/Library/Application Support/CommanderGuard/`：

| 文件 | 内容 |
|---|---|
| `status.json` | 服务、通道、工具执行、调用状态和可选额度摘要 |
| `timeline.jsonl` | 脱敏事件，最多 1 MiB，保留一个轮替副本 |
| `channel-incident.json` | 当前及最近通道故障类别、时间、退避和恢复状态 |
| `channel-decisions.jsonl` | 探测与恢复决策，最多 512 KiB，保留一个轮替副本 |
| `channel-recovery.json` | 自动恢复开关和最近尝试时间，不含凭据 |
| `active-probe-budget.json` | 主动探测许可、间隔与上次请求时间；不含凭据，重开不清零；旧版记录升级后关闭探测 |

会话归属只接受上游明确提供的 `_meta["openai/session"]` 或 `origin_context_id`，原值经 SHA-256 转为短匿名指纹。缺少字段时不显示归属提示，字段冲突仍显示“归属冲突”。时间接近、前台聊天、终端进程和 `origin_instance` 都不作为归属依据。

当前配对链路尚缺稳定会话字段透传，实际调用可能仍无法区分 ChatGPT 会话；Guard 会显示具体工具和操作，不反复附上无用的未确认归属。进展见 [Remote Desktop Commander #12](https://github.com/desktop-commander/remote-desktop-commander/issues/12) 和 [CHAT-COMMANDER-ATTRIBUTION-REVIEW.md](CHAT-COMMANDER-ATTRIBUTION-REVIEW.md)。

Guard 也会读取 `~/.claude-server-commander/tool-history.jsonl`，只提取工具名、实际时间、耗时和返回状态，丢弃参数及结果正文。该格式没有可靠调用编号，所以不会按时间与其他记录强行合并，也不会单独用它证明当前空闲。

历史重建中缺失的时间和耗时会标为未知。本机调用返回不证明云端已收到结果，也不证明整轮 ChatGPT 任务完成。

</details>

## 手动检查与开发

以下命令在项目目录运行。两个探针同样受主动探测开关与共享间隔约束；关闭时不会访问云端。开启后使用真实连接，可能消耗额度，不会启动自动恢复。`--probe-tool` 会发送只读工具调用。

```bash
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --probe-channel
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --probe-tool
```

只读查看开关、频率与下一次可探测时间，不读取凭据或发送请求：

```bash
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --active-probe-status
```

离线自检不会启动守护或操作 Commander 服务：

```bash
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --self-test
```

无头浏览器检查会在临时资料里连续启动两次 Chrome 空白页，核对关闭后没有残留锁、前台应用未改变。它不读取账户或真实额度：

```bash
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --probe-headless
```

UI 预览使用固定示例，不启动监控、恢复或额度请求，也不写入状态：

```bash
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --preview-ui
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --preview-ui --verify-ui
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --preview-ui --preview-dark --verify-ui
```

实现使用原生 AppKit。应用图标为 `Assets/AppIcon.png` 和 `Assets/AppIcon.icns`，菜单栏使用单色盾牌与连接标识。界面结构参考 [Little Snitch](https://help.obdev.at/littlesnitch6/lsm-overview) 和 [Stats](https://github.com/exelban/stats)。

## 卸载

通过安装脚本安装的版本，可在项目目录执行：

```bash
./uninstall.sh
```

它会移除 Guard 应用、桌面入口和登录启动项，保留项目源码、状态和日志。只从 `build/CommanderGuard.app` 运行的用户，退出后删除构建产物即可。

## 项目文档

- [TODO.md](TODO.md)：功能优先级和验收条件。未完成项目不属于当前能力。
- [PROBE-QUOTA-REVIEW.md](PROBE-QUOTA-REVIEW.md)：探测频率、真实额度对照和替代方式；不把未证实的计费推测当作结论。
- [CHAT-COMMANDER-ATTRIBUTION-REVIEW.md](CHAT-COMMANDER-ATTRIBUTION-REVIEW.md)：会话归属与上游字段缺口。
- [CHAT-LIVENESS-REVIEW.md](CHAT-LIVENESS-REVIEW.md)：ChatGPT 回答流与保活能力复核。
- [DIAGNOSIS.md](DIAGNOSIS.md)：历史超时诊断。
- [RESEARCH.md](RESEARCH.md)：长任务、超时及公开方案调研。

这些详细文档目前主要为中文。报告问题时，请提供 macOS 与 Commander 版本、运行方式、故障时间，以及脱敏后的面板状态；不要提交登录信息或完整私有日志。

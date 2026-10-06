<p align="center">
  <img src="Assets/AppIcon.png" width="112" alt="CommanderGuard icon">
</p>

<h1 align="center">CommanderGuard</h1>

<p align="center">
  macOS 上用于观察 <strong>Remote Desktop Commander ↔ 本机工具执行 ↔ ChatGPT App</strong> 的轻量守护与诊断工具。
</p>

CommanderGuard 关注的是 **命令链路和 ChatGPT App 自身的可观察状态**。它不会把“设备在线”“ping 成功”“本机命令已返回”混成同一件事，而是把链路拆成三层分别判断：

| 层级 | CommanderGuard 判断什么 | 主要证据 |
|---|---|---|
| **消息通道** | Remote Desktop Commander 的远端消息是否还能到达这台 Mac | 针对当前设备、请求编号匹配的 MCP `ping` / `pong` |
| **工具执行** | 本机工具调用是否真的能执行并返回 | 近期真实成功调用，或满足安全条件时的只读 `list_sessions` 探针 |
| **ChatGPT 回答** | 本机 ChatGPT App 最近是否出现回答恢复、断流或重连异常 | App 的固定结构化日志事件 |

> **重要：** 某一层正常，不代表其他层也正常。 `ping` 成功只能证明消息通道可回应；它不能证明本机工具一定执行成功，也不能证明 ChatGPT 的原回答流已经恢复。

### 产品边界

CommanderGuard **不负责代理、隧道、节点或网络策略**。这类问题属于独立的网络诊断工具，不应通过读取另一个 App 的私有状态文件来耦合进 CommanderGuard。即使 ChatGPT 与 Commander 在相近时间同时异常，本项目也只报告“可能受共同环境影响”，不会据此认定代理、隧道或网络是根因。

它同样不会读取聊天正文、自动重发消息、重试业务任务，或把未知状态当作“可以安全重启”。

> **上游跟踪：ChatGPT 会话归属**
>
> CommanderGuard 已兼容 OpenAI 的 `openai/session` 和建议的 `origin_context_id`，但 Remote Desktop Commander 当前尚未把稳定会话字段透传到配对设备。进展可直接跟踪 [Remote Desktop Commander #12 — Preserve stable ChatGPT conversation identity in remote tool-call metadata](https://github.com/desktop-commander/remote-desktop-commander/issues/12)。

后续功能、优先级和验收条件见 [TODO.md](TODO.md)。待办里未完成的项目不属于当前能力。

---

## 快速开始

### 1. 前置条件

先安装并登录 [Remote Desktop Commander](https://github.com/desktop-commander/remote-desktop-commander)，并确认它已经在本机运行。

### 2. 构建、测试并安装

在项目目录执行：

```bash
./build.sh
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --self-test
./install.sh
```

安装脚本会：

- 构建并签名 CommanderGuard；
- 安装到 `~/Applications/CommanderGuard.app`；
- 创建桌面入口与登录自启项；
- 只重新启动 **CommanderGuard** 本身。

它**不会**重新登录、重启或修改已经运行的 Desktop Commander 服务。

> 当前安装脚本使用固定项目路径：`/Volumes/ExtSSD/Projects/CommanderGuard`。

首次安装且没有旧设置文件时，“自动恢复命令连接”默认开启。它和“保持电脑唤醒”是两个互相独立的开关。

---

## 主界面

点击菜单栏图标，或再次打开桌面入口，会进入同一个主面板。

概览和连接状态页顶部显示三张状态卡：

- 消息通道
- 工具执行
- ChatGPT 回答

操作记录页会隐藏这些重复状态控件，把空间留给记录本身。

主面板分为三个页面：

### 概览

只回答两个问题：

- **当前状态**：当前最重要的状态，以及是否需要你处理；
- **当前任务**：有没有本机工具正在执行，以及必要时提示为什么 Guard 暂时不能判断空闲。

这里不再重复连接历史、自动恢复细节或事件列表。

### 操作记录

显示最近最多 100 次本机工具调用。记录表会使用完整可用宽度，点击一条记录后查看脱敏后的时间、状态、耗时、操作详情和匿名会话归属（如果上游提供可靠字段）。

支持按命令、工具、路径和会话搜索，并提供“全部 / 进行中 / 异常与未确认”三种筛选。ChatGPT App 事件不再混在这个页面里。

### 连接状态

只显示用户需要判断的连接信息：

- 当前连接处理状态；
- 自动恢复当前是否可用，以及为什么会暂缓；
- 最近一次连接问题何时发生、是否已经恢复。

如果当前没有连接问题，就不会额外堆叠日志来源、诊断依据或事件列表。

---

## 状态栏含义

| 标记 | 含义 |
|---|---|
| `●` | 消息通道近期已明确回应 |
| `!` | 服务未运行，或通道已明确报错 |
| `?` | 尚未确认、结果已过期，或当前证据不足 |

“未观察到新调用”只表示当前可见日志里没有新调用；如果日志存在缺口，CommanderGuard 不会把它当成“已经确认空闲”。

---

## 消息通道与工具执行为什么要分开

在没有已观察故障时，CommanderGuard 启动约 90 秒后才进入常规定期 MCP `ping`；这是启动宽限，不是故障解释。若日志已经观察到持续通道异常，故障驱动的只读复查会绕过这段常规启动等待，并按退避节奏执行。

只有同时满足以下条件，才会把消息通道标记为可回应：

- 响应属于当前设备；
- 请求编号匹配；
- 收到对应 `pong`。

这个 `ping` 由 Commander 设备端直接返回，**不会经过真实本机工具执行**。

因此，工具执行有自己独立的 120 秒证据有效期：

1. 优先复用最近一次明确成功的真实工具调用；
2. 如果证据过期，且本机确认空闲、日志完整、消息通道可回应，才发送固定的只读 `list_sessions` 探针；
3. 探针正文会被丢弃，只保留“已验证 / 失败 / 未知”、检查时间和必要错误类别。

工具检查失败本身不会增加自动重启条件。

---

## 持续通道异常如何处置

CommanderGuard 不再把所有断链都压成同一个“通道错误”。它会把可安全识别的信号归为固定、脱敏的类别，并把**当前健康状态**与**最近故障记录**分开显示。

| 观察到的信号 | Guard 的处理 | 会不会因此重启本机 Commander |
|---|---|---|
| `IncreaseConnectionPool` | 显示 **“云端实时服务连接池异常”**；立即进入有限频率的只读复查，随后按 10 / 20 / 40 / 80 / 120 秒退避；本次故障只记录一次容量告警 | **不会**。这是云端 Realtime 容量类异常，本机重启不能修复 |
| 明确返回“设备没有活动连接” | 记为明确设备断链；累计达到 3 次后才进入既有的安全恢复判断 | 只有任务、日志、进程树、云端待执行调用和冷却条件全部允许时才可能重启 |
| 网络或服务结果未知 | 保存为“未知”，继续有限频率复查 | **不会**。未知既不等同于断链，也不会抹掉此前已确认的断链历史 |
| 普通通道错误 / 关闭 / 订阅超时 | 记为持续通道异常并安排只读复查 | 不单凭这些日志重启；仍需明确设备断链证据 |

Supabase 对 `IncreaseConnectionPool` 的说明见 [Realtime Error Codes](https://supabase.com/docs/guides/realtime/error_codes) 与 [Realtime Settings](https://supabase.com/docs/guides/realtime/settings)：该错误表示 Realtime 使用的数据库连接池不足。CommanderGuard 能做的是**识别、提示、退避复查并记录恢复经过**，不能从本机修复云端连接池。

每次通道探测、结果类别、连续明确断链计数、恢复判断、暂缓原因和恢复结果都会写入受限大小的脱敏决策日志。日志只保存固定类别与时间，不保存 MCP 原始响应、凭据、命令正文或工具结果。

---

## 自动恢复：什么时候会重启 Commander

CommanderGuard 的自动恢复设计原则是：**宁可暂缓，也不要在任务仍可能运行时误重启。**

只有累计收到 **3 次明确的“设备没有活动连接”**，才会进入自动恢复判断。中间出现“网络或服务未知”不会把这些明确断链证据清零；明确健康的 `ping` 才会清零计数。

以下情况不会直接触发重启：

- 普通超时；
- 网络或服务状态未知；
- 登录失效；
- 无法识别的响应；
- `IncreaseConnectionPool` 等已识别的云端容量异常；
- 工具探针失败；
- 日志不完整；
- 当前仍有业务调用；
- 自动恢复已关闭；
- 处于冷却期。

真正重启前还会确认：

- 云端没有待执行或执行中的调用；
- 本机日志没有未结束或状态不明的调用；
- Commander 进程树没有额外子进程；
- 日志覆盖足够完整；
- 五分钟冷却条件允许。

重启后，只有同时满足：

1. Desktop Commander 服务 PID 已变化；
2. 新服务的 `ping` 成功；

才会报告“恢复成功”。

自动恢复**不会**：

- 重放命令；
- 重新提交图片生成；
- 自动发送聊天消息；
- 自动继续未完成的远端任务。

这些保护能减少误伤，但不能保证识别所有独立运行的后台任务。

---

## 操作记录与会话归属

CommanderGuard 会从当前服务时期的日志重建调用状态，并保留脱敏后的调用摘要。

历史重建记录会明确标注时间或耗时是否未知；日志轮换、截断、丢失或读取失败也会单独记录，不会因为“安静了一段时间”就假定任务完成。

### ChatGPT 会话归属

CommanderGuard **只接受上游明确提供的稳定会话字段**，不会靠时间或窗口位置猜测。

当前支持：

- OpenAI 官方 `_meta["openai/session"]`
- Remote Desktop Commander issue #12 建议的 `origin_context_id`

收到原始值后会立即做 SHA-256，只保存和展示短匿名指纹，例如：

```text
会话 A1B2C3D4E5
```

以下信息**不会**被当作会话归属依据：

- `origin_instance`
- 调用时间接近
- 当前前台聊天
- 终端进程

如果两个稳定字段互相冲突，记录会显示“归属冲突”；如果没有稳定字段，则显示“归属未确认”。

> 当前 Remote Desktop Commander 0.2.51 的云端调用 metadata 仍未透传这两个稳定字段，所以真实调用通常仍显示“归属未确认”。

详细复核见 [CHAT-COMMANDER-ATTRIBUTION-REVIEW.md](CHAT-COMMANDER-ATTRIBUTION-REVIEW.md)。

### 结构化工具历史

CommanderGuard 还会只读：

```text
~/.claude-server-commander/tool-history.jsonl
```

它只提取：

- 工具名；
- 实际时间；
- 耗时；
- 已返回 / 返回错误 / 未知。

参数正文和结果正文不会进入 CommanderGuard 的 UI 或状态文件。

由于这个历史格式没有可靠调用编号，CommanderGuard 不会按时间把它和 stdout 记录、ChatGPT 会话强行合并，也不会单独把它当成“当前空闲”的证明。

---

## ChatGPT App 监控

CommanderGuard 会只读观察当前本机 ChatGPT App 的固定结构化事件，包括：

- 回答恢复尝试；
- 恢复流不可用；
- 恢复完成；
- 恢复检查失败；
- 对话状态刷新失败；
- 更新连接关闭、失败、重连、重连耗尽与重新建立。

启动时会分批读取最近的 App 日志，并从自己的脱敏时间线恢复最近异常。

界面会把 **当前 ChatGPT 状态** 和 **最近一次历史回答异常** 分开：顶部状态卡只表示当前是否正常；历史异常保留在“连接状态”页。如果后续连接已经恢复，CommanderGuard 会明确显示“当前连接正常”，同时保留“原中断回答是否完整恢复无法从日志确认”的历史说明，而不会让旧异常永久占据当前状态。

这里有几个重要边界：

- “恢复完成”只表示对应恢复路径成功，不代表其他异常也已恢复；
- 更新连接重新建立，不代表原回答已经恢复；
- `Connection interrupted` 表示响应中断后进入轮询等待；
- `Message delivery timed out` 表示这段轮询等待超时，不能据此判断用户消息是否已经发出；
- 当前日志没有每次屏幕 `Message delivery timed out` 提示对应的专属最终事件。

CommanderGuard 不会：

- 读取或保存聊天正文；
- 自动发送消息；
- 自动重试任务；
- 重启 ChatGPT；
- 切换网络。

详细复核见 [CHAT-LIVENESS-REVIEW.md](CHAT-LIVENESS-REVIEW.md)。

---

## 隐私与安全边界

CommanderGuard 的原则是：**尽量保存状态，不保存内容。**

本机状态位于：

```text
~/Library/Application Support/CommanderGuard/
```

主要文件：

| 文件 | 内容 |
|---|---|
| `status.json` | 当前服务、通道、工具执行、调用与脱敏故障处置状态 |
| `timeline.jsonl` | 脱敏事件时间线，最多 1 MiB，并保留一个轮替副本 |
| `channel-incident.json` | 当前 / 最近通道故障类别、首次与最近时间、退避状态和恢复时间 |
| `channel-decisions.jsonl` | 通道探测与恢复决策历史，最多 512 KiB，并保留一个轮替副本 |
| `channel-recovery.json` | 自动恢复开关与最近尝试时间，不含登录凭据 |

CommanderGuard 会读取已有本机登录信息，用于查询设备登记、待执行调用和发送固定 `ping`，但不会写入或刷新登录凭据。

以下内容不会写入 CommanderGuard 的状态、时间线或通道决策日志：

- 探针正文和 MCP 原始响应；
- Commander 原始错误详情；
- 登录令牌；
- 原始 ChatGPT 会话标识；
- 命令正文与工具结果正文。

命令预览会隐藏常见凭据及内联脚本，但自定义秘密格式仍不应该直接放进命令行。

---

## 手动检查与开发命令

### 离线自检

不会启动 Guard，也不会操作 Commander 服务：

```bash
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --self-test
```

### 离线 UI 预览

使用固定示例数据，不启动监控或恢复，也不写状态：

```bash
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --preview-ui
```

检查常规 / 最小尺寸及浅色 / 深色布局：

```bash
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --preview-ui --verify-ui
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --preview-ui --preview-dark --verify-ui
```

### 单独检查两层链路

只检查消息通道：

```bash
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --probe-channel
```

只检查真实本机工具执行：

```bash
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --probe-tool
```

这两个探针都不会启动自动恢复。

---

## 当前已知限制

- Remote Desktop Commander 当前没有把稳定 ChatGPT session metadata 透传到配对设备，因此会话归属通常仍是“未确认”；见 [上游 issue #12](https://github.com/desktop-commander/remote-desktop-commander/issues/12)。
- 本机工具调用返回，不代表云端一定已经收到结果，也不代表整轮 ChatGPT 任务已经完成。
- `ping` 和更新连接恢复都不能单独证明原回答流已经恢复。
- CommanderGuard 只能根据可观察证据避免误重启，不能保证识别所有独立后台任务。
- `IncreaseConnectionPool` 这类云端 Realtime 容量异常只能由 Guard 识别、退避复查和提示；本机 Guard 不能扩容或修复 Supabase / Remote Desktop Commander 的云端连接池。
- ChatGPT App 当前没有经验证的、供第三方 Guard 控制原回答流的受支持接口。
- 安装脚本目前仍依赖固定项目路径。

---

## 项目文档

| 文档 | 用途 |
|---|---|
| [TODO.md](TODO.md) | 当前优先级、验收条件和实施进度 |
| [CHAT-COMMANDER-ATTRIBUTION-REVIEW.md](CHAT-COMMANDER-ATTRIBUTION-REVIEW.md) | ChatGPT 会话归属、`openai/session` 与 RDC metadata 缺口 |
| [CHAT-LIVENESS-REVIEW.md](CHAT-LIVENESS-REVIEW.md) | ChatGPT App 回答流、续传与保活能力复核 |
| [DIAGNOSIS.md](DIAGNOSIS.md) | ChatGPT App / Commander 历史超时诊断 |
| [RESEARCH.md](RESEARCH.md) | 长任务、超时与相关公开方案调研 |

---

## UI 与实现

CommanderGuard 使用原生 AppKit，支持：

- 系统浅色 / 深色外观；
- 可调整窗口尺寸；
- 菜单栏实时状态；
- 固定示例 UI 预览与布局自检。

界面分层参考：

- [Little Snitch](https://help.obdev.at/littlesnitch6/lsm-overview) 的概览、列表和详细信息结构；
- [Stats](https://github.com/exelban/stats) 的菜单栏监测用途。

应用图标位于：

```text
Assets/AppIcon.png
Assets/AppIcon.icns
```

菜单栏使用同一语义的原生单色盾牌 / 连接标识。

---

## 卸载

```bash
./uninstall.sh
```

卸载脚本会移除：

- CommanderGuard 应用；
- 桌面入口；
- 登录启动项。

项目源码和 CommanderGuard 状态文件会保留。

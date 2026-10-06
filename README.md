# CommanderGuard

CommanderGuard 是一个 macOS 菜单栏守护工具，用来观察 **Remote Desktop Commander、ChatGPT App 与本机网络路径** 的状态。

它不把“设备在线”“ping 成功”“本机命令已返回”混成同一件事，而是把链路拆成四层分别判断：

| 层级 | CommanderGuard 判断什么 | 主要证据 |
|---|---|---|
| **消息通道** | 远端消息是否还能到达这台 Mac | 针对当前设备、请求编号匹配的 MCP `ping` / `pong` |
| **工具执行** | 本机工具调用是否真的能执行并返回 | 近期真实成功调用，或满足安全条件时的只读 `list_sessions` 探针 |
| **ChatGPT 回答** | 本机 ChatGPT App 最近是否出现回答恢复、断流或重连异常 | App 的结构化日志事件 |
| **网络路径** | 本机已知网络守护是否报告代理、隧道或网页探测异常 | TunnelSentinel 的只读状态（如已安装） |

> **重要：** 某一层正常，不代表其他层也正常。
>
> 例如 `ping` 成功只能证明消息通道可回应，不能证明本机工具一定执行成功，更不能证明 ChatGPT 的原回答流已经恢复。

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

顶部始终显示四张状态卡：

- 消息通道
- 工具执行
- ChatGPT 回答
- 网络路径

主面板分为三个页面：

### 概览

优先显示：

- 当前最值得处理的问题；
- 观察时间；
- 下一步建议；
- 本机活动；
- ChatGPT 更新连接；
- 最近事件。

### 操作记录

显示最近最多 100 次本机工具调用，包括：

- 工具 / 命令；
- 状态；
- 观察时间；
- 耗时；
- 匿名会话归属（如果上游提供可靠字段）。

支持按命令、工具、路径和会话搜索，并提供：

- 全部
- 进行中
- 异常与未确认

三种筛选。

### 连接诊断

按主题整理：

- Commander 消息通道；
- 实际工具执行；
- 自动恢复；
- ChatGPT 回答异常；
- 日志覆盖与缺口；
- 网络守护状态；
- 最近连接事件。

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

CommanderGuard 启动约 90 秒后，会定期发送无副作用的 MCP `ping`。

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

## 自动恢复：什么时候会重启 Commander

CommanderGuard 的自动恢复设计原则是：**宁可暂缓，也不要在任务仍可能运行时误重启。**

只有服务**连续三次明确返回“设备没有活动连接”**时，才会进入自动恢复判断。

以下情况不会直接触发重启：

- 普通超时；
- 网络故障；
- 登录失效；
- 无法识别的响应；
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

## 网络路径与 TunnelSentinel

如果本机安装了 TunnelSentinel，CommanderGuard 只读取它选定的状态：

- 检查时间；
- 网页探测结果；
- 代理是否可用；
- 隧道状态；
- 手动暂停；
- 失败计数。

它不会读取：

- 节点列表；
- 代理配置；
- 探测正文；
- 原始日志。

也不会启动、重启或修改 TunnelSentinel。

网页探测正常只能说明某条网络路径可达，**不能证明 ChatGPT 的持续回答连接正常**。

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
| `status.json` | 当前服务、通道、工具执行与调用状态 |
| `timeline.jsonl` | 脱敏事件时间线，最多 1 MiB，并保留一个轮替副本 |
| `channel-recovery.json` | 自动恢复开关与最近尝试时间，不含登录凭据 |

CommanderGuard 会读取已有本机登录信息，用于查询设备登记、待执行调用和发送固定 `ping`，但不会写入或刷新登录凭据。

以下内容不会写入状态或时间线：

- 探针正文；
- 登录令牌；
- 原始 ChatGPT 会话标识；
- 命令结果正文。

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

- Remote Desktop Commander 当前没有把稳定 ChatGPT session metadata 透传到配对设备，因此会话归属通常仍是“未确认”。
- 本机工具调用返回，不代表云端一定已经收到结果，也不代表整轮 ChatGPT 任务已经完成。
- `ping`、网页探测和更新连接恢复都不能单独证明原回答流已经恢复。
- CommanderGuard 只能根据可观察证据避免误重启，不能保证识别所有独立后台任务。
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

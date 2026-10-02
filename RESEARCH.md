# ChatGPT App 的任务进度与超时预防调研

核对日期：2026-10-01。适用范围为普通 ChatGPT macOS App 的 Chat 模式，通过 Remote Desktop Commander 操作本机；不包含浏览器扩展、自动发送 Continue/“继续”消息，也不涉及 Codex CLI、Remote 或 Work 专用控制接口。本轮只读查阅 GitHub Issue、README 和关键源码，没有安装第三方软件、改动 Commander 或向远端会话发送消息。

## 查到的不同故障

| 故障 | 公开证据 | 对当前守护的意义 |
|---|---|---|
| 云端接受了调用，但本机未收到 | [Remote Desktop Commander #2](https://github.com/desktop-commander/remote-desktop-commander/issues/2)，报告设备进程仍在，调用未进入本机接收日志；评论讨论持久请求和 REST 补偿读取 | 本机在线与本机调用成功率不能证明云端请求送达。补偿执行需要请求身份、认领与去重，不能由旁路守护重放任意命令；本轮不修改此服务。 |
| 工具等待超时，后台进程仍运行 | [DesktopCommanderMCP #447](https://github.com/wonderwhy-er/DesktopCommanderMCP/issues/447) 及复现评论；[PR #553](https://github.com/wonderwhy-er/DesktopCommanderMCP/pull/553) 与 [PR #766](https://github.com/wonderwhy-er/DesktopCommanderMCP/pull/766) 当前仍未合并 | 超时不等于命令失败。可在远端任务约定短启动等待、记录 PID、短轮询直到终态；不要因超时重复启动同一命令。约 60 秒是特定报告路径的观察，不是通用限制。PR #766 是 Commander 服务端改动提案，本轮不应用或验证。 |
| 本机工具已经返回，ChatGPT 未继续消耗结果 | [Chat On Steroids #27](https://github.com/totec448-spec/chat-on-steroids/issues/27)，含后台结果保留、手动轮询立即取得结果的记录；[后续 #36](https://github.com/totec448-spec/chat-on-steroids/issues/36) 处理未读结果积压 | 单看本机工具日志不能确认云端是否收到、是否继续。需要会话侧状态和后台会话状态共同判断。Issue 已关闭，不意味着任意 ChatGPT 停滞都已被解决。 |

[OpenAI 社区支持回复（2026-01-08、2026-05-31）](https://community.openai.com/t/progress-notifications-not-working-in-chatgpt-mcp-ts-sdk-1-20-0/1367559) 建议 MCP 长任务尽快返回 job ID，再通过轮询取得结果；2026-05-31 的回复称当时没有文档说明 ChatGPT 网页 MCP 的默认超时。这些是有日期的支持回复，不代表当前产品承诺，也不能直接外推到原生 macOS App。以上均为公开复现或讨论证据，不是对这台 Mac 的故障定因。未进行主动断网、故障注入或重跑用户任务。

## 现有项目的适用性

- [Chat On Steroids](https://github.com/totec448-spec/chat-on-steroids)：最接近普通 ChatGPT 网页的任务观察与续话。当前主分支含浏览器扩展、会话归属、网页工具进度、Goal/Loop；需要配套应用和自己的 MCP 接入，不能作为当前 Commander 的一个小补丁直接安装。代码有页面／本机活动交叉检查和终态确认，不应把它概括为固定间隔自动发送“继续”。本轮只查代码，未在本机验证可靠性。
- [Codex Goal Watchdog](https://github.com/flowing-water1/codex-watchdog)：依赖 Codex TUI/app-server 的线程、回合与 Goal 事件，不能直接控制普通 ChatGPT 会话。
- [ChatGPT AutoContinuer](https://github.com/punkshiraishi/chatgpt-auto-continuer/blob/main/content.js)：源码主要监听页面按钮并点击 Continue generating/Regenerate response，不识别 Commander 的命令或任务完成；不能证明会恢复持续显示生成中的工具循环。

Chat On Steroids 的源码证据仅说明网页扩展路径，不适用于本次原生 App 目标。源码核对：[当前快照](https://github.com/totec448-spec/chat-on-steroids/tree/7580143b58fa9509cbc50c4b822df2eb8e95f960)。`extension/content.js` 的长时间无可见进度提示不能独自证明卡死；它还排除已确认仍运行的高推理回合。`confirmedProviderTerminal` 与 Goal 发送条件复核会话归属、终态、未结束工具和输入框。此快照不等于对下载版的实际验收。

## 普通 ChatGPT macOS 客户端的边界

目标是普通 ChatGPT macOS App 的 Chat 模式；不包含浏览器扩展，也不自动发送 Continue/“继续”消息。现有 CommanderGuard 是本机 Commander 的被动观察器，不会更改远端工具的 `timeout_ms`，也不能保证云端编排继续运行。浏览器页面状态方案不适用于原生客户端，因此不建议将其作为当前方案。

当前可行的预防策略放在发起任务的远端调用约定中：让长命令短暂启动后立即取得并记录 PID；之后短时读取同一 PID 的输出并轮询，直到看到明确退出状态。这样短等待结束时，已安装的 Commander 仍可让后台进程继续运行；处理器调用时长与后台进程时长是两回事。请求超时后先检查原会话／PID 的状态，避免重复启动。只在有实际阶段变化时报告进度，验证结果并报告完成后停止；不发送空 keepalive，也不强行要求无限续跑。

本机只读抽样（2026-10-01 10:31 左右）：stdout 最新至多 512 KiB 中，解析出的 15 次 `start_process` 和 54 次 `read_process_output` 全部使用 `timeout_ms: 3000`。这仅覆盖一段日志，不代表整项任务，也没有云端回合归属；但说明所观察到的调用已经采用短等待。不能据此把此前的 timeout 归因于等待参数过大，也不能声称再缩短等待或增加旁路心跳就能解决。

按任务或阶段计算时长，需要远端代理提供明确任务身份以及开始、阶段和结束标记。现有日志没有这些语义标记，因此不能从沉默推断任务开始、冻结、完成或卡住；无新调用只代表“未观察到新调用”。该接入尚未实现，也未应用到远端聊天。

## 现在可给远端任务使用的约定

以下约定适用于普通 ChatGPT macOS App Chat 模式中，由远端代理调用 Commander 执行的长命令；可降低工具等待超时造成的误判，但不保证云端编排继续运行：

> 长命令用短启动等待（例如 `start_process` 的 `timeout_ms: 5000`），取得并记录 PID。后续用短 `read_process_output` 等待（例如 `timeout_ms: 5000–10000`，并限制每次读取长度）持续读取同一 PID，直到明确看到进程退出。工具请求超时后先检查原 PID／会话，再决定是否重试。只在有意义的阶段变化时说明进度；完成后核验结果、报告完成并停止。不要发送空 keepalive 或无限续跑。

约 60 秒超时来自特定报告路径，不是所有 Commander、客户端或远端调用的统一限制。短等待返回时后台进程仍可能继续运行；不要把一次处理器返回误当成整个长任务的完成。

按服务、工具和 ChatGPT 客户端分层排查，并收集工具调用记录：[OpenAI 插件故障排查](https://developers.openai.com/plugins/deploy/troubleshooting)。本轮未发现可确认直接适配现有 Mac + 普通 ChatGPT 客户端 + 当前 Commander、并保证任意停滞回合自动恢复的现成方案；上述调用约定尚未在远端应用。

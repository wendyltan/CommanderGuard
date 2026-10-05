# ChatGPT 探测与保活复核

复核日期：2026-10-05。对象：本机 ChatGPT App 26.930.31730。结论适用于这份已安装代码；后续版本可能变化。

## 能做到什么

Guard 可以被动观察本机 App 的连接关闭、重连、恢复尝试、恢复完成、恢复检查失败、重连耗尽及对话状态刷新失败。本次补齐后三类已存在的结构化日志事件，只保存固定事件名称、时间、已核对的会话名称；不保存原始错误、会话编号或聊天内容。

最近 8 个本机日志文件各末尾 2 MiB 中，发现 2 条恢复开始和 1 条恢复完成。恢复完成确实可观察，但不能据此清除另一条异常：日志没有供 Guard 使用的可靠同一轮回答关联信息。对话状态刷新失败也不能单独证明回答流失败。

## App 已经有哪些保护

只读检查 `ChatGPT.app/Contents/Resources/app.asar` 中以下资源：

- `webview/assets/app-initial-576fc7ca620e.js`：响应流接收器 `N0t` 接收服务端 heartbeat，收到有效数据后重置等待计时。检查到的默认首次等待为 5 秒，后续无数据等待为 30 秒。续传代码持有原回答的令牌、偏移及请求上下文，并有重试与轮询兜底。
- `webview/assets/app-primary-5fc751535eb1.js`：`Connection interrupted` 对应响应中断后回退到轮询；`Message delivery timed out` 对应轮询等待完整回答超时，不能说明用户消息没有发送。
- `webview/assets/app-shared-b72e16382796.js`：公共更新连接有退避重连和历史补取。重试耗尽后，返回 App 前台的焦点事件可再次触发重连；这不能保证原回答成功。

没有把页面编辑传输中的 `sendPing` 或遥测请求的 `keepalive` 当成 ChatGPT 回答流保活证据。收到服务端 heartbeat 与主动周期发送 ping 也不是同一件事。

## 为什么额外 ping 不能保活原回答

另一个 HTTP 请求或另一条 WebSocket 不属于 App 当前的回答连接，不能重置它的接收器、补回丢失的结果或恢复服务端已不可用的流。App 内部恢复还依赖登录会话、原会话及消息上下文、续传令牌和偏移。当前未验证到供第三方 Guard 操作这条原回答流的受支持接口；不能把“没有接口”泛化成任何形式的探测都不可能。

匿名 DNS／HTTPS 检查可以缩小网络问题范围。本次对 `chatgpt.com` 与 `ws.chatgpt.com` 的一次 HEAD 检查分别收到 403 与 404：说明测试路径上的 DNS 和 HTTPS 有响应，不能证明已登录 App 或 WebSocket 回答流正常，也不能仅凭状态码宣布网络故障。系统检查与 App 的代理路径可能不同。没有把这种检查加入持续轮询或用它清除回答异常。

## 实际处理办法

保持电脑唤醒可以减少主机睡眠造成的断连。若更新连接重连耗尽，可以回到 App 前台让其已有重连机制尝试恢复。出现回答中断或超时，先在原对话核对完整回答和操作记录，再决定是否手动继续，避免重复执行。没有自动刷新页面、重发消息、重启 ChatGPT、调整网络或调用私有认证接口。

[官方故障排查](https://learn.chatgpt.com/docs/reference/troubleshooting) 建议确认等待中的审批、终端和当前会话状态；需要重启时先等待活跃会话结束。[官方远程连接说明](https://learn.chatgpt.com/docs/remote-connections) 列出主机睡眠、断网和 App 关闭等断连因素。这些说明属于 Codex／Work 及其远程连接，不是 Desktop Commander 命令通道或每次 ChatGPT 回答的成功证明。[Responses API 的 WebSocket 模式](https://developers.openai.com/api/docs/guides/websocket-mode) 是开发者 API，不是控制 ChatGPT App 会话的接口。

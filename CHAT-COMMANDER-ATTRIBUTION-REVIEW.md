# ChatGPT 与 Commander 会话归属复核

更新时间：2026-10-05

## 结论

当前 Remote Desktop Commander 0.2.51 的远程调用链不能让 CommanderGuard **可靠地**把本机工具调用自动对应到具体 ChatGPT 会话。阻塞点位于托管 Remote Desktop Commander 的入站 metadata：ChatGPT 已提供稳定的匿名会话字段，但当前传到配对设备的 metadata 没有该字段。

CommanderGuard 不使用时间接近、当前前台聊天、终端进程或 `origin_instance` 猜测归属。上游字段缺失时保持“归属未确认”。

## OpenAI 已提供的稳定字段

OpenAI Plugins Reference 明确规定，工具调用可带：

- `_meta["openai/session"]`
- 类型：string
- 含义：匿名化 conversation id
- 用途：在同一个 ChatGPT session 中关联工具调用

2026-01-15 的 Plugins changelog 也明确记录了该字段上线。

参考：
- https://developers.openai.com/plugins/reference
- https://developers.openai.com/plugins/changelog

## 当前 Remote Desktop Commander 实测

对当前本机 Remote Desktop Commander `stdout.log` 的 16,976 条远程调用 receipt 做字段统计，metadata 出现的字段全集只有：

- `transport`
- `clientInfo.name`
- `clientInfo.version`
- `origin_instance`
- `is_internal_user`
- `device_app_version`
- 部分调用有 `dispatch_device_status`
- 部分调用有 `dispatch_last_seen_age_ms`

历史记录中没有观察到 `openai/session`、conversation、thread 或 turn 级稳定字段。

### origin_instance 为什么不能代替会话 ID

历史中 16,973 条可解析 receipt 只对应 216 个不同 `origin_instance`；多个单独的 origin 值跨越很长日志区间承载数百次、多个不同工具的调用。

此外，在同一次上层执行里连续发出的两个 `read_file` 调用也观察到不同的 `origin_instance`。

因此它更接近传输/执行实例，不能作为 ChatGPT conversation 的稳定身份。

### tool-call UUID 为什么也不能直接桥接

Commander receipt 的 call UUID 是逐调用唯一值。对近期 Commander call UUID 和 `origin_instance` 在 ChatGPT 本机日志及 Application Support 中做精确查找，没有找到共同值。

因此目前没有可用于 join 的共享主键。

## 为什么不按时间或前台会话猜

ChatGPT 桌面日志能观察到前台 conversation route 变化，但后台远程工具调用可在用户切换到其他会话后继续。因此“命令到达时当前打开哪个聊天”会产生误归属。

基于 ChatGPT turn start/completed 时间窗的实验也不可靠：当前活跃日志并不持续提供完整 turn 生命周期；历史 turn 还存在重叠和未闭合。对实际工具时间做窗口包含时，大部分调用无法唯一归属。

所以 CommanderGuard 不采用这两类启发式方法。

## 上游已知问题

Remote Desktop Commander 公共仓库已有完全对应的 feature request：

- Issue #12 — Preserve stable ChatGPT conversation identity in remote tool-call metadata
- https://github.com/desktop-commander/remote-desktop-commander/issues/12

该 issue 说明当前 `call_id` 仅逐调用唯一，`origin_instance` 不会在同一个 ChatGPT conversation 的连续调用间保持稳定，并建议在 `mcp_remote_calls.metadata` 增加稳定、匿名的 `origin_context_id`。

截至本次复核，issue 仍为 open，未看到对应 PR。

托管 Remote Desktop Commander 的服务实现并未公开在该仓库；本机可修改的是配对设备代理和本地 Desktop Commander，无法在本机补回托管入口已经丢失的 ChatGPT session metadata。

## CommanderGuard 已做的兼容

CommanderGuard 现在识别两种明确的会话归属字段：

1. `openai/session` — OpenAI 官方字段，优先。
2. `origin_context_id` — 兼容 RDC issue #12 建议的字段。

处理规则：

- 原始会话值只在内存中用于立即计算 SHA-256。
- ActivityStep 只保存 SHA-256；UI 仅展示前 10 个十六进制字符组成的匿名“会话 XXXXX”。
- `status.json` 只保存匿名显示值和字段来源，不保存原始 session。
- `origin_instance` 明确忽略。
- 同一 call ID 若收到互相冲突的稳定会话字段，则标记“归属冲突”，不采用任何一个。
- completion 行不会制造或覆盖会话归属。
- 没有稳定字段时继续显示“归属未确认”。

### 大参数调用

当前 Commander receipt 把 metadata 放在工具参数 JSON 之后，而 CommanderGuard 为安全和性能只保留有限日志前缀。

为了避免未来出现 `openai/session` 后，大参数调用反而丢失会话归属，日志读取器增加了有界尾部缓冲：

- 普通前缀仍按原规则读取、脱敏。
- 超过前缀上限后不保存中间的大段参数。
- 仅滚动保留末尾最多 8 KiB，用于寻找末尾 metadata。
- metadata JSON 自身最多接受 4 KiB。
- 这部分只提取受支持的会话字段，不进入命令详情。

## 何时能真正生效

只要 Remote Desktop Commander 托管入口开始把 ChatGPT 的 `openai/session` 原样或等价地透传到配对设备的 `mcp_remote_calls.metadata`，或者实现 issue #12 的 `origin_context_id`，CommanderGuard 无需再猜测即可自动：

- 在每条本机操作记录旁显示匿名会话归属；
- 把同一会话的连续命令识别为同一组；
- 为后续按会话诊断、保活状态和故障记录提供稳定键。

在上游尚未透传之前，当前真实调用应继续显示“归属未确认”。
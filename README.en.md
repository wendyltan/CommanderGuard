<p align="center">
  <img src="Assets/AppIcon.png" width="112" alt="CommanderGuard icon">
</p>

<h1 align="center">CommanderGuard</h1>

<p align="center">A macOS menu bar app for checking Desktop Commander connections, viewing local tool activity, and attempting recovery when safety checks permit.</p>

<p align="center"><a href="README.md">中文</a> · English</p>

Your device shows as online, but remote tools fail to run. CommanderGuard checks the message channel and local tool execution separately, helping you locate the failure. It also observes some ChatGPT App connection events and can show your Desktop Commander cloud tool calls usage.

This project is for macOS users who already use [Remote Desktop Commander](https://github.com/desktop-commander/remote-desktop-commander). The app UI is currently in Chinese. Automatic recovery depends on a specific local service and log layout; check the compatibility requirements below before installing.

## What it does

| Feature | What you can see or do |
|---|---|
| Live status | Menu bar icon and text show channel status; the panel tracks the message channel, tool execution, and ChatGPT answer state separately |
| Connection checks | MCP `ping` checks whether your device responds; a read-only `list_sessions` probe checks local tool execution when safety conditions permit |
| Automatic recovery | After repeated explicit disconnects, checks tasks, logs, processes, and cooldown before deciding whether to restart the managed Commander service |
| Activity records | Up to 100 recent local calls, with search, filters, redacted details, and anonymous session attribution when reliable upstream metadata exists |
| Cloud usage | Uses the official usage page in Chrome to display used, included, and remaining calls, progress, and the last successful sync time |
| ChatGPT observation | Reads local logs for some stream, resume, and update-connection events, separating current status from past incidents |
| Keep awake | Can prevent idle system sleep while the Commander service is running |

A successful check establishes the state of that layer only. Device registration, a successful `ping`, a returned local tool call, and a complete ChatGPT answer each need their own evidence. Guard does not resend chat messages or retry business tasks.

## Quick start

### 1. Check the requirements

You need macOS, a working Swift compiler, and an installed, signed-in, paired Remote Desktop Commander. The build uses the system AppKit and IOKit frameworks without additional Swift package dependencies. Install Xcode Command Line Tools if you do not have the compiler.

The current version expects the following layout. There are no settings for custom paths or service labels yet:

| Item | Expected location |
|---|---|
| Device credentials | `~/.desktop-commander-device/device.json` |
| Managed LaunchAgent | `com.wuwendi.remote-desktop-commander` |
| Commander logs | `~/Library/Logs/RemoteDesktopCommander/stdout.log`, `stderr.log` |
| Commander program | `~/.local/share/remote-desktop-commander/node_modules/@wonderwhy-er/desktop-commander/dist/index.js` |
| ChatGPT App logs | `~/Library/Logs/com.openai.codex` |

With a different launch method, Guard may be unable to identify the service or establish that it is idle, making automatic recovery unavailable. It does not reconfigure Commander to match this layout.

### 2. Build and run from source

Download or clone this repository, then run these commands in the project directory:

```bash
./build.sh
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --self-test
```

Open `build/CommanderGuard.app` in Finder after the build completes. Click its menu bar icon to open the panel. The source build is ad hoc signed locally; Developer ID notarization is not configured.

On a first run without an existing configuration, “自动恢复本机 Commander” (automatically recover local Commander) is enabled by default. Turn it off in the panel if you only want observation and diagnosis. “防止闲置睡眠（Guard）” (prevent idle sleep) is a separate toggle.

### 3. Check the connection

Click “检查链路” (check connection) in the panel. Guard checks the message channel first, then checks tool execution if the channel responds and local safety conditions permit. Routine checks have a startup grace period of about 90 seconds; an observed persistent channel fault schedules read-only rechecks sooner.

The panel explains why a tool check is deferred. Check for running tasks and incomplete logs before treating an unconfirmed state as idle.

### Optional: use the existing installer

**`install.sh` currently depends on `/Volumes/ExtSSD/Projects/CommanderGuard` and requires `/Volumes/ExtSSD/Projects` to exist. If you use a different directory layout, use the source build above first.**

Once your setup matches that layout, run:

```bash
./install.sh
```

The script builds the app, installs it to `~/Applications/CommanderGuard.app`, creates a desktop shortcut and login LaunchAgent, and restarts CommanderGuard. The installation steps do not restart or modify Remote Desktop Commander. Once Guard starts, its recovery toggle and safety checks determine whether automatic recovery can run. The login LaunchAgent attempts to relaunch Guard after an unsuccessful exit; a normal quit does not trigger relaunch.

## Everyday use

The panel has three pages, a resizable window, and support for system light and dark appearance.

| Page | What to look for |
|---|---|
| 概览 (Overview) | The status needing attention, local task activity, usage, main toggles, and the connection-check button |
| 操作记录 (Activity) | Hides `ping` checks by default; search commands, tools, paths, or known sessions, and select a row for its tool name, details, time and duration; choose “全部（含连接检查）” to include checks |
| 故障与恢复 (Incidents and recovery) | Recent incidents, probes, recovery times and results, without repeating Overview status cards or controls |

The menu bar keeps updating. The internal marker `●` means the message channel recently responded, `!` means the service is not running or the channel explicitly failed, and `?` means the result is unconfirmed, stale, or lacks evidence.

### Connect cloud usage

This shows Desktop Commander cloud tool calls usage, separate from your ChatGPT subscription limits. It is optional and currently requires Google Chrome.

1. Click “连接额度账户” (connect usage account) in Overview and sign in on the official page that opens. You can use your existing Google sign-in in Chrome.
2. Allow CommanderGuard to control Google Chrome when macOS requests Automation permission.
3. In Chrome, enable View → Developer → Allow JavaScript from Apple Events (Chinese: “视图 → 开发者 → 允许来自 Apple Events 的 JavaScript”).
4. Return to Guard and click “刷新” (refresh). Check that usage and a last successful sync time appear.

You can close the usage page after signing in. Once enabled, usage syncs every 2 minutes; manual refresh shows progress and failure reasons. Chrome must already be running with a regular window. Guard reuses a unique existing usage page, or creates a temporary background tab in the current Chrome window, reads usage, and closes only its own tab while preserving your active tab. It does not launch a Chrome you have quit. If several official usage tabs are open, make the account you want to read the active tab in the front Chrome window.

Without an existing usage page, the read uses the account in the current Chrome window, rather than a permanently bound account. With no existing usage page, a front incognito window prevents a new read; ambiguous page selection also pauses the read with guidance to select a regular window or account.

“暂停同步” (pause sync) stops further syncing without signing you out of Chrome. An unlimited Pro plan has no finite progress bar. Temporary failures retain and label the last successful values; data older than 15 minutes is marked stale, and an expired login clears old values.

Guard obtains validated usage fields through the official page's read-only interface. It does not export cookies, passwords, tokens, or email addresses. This is the interface currently used by the website, so website changes may break syncing.

## Troubleshooting

### The console says online, but tools fail

An online console entry generally reflects device registration or a heartbeat. Click the connection-check button to test your device's `ping` response, then inspect tool execution. The device answers `ping` directly, without running a local tool.

Tool execution prefers a recent, explicitly successful real call. Once that evidence is older than 120 seconds, Guard sends read-only `list_sessions` only if the channel responds, logs are complete, and the device is confirmed idle. Probe response bodies are discarded. A failed tool probe does not itself trigger a restart.

### Guard cannot safely confirm that the device is idle

The message “本机日志覆盖有缺口，无法安全确认空闲” means Guard cannot see the complete call history. Logs may have rotated, been truncated or lost, failed to read, or not yet been fully read. Recovery is deferred because a task may still be running. The warning alone establishes neither a disconnect nor task completion.

### Cloud Realtime connection pool error

“云端实时服务连接池异常” means Guard observed `IncreaseConnectionPool` in the logs. This cloud capacity category suppresses local automatic restarts and schedules read-only rechecks with 10 / 20 / 40 / 80 / 120-second backoff.

Use the latest check result and timestamp to assess the current state. An old capacity warning or an online console entry cannot establish whether the command channel has recovered. Guard records the incident and rechecks, but cannot expand or repair the cloud connection pool. See [Realtime Error Codes](https://supabase.com/docs/guides/realtime/error_codes) and [Realtime Settings](https://supabase.com/docs/guides/realtime/settings).

### ChatGPT shows “Connection interrupted” or “Message delivery timed out”

Guard can observe some answer-resume, refresh-failure, and update-connection events in local logs. Those logs do not provide a dedicated final event for every timeout shown on screen. Guard may miss the warning you saw and cannot reliably establish that the original answer fully recovered.

An update connection reopening establishes only that connection's recovery; a resume-completed event applies to its corresponding recovery path. Guard cannot control or resume the original ChatGPT answer stream, resend messages, restart ChatGPT, or switch networks. See [CHAT-LIVENESS-REVIEW.md](CHAT-LIVENESS-REVIEW.md) for the technical review in Chinese.

## When automatic recovery runs

Guard starts evaluating recovery after automatic probes accumulate three explicit “device has no live connection” results. Unknown results between them do not clear that evidence; a confirmed healthy `ping` does.

Enabling this toggle permits Guard to restart the managed local Commander service. Turning it off keeps observation and alerts running but prevents new automatic restarts; a restart already launched cannot be undone. The setting is saved. It does not unconditionally start a stopped service, repair the cloud, or sign you in again.

Before a restart, automatic recovery must be enabled and all of the following must be established:

- Local calls have ended, with complete, readable log coverage.
- The Commander process tree matches the expected layout and has no extra child processes.
- The cloud has no pending or running calls.
- The five-minute cooldown since the previous recovery attempt has elapsed.

Timeouts, expired authentication, unrecognized responses, failed tool probes, and cloud capacity errors do not individually trigger a restart. Guard reports recovery success only after the service PID changes and the new service responds to `ping`. That result does not establish that the original business task continued or finished.

These checks cannot cover every independently running background task. Turn off automatic recovery when you need manual control of the service.

### Prevent idle sleep

With “防止闲置睡眠（Guard）” enabled, Guard requests that macOS prevent idle system sleep only while it identifies the Commander service as running. The panel distinguishes an active request, waiting for the service, and an unsuccessful request. Disabling it releases only Guard's own request; other apps, including Commander's own sleep-prevention process, can still keep the Mac awake. The display may turn off, and manual sleep, restart, or other forced sleep is not prevented. This preference survives Guard relaunches and is independent of automatic recovery.

## Data and privacy

Guard reads existing credentials and logs without writing or refreshing Commander credentials. Device registration, pending-call checks, and fixed probes use the existing authorization; usage sync separately uses the official page in Chrome.

Activity records include redacted command summaries, paths, times, and states. Common credentials and inline scripts are hidden, but custom secret formats may not be recognized. Avoid putting sensitive values directly in commands and review records before sharing them.

Guard does not read chat bodies. Probe and tool result bodies, raw error responses, login tokens, raw session identifiers, and usage-account cookies, passwords, tokens, email addresses, or raw responses are not written to its state or decision logs.

<details>
<summary>Local data files and session attribution</summary>

State files live in `~/Library/Application Support/CommanderGuard/`:

| File | Contents |
|---|---|
| `status.json` | Service, channel, tool execution, call state, and optional usage summary |
| `timeline.jsonl` | Redacted events, capped at 1 MiB with one rotated copy |
| `channel-incident.json` | Current and recent channel categories, timestamps, backoff, and recovery state |
| `channel-decisions.jsonl` | Probe and recovery decisions, capped at 512 KiB with one rotated copy |
| `channel-recovery.json` | Recovery toggle and last attempt time, without credentials |

Session attribution accepts only upstream `_meta["openai/session"]` or `origin_context_id`. Raw identifiers are SHA-256 hashed into short anonymous fingerprints. Missing fields produce no attribution label; conflicting fields still show “归属冲突” (attribution conflict). Timing, the foreground chat, terminal processes, and `origin_instance` are not attribution evidence.

The current pairing path still lacks stable session metadata forwarding, so real calls may remain unattributed. Guard shows the tool and operation without repeatedly adding an unconfirmed-attribution label. Follow [Remote Desktop Commander #12](https://github.com/desktop-commander/remote-desktop-commander/issues/12) and [CHAT-COMMANDER-ATTRIBUTION-REVIEW.md](CHAT-COMMANDER-ATTRIBUTION-REVIEW.md).

Guard also reads `~/.claude-server-commander/tool-history.jsonl`, extracting only tool names, actual timestamps, duration, and return state. Argument and result bodies are discarded. That format lacks reliable call IDs, so Guard does not merge it with other records by timing or use it alone to establish that the device is idle.

Missing times and durations in reconstructed history are marked unknown. A returned local call does not establish that the cloud received the result or that the whole ChatGPT task completed.

</details>

## Manual checks and development

Run these commands in the project directory. Both probes use the real cloud connection without starting Guard's automatic recovery. `--probe-tool` sends a read-only tool call.

```bash
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --probe-channel
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --probe-tool
```

The offline self-test does not start the guard or operate the Commander service:

```bash
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --self-test
```

UI previews use fixed sample data. They do not start monitoring, recovery, or usage requests, and do not write state:

```bash
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --preview-ui
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --preview-ui --verify-ui
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --preview-ui --preview-dark --verify-ui
```

The app uses native AppKit. Its icons are `Assets/AppIcon.png` and `Assets/AppIcon.icns`, with a monochrome shield and link symbol in the menu bar. UI structure draws on [Little Snitch](https://help.obdev.at/littlesnitch6/lsm-overview) and [Stats](https://github.com/exelban/stats).

## Uninstall

For an installation made with the installer, run this from the project directory:

```bash
./uninstall.sh
```

It removes the Guard app, desktop shortcut, and login LaunchAgent, preserving project source, state, and logs. If you only run `build/CommanderGuard.app`, quit it and delete the build output.

## Project documentation

- [TODO.md](TODO.md): priorities and acceptance criteria. Unfinished items are not current capabilities.
- [CHAT-COMMANDER-ATTRIBUTION-REVIEW.md](CHAT-COMMANDER-ATTRIBUTION-REVIEW.md): session attribution and upstream metadata gaps.
- [CHAT-LIVENESS-REVIEW.md](CHAT-LIVENESS-REVIEW.md): ChatGPT answer streams and connection keepalive review.
- [DIAGNOSIS.md](DIAGNOSIS.md): historical timeout diagnosis.
- [RESEARCH.md](RESEARCH.md): long-running tasks, timeouts, and public approaches.

These detailed documents are currently mostly in Chinese. When reporting a problem, include your macOS and Commander versions, launch method, incident time, and redacted panel state. Do not submit credentials or complete private logs.

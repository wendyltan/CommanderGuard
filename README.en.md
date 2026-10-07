<p align="center">
  <img src="Assets/AppIcon.png" width="112" alt="CommanderGuard icon">
</p>

<h1 align="center">CommanderGuard</h1>

<p align="center">A macOS menu bar app for checking Desktop Commander connections, viewing local tool activity, and attempting recovery when safety checks permit.</p>

<p align="center"><a href="README.md">中文</a> · English</p>

Your device shows as online, but remote tools fail to run. CommanderGuard observes the message channel and local tool execution separately. Active cloud probes are OFF by default to avoid continuously sending potentially metered tool requests while idle. It also observes some ChatGPT App connection events and can show your Desktop Commander cloud tool calls usage.

This project is for macOS users who already use [Remote Desktop Commander](https://github.com/desktop-commander/remote-desktop-commander). The app UI is currently in Chinese. Automatic recovery depends on a specific local service and log layout; check the compatibility requirements below before installing.

## What it does

| Feature | What you can see or do |
|---|---|
| Live status | Menu bar icon and text show channel status; the panel tracks the message channel, tool execution, and ChatGPT answer state separately |
| Optional active probes | OFF by default; device `ping` and safe, read-only `list_sessions` share a persistent limit of 6 attempts per rolling 24 hours |
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

“云端主动探测（可能消耗额度）” (active cloud probes, may use quota) defaults to OFF, including upgrades. The automatic-recovery permission defaults to ON for a new configuration, but recovery is paused while active probes are OFF. The panel shows the reason. Preventing idle sleep is independent and does not require probes.

### 3. Decide whether to enable active probes

By default, Guard observes local logs, real calls and device registration without sending MCP tool probes. To test device responsiveness, enable active probes and click “手动 ping（1次）” (one manual ping). The button sends one request. A device ping does not prove local tool execution works.

Automatic, manual, command-line and post-recovery probes share **6 total attempts per rolling 24 hours**. Failed or timed-out requests count too. Relaunching Guard or toggling the setting does not reset the stored budget. Routine ping and tool checks each have a minimum ten-minute interval; incident backoff still obeys the shared cap. Usage-account reads do not consume this probe budget.

OFF blocks new `tools/call` requests and pauses automatic recovery. Submitted requests cannot be recalled. An exhausted budget, corrupt ledger, backwards clock or failed safe write also blocks probes. Logs, device-registration reads, ChatGPT observation, usage sync and idle-sleep prevention continue. An unconfirmed state is not evidence of health or idleness.

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
| 概览 (Overview) | The status needing attention, local task activity, usage, main toggles, probe budget, and the one-ping button |
| 操作记录 (Activity) | Hides `ping` checks by default; search commands, tools, paths, or known sessions, and select a row for its tool name, details, time and duration; choose “全部（含连接检查）” to include checks |
| 故障与恢复 (Incidents and recovery) | Recent incidents, probes, recovery times and results, without repeating Overview status cards or controls |

The menu bar keeps updating. The internal marker `●` means the message channel recently responded, `!` means the service is not running or the channel explicitly failed, and `?` means the result is unconfirmed, stale, or lacks evidence.

### Connect cloud usage

This shows Desktop Commander cloud tool calls usage, separate from your ChatGPT subscription limits. It is optional and requires Google Chrome to be installed.

1. Click “连接额度账户” (connect usage account) in Overview and sign in on the official site in Guard's dedicated browser window. Google sign-in is supported.
2. After signing in, return to Guard and click “完成登录并同步” (finish sign-in and sync), which closes only the dedicated browser process Guard launched and reads usage in the background. You may also close the window and click Refresh. Everyday Chrome is unaffected. Guard will not force-close an unowned browser holding the profile.
3. Choose manual only or 1, 2, 5, 10, 30, or 60 minutes under “后台自动同步” (background sync). The default is five minutes. The choice survives Guard relaunches; changing it does not immediately send a request.

Automatic reads use Chrome Headless, without visible windows or changes to your everyday browser tabs or foreground app. Only clicking the sign-in button opens a dedicated login window. A failed automatic read never opens a login window on its own.

The dedicated browser has its own sign-in profile. It cannot reuse your everyday Chrome Google session, so upgrading requires signing in once in the dedicated window. Guard does not copy cookies or account data from your everyday browser. Chrome retains authentication in its dedicated profile; Guard receives only validated usage numbers, plan, and month.

“暂停同步” (pause sync) stops future requests and cancels an active usage read without signing out. Unlimited Pro plans have no finite progress bar. Temporary failures retain the last successful values and actual sync time. The stale threshold follows the selected interval, with a minimum of fifteen minutes. Expired authentication requires signing in again.

The usage endpoint is the read-only interface currently used by the official website, rather than a guaranteed public API. Website changes may break syncing. See the [official Chrome Headless guide](https://developer.chrome.com/docs/automation-and-testing/headless) for its window-free mode.

## Troubleshooting

### The console says online, but tools fail

An online console entry generally reflects registration or a heartbeat. Inspect local errors and recent real calls first. If needed, enable active probes and send one manual ping within the budget. The device answers `ping` directly, without running a local tool.

Tool execution prefers a recent, explicitly successful real call. Once that evidence is older than 120 seconds, Guard sends read-only `list_sessions` only if active probes are enabled, budget remains, the channel recently responded, logs are complete and the device is confirmed idle. Probe response bodies are discarded. A failed tool probe does not itself trigger a restart.

### Guard cannot safely confirm that the device is idle

The message “本机日志覆盖有缺口，无法安全确认空闲” means Guard cannot see the complete call history. Logs may have rotated, been truncated or lost, failed to read, or not yet been fully read. Recovery is deferred because a task may still be running. The warning alone establishes neither a disconnect nor task completion.

### Cloud Realtime connection pool error

“云端实时服务连接池异常” means Guard observed `IncreaseConnectionPool` in the logs. This cloud capacity category suppresses local automatic restarts. When probes are enabled and budget remains, read-only rechecks use 10 / 20 / 40 / 80 / 120-second backoff. OFF or the shared six-attempt cap stops further probes.

Use the latest check result and timestamp to assess the current state. An old capacity warning or an online console entry cannot establish whether the command channel has recovered. Guard records the incident and rechecks, but cannot expand or repair the cloud connection pool. See [Realtime Error Codes](https://supabase.com/docs/guides/realtime/error_codes) and [Realtime Settings](https://supabase.com/docs/guides/realtime/settings).

### ChatGPT shows “Connection interrupted” or “Message delivery timed out”

Guard can observe some answer-resume, refresh-failure, and update-connection events in local logs. Those logs do not provide a dedicated final event for every timeout shown on screen. Guard may miss the warning you saw and cannot reliably establish that the original answer fully recovered.

An update connection reopening establishes only that connection's recovery; a resume-completed event applies to its corresponding recovery path. Guard cannot control or resume the original ChatGPT answer stream, resend messages, restart ChatGPT, or switch networks. See [CHAT-LIVENESS-REVIEW.md](CHAT-LIVENESS-REVIEW.md) for the technical review in Chinese.

## When automatic recovery runs

Both active probes and automatic recovery must be enabled, with probe budget remaining. Turning probes OFF preserves the saved recovery permission but pauses new recovery attempts; the panel explains why.

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

Guard reads existing credentials and logs without writing or refreshing Commander credentials. Device registration, pending-call checks, and fixed probes use the existing authorization; usage sync uses a dedicated Chrome profile and headless browser without controlling everyday Chrome windows.

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
| `active-probe-budget.json` | Probe permission and rolling request timestamps, without credentials; relaunches do not reset it |

Session attribution accepts only upstream `_meta["openai/session"]` or `origin_context_id`. Raw identifiers are SHA-256 hashed into short anonymous fingerprints. Missing fields produce no attribution label; conflicting fields still show “归属冲突” (attribution conflict). Timing, the foreground chat, terminal processes, and `origin_instance` are not attribution evidence.

The current pairing path still lacks stable session metadata forwarding, so real calls may remain unattributed. Guard shows the tool and operation without repeatedly adding an unconfirmed-attribution label. Follow [Remote Desktop Commander #12](https://github.com/desktop-commander/remote-desktop-commander/issues/12) and [CHAT-COMMANDER-ATTRIBUTION-REVIEW.md](CHAT-COMMANDER-ATTRIBUTION-REVIEW.md).

Guard also reads `~/.claude-server-commander/tool-history.jsonl`, extracting only tool names, actual timestamps, duration, and return state. Argument and result bodies are discarded. That format lacks reliable call IDs, so Guard does not merge it with other records by timing or use it alone to establish that the device is idle.

Missing times and durations in reconstructed history are marked unknown. A returned local call does not establish that the cloud received the result or that the whole ChatGPT task completed.

</details>

## Manual checks and development

Run these commands in the project directory. Both probes obey the same switch and shared limit; OFF means no cloud request. When enabled, they use the real connection and may consume quota, without starting automatic recovery. `--probe-tool` sends a read-only tool call.

```bash
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --probe-channel
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --probe-tool
```

Read the switch and budget without loading credentials or sending requests:

```bash
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --active-probe-status
```

The offline self-test does not start the guard or operate the Commander service:

```bash
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --self-test
```

The headless check starts Chrome twice with blank pages in a temporary profile and checks for leftover locks and changes to the foreground app. It does not access an account or verify real usage:

```bash
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --probe-headless
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
- [PROBE-QUOTA-REVIEW.md](PROBE-QUOTA-REVIEW.md): probe cadence, measured usage comparisons and alternatives; unproven billing assumptions are marked as such.
- [CHAT-COMMANDER-ATTRIBUTION-REVIEW.md](CHAT-COMMANDER-ATTRIBUTION-REVIEW.md): session attribution and upstream metadata gaps.
- [CHAT-LIVENESS-REVIEW.md](CHAT-LIVENESS-REVIEW.md): ChatGPT answer streams and connection keepalive review.
- [DIAGNOSIS.md](DIAGNOSIS.md): historical timeout diagnosis.
- [RESEARCH.md](RESEARCH.md): long-running tasks, timeouts, and public approaches.

These detailed documents are currently mostly in Chinese. When reporting a problem, include your macOS and Commander versions, launch method, incident time, and redacted panel state. Do not submit credentials or complete private logs.

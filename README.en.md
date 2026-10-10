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
| Optional active probes | OFF by default; choose a device `ping` every 5, 10, 15, or 30 minutes, or 1, 2, 3, or 6 hours; all entry points share that interval |
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

Choose **5, 10, 15, or 30 minutes, or 1, 2, 3, or 6 hours** under “探测频率” (probe interval). The default is 1 hour. Use 15 minutes for regular active checks, 1 hour for light ongoing observation, and 5 minutes for temporary diagnosis. Automatic, manual, command-line and post-recovery probes all wait the selected interval since the last submitted request. Failed and timed-out requests also start that wait; they do not trigger rapid retries. Relaunches, toggles and interval changes retain the last request time. Changing the interval does not itself submit a request.

This replaces the fixed six-attempt daily cap. Continuous probing at one fixed interval permits about 288, 144, 96, 48, 24, 12, 8, or 4 requests per day; the panel shows this estimate and the next allowed time. The estimate is not a count of actual calls in the previous 24 hours. Desktop Commander has not published a device-ping billing exemption. Earlier comparisons observed no usage increase during those specific windows. Usage-account reads are separate from MCP tool probes and do not consume this interval.

OFF blocks new `tools/call` requests and pauses automatic recovery. Submitted requests cannot be recalled. A corrupt ledger, backwards clock or failed safe write also blocks probes. Logs, device-registration reads, ChatGPT observation, usage sync and idle-sleep prevention continue. An unconfirmed state is not evidence of health or idleness.

### Optional: use the existing installer

**`install.sh` currently depends on `/Volumes/ExtSSD/Projects/CommanderGuard` and requires `/Volumes/ExtSSD/Projects` to exist. If you use a different directory layout, use the source build above first.**

Once your setup matches that layout, run:

```bash
./install.sh
```

The script builds the app, installs it to `~/Applications/CommanderGuard.app`, creates a desktop shortcut and login LaunchAgent, and restarts CommanderGuard. Before replacing the installed app, it sends TERM to CommanderGuard processes at that exact install path and waits up to 10 seconds; if one is still running, installation stops without overwriting the app. Preferences and the dedicated Chrome sign-in profile are preserved. Installation does not restart or modify Remote Desktop Commander. Once Guard starts, its recovery toggle and safety checks determine whether automatic recovery can run. The login LaunchAgent attempts to relaunch Guard after an unsuccessful exit; a normal quit does not trigger relaunch.

## Everyday use

The panel has three pages, a resizable window, and support for system light and dark appearance. A compact status strip and navigation remain visible across pages. Overview groups the current conclusion, guard controls, usage and local activity; important times include both the clock time and the age of the evidence.

| Page | What to look for |
|---|---|
| 概览 (Overview) | The status needing attention, local task activity, usage, main toggles, probe interval, next allowed time, and the one-ping button |
| 操作记录 (Activity) | Columns show time, action, result, duration and session. `ping` is hidden by default; older records with unknown times can be expanded separately. Search and filters retain access to records, and selection shows sanitized details. Reliable session identifiers use stable accent colors |
| 故障与恢复 (Incidents and recovery) | A compact status strip, followed by chronological incidents, probes and recovery evidence, without repeating the guard controls |

The menu bar keeps updating a short status. The channel shows the last actual probe result and its time. “上次探测成功” (last probe succeeded) records past evidence; it does not guarantee a live connection now. The internal marker `●` means the message channel recently responded, `!` means the service is not running or the channel explicitly failed, and `?` means the result is unconfirmed, stale, or lacks evidence. Waiting for the next check is not a new failure.

A toggle records your permission; its adjacent status explains whether Guard can act now. Automatic recovery can be enabled yet paused because incomplete logs prevent Guard from proving the host is idle. No observed operation is different from confirmed idle. ChatGPT connection recovery is also shown separately from the completeness of the original answer.

### Connect cloud usage

This shows Desktop Commander cloud tool calls usage, separate from your ChatGPT subscription limits. It is optional and requires Google Chrome to be installed. Used and included totals come from the official account response. The progress bar shows the used share of the included total, so 100% means the period's included calls are used, not a fixed count of 100. UI previews use sample data.

1. Click “连接” (connect) in the Overview usage card. If the account is already connected but needs sign-in, the button says “登录” (sign in). Sign in on the official site in Guard's dedicated browser window; Google sign-in is supported.
2. While Guard's login window is open, the card button says “完成登录” (finish sign-in). Click it after signing in; Guard closes the login process it started and reads usage. You may also close the dedicated window and click “刷新” (refresh). At other times, this button reads usage. Guard does not edit everyday Chrome tabs or terminate its process. Guard will not force-close an unowned browser holding the dedicated profile.
3. Under “自动同步” (automatic sync), choose “手动” (manual) or 1, 2, 5, 10, 30, or 60 minutes. The default is five minutes. The choice survives Guard relaunches; changing it does not immediately send a request. Click “暂停” (pause) to stop future syncs and cancel an active usage read.

Automatic syncing reuses one Guard-owned headless Chrome session and parks it on about:blank between reads. The process stays running and uses some memory. Switching to manual mode closes an idle session; an active read finishes before the session closes. In manual mode, each refresh also closes Chrome after the read. Pausing, signing in, quitting Guard, or a failed read releases the session. macOS may add a Chrome recent-app entry on first launch; Guard does not clear existing entries or change global Dock settings. Only clicking Sign in opens the dedicated login window; automatic sync failures do not open one.

The dedicated browser has its own sign-in profile. It cannot reuse your everyday Chrome Google session, so the first connection needs a separate sign-in; subsequent upgrades retain that profile. Guard does not copy cookies or account data from your everyday browser. Chrome retains authentication in its dedicated profile; Guard receives only validated usage numbers, plan, and month.

“暂停” (pause) stops future requests and cancels an active usage read without signing out. Unlimited Pro plans have no finite progress bar. Temporary failures retain the last successful values and actual sync time. The stale threshold follows the selected interval, with a minimum of fifteen minutes. Expired authentication requires signing in again.

The usage endpoint is the read-only interface currently used by the official website, rather than a guaranteed public API. Website changes may break syncing. See the [official Chrome Headless guide](https://developer.chrome.com/docs/automation-and-testing/headless) for its window-free mode.

## Troubleshooting

### The console says online, but tools fail

An online console entry generally reflects registration or a heartbeat. Inspect local errors and recent real calls first. If needed, enable active probes and send one manual ping within the selected interval. The device answers `ping` directly, without running a local tool.

Tool execution uses recent, explicitly successful real calls. Evidence older than 120 seconds is marked stale. Guard no longer sends automatic `list_sessions` calls to refresh that evidence. For a deliberate tool-execution check, use the `--probe-tool` diagnostic below. It obeys the same switch and interval, may consume quota, and discards the response body. A failed tool probe does not itself trigger a restart.

### Guard cannot safely confirm that the device is idle

The message “本机日志覆盖有缺口，无法安全确认空闲” means Guard cannot see the complete call history. Logs may have rotated, been truncated or lost, failed to read, or not yet been fully read. Recovery is deferred because a task may still be running. The warning alone establishes neither a disconnect nor task completion.

### Cloud Realtime connection pool error

“云端实时服务连接池异常” means Guard observed `IncreaseConnectionPool` in the logs. This cloud capacity category suppresses local automatic restarts. Rechecks obey the selected probe interval; incident backoff cannot bypass it. Turning active probes OFF pauses rechecks.

Use the latest check result and timestamp to assess the current state. An old capacity warning or an online console entry cannot establish whether the command channel has recovered. Guard records the incident and rechecks, but cannot expand or repair the cloud connection pool. See [Realtime Error Codes](https://supabase.com/docs/guides/realtime/error_codes) and [Realtime Settings](https://supabase.com/docs/guides/realtime/settings).

### ChatGPT shows “Connection interrupted” or “Message delivery timed out”

Guard can observe some answer-resume, refresh-failure, and update-connection events in local logs. Those logs do not provide a dedicated final event for every timeout shown on screen. Guard may miss the warning you saw and cannot reliably establish that the original answer fully recovered.

An update connection reopening establishes only that connection's recovery; a resume-completed event applies to its corresponding recovery path. Guard cannot control or resume the original ChatGPT answer stream, resend messages, restart ChatGPT, or switch networks. See [CHAT-LIVENESS-REVIEW.md](CHAT-LIVENESS-REVIEW.md) for the technical review in Chinese.

## When automatic recovery runs

Both active probes and automatic recovery must be enabled, and the probe ledger must be readable and safely writable. Turning probes OFF preserves the saved recovery permission but pauses new recovery attempts; the panel explains why.

Guard starts evaluating recovery after automatic probes accumulate three explicit “device has no live connection” results. Longer intervals delay this decision: three confirmations at a three-hour interval span several hours. Probes check the channel at that moment; Commander still handles its own heartbeat and reconnection. Unknown results between them do not clear that evidence; a confirmed healthy `ping` does.

Enabling this toggle permits Guard to restart the managed local Commander service. Turning it off keeps observation and alerts running but prevents new automatic restarts; a restart already launched cannot be undone. The setting is saved. It does not unconditionally start a stopped service, repair the cloud, or sign you in again.

Before a restart, automatic recovery must be enabled and all of the following must be established:

- Local calls have ended, with complete, readable log coverage.
- The Commander process tree matches the expected layout and has no extra child processes.
- The cloud has no pending or running calls.
- The five-minute cooldown since the previous recovery attempt has elapsed.

Timeouts, expired authentication, unrecognized responses, failed tool probes, and cloud capacity errors do not individually trigger a restart. Post-restart verification also waits for the selected probe interval. Until then, recovery remains unconfirmed. Guard reports success only after the service PID changes and that new service responds to `ping`. That result does not establish that the original business task continued or finished.

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
| `active-probe-budget.json` | Probe permission, interval and last request time, without credentials; relaunches do not reset it; upgrading an old ledger switches probing OFF |

Session attribution accepts only upstream `_meta["openai/session"]` or `origin_context_id`. Raw identifiers are SHA-256 hashed into short anonymous fingerprints. Missing fields produce no attribution label; conflicting fields still show “归属冲突” (attribution conflict). Timing, the foreground chat, terminal processes, and `origin_instance` are not attribution evidence.

The current pairing path still lacks stable session metadata forwarding, so real calls may remain unattributed. Guard shows the tool and operation without repeatedly adding an unconfirmed-attribution label. Follow [Remote Desktop Commander #12](https://github.com/desktop-commander/remote-desktop-commander/issues/12) and [CHAT-COMMANDER-ATTRIBUTION-REVIEW.md](CHAT-COMMANDER-ATTRIBUTION-REVIEW.md).

Guard also reads `~/.claude-server-commander/tool-history.jsonl`, extracting only tool names, actual timestamps, duration, and return state. Argument and result bodies are discarded. That format lacks reliable call IDs, so Guard does not merge it with other records by timing or use it alone to establish that the device is idle.

Missing times and durations in reconstructed history are marked unknown. A returned local call does not establish that the cloud received the result or that the whole ChatGPT task completed.

</details>

## Manual checks and development

Run these commands in the project directory. Both probes obey the same switch and shared interval; OFF means no cloud request. When enabled, they use the real connection and may consume quota, without starting automatic recovery. `--probe-tool` sends a read-only tool call.

```bash
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --probe-channel
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --probe-tool
```

Read the switch, interval and next allowed time without loading credentials or sending requests:

```bash
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --active-probe-status
```

The offline self-test does not start the guard or operate the Commander service:

```bash
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --self-test
```

The headless check starts one Chrome process, runs two checks against the same blank-page target in a temporary profile, and verifies that no lock remains after exit and the foreground app is unchanged. It does not access an account or usage service:

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

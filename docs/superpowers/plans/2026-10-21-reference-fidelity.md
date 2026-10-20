# Restore the approved reference composition

> Execution: subagent-driven development. User explicitly rejected f0f20e2 appearance and requires the first approved picture. Existing feature checkout, clean at start. Prior functional checks do not establish visual fidelity.

**Goal:** Reproduce the approved sidebar and compact reference composition in AppKit, preserving real data, controls and recovery safety.
**Authority:** The original guard-native-directions.html in this conversation visualization workspace, selected variant 侧栏主窗; both page templates and compact surface are binding. Preserve this file unchanged. Earlier DESIGN.md describes rejected output and is not authority for this rework.
**Files:** CommanderGuard.swift (UI/helpers/UI assertions); README.md/README.en.md, PRODUCT.md/DESIGN.md/TODO.md and this plan (root owns documentation).
**Architecture:** Keep Swift/AppKit and all monitoring, persistence, probe and recovery methods unchanged. Replace presentation composition; do not add WebKit, packages or backend behavior. Use native switches and buttons with reference-specific colors/geometry. No live probes or restart drills during QA.

## Binding appearance

- Paired exact palette, light/dark: surface #fff/#242526; rail #eef1f5/#2c3036; text #20252d/#edf0f5; secondary #626d7c/#aab4c3; line #e3e7ed/#40454d; tint #f6f8fb/#2b2e33; blue #1669d3/#81b5ff; selection #e4edfc/#34465f; green #26724c/#8bd4ae; amber #93621a/#e4bb75. Appearance switches update every surface.
- Window has integrated chrome: traffic lights over rail, no separate visible global title band; rail188, toolbar58 with bottom hairline; content26 horizontal/24 top/20 bottom. Default outer frame940×620 (matches approximately620px reference), minimum760×560. Generous row padding, no legacy gray log-sheet layout.
- Sidebar brand at approximately y62, 13pt/11pt text, blue shield. Navigation near top, 38px rows/4 gap/6 radius, selected blue tint AND blue icon/text, never native gray bezel. Settings at bottom above separated service footer. Service text uses actual state.
- Main overview starts with44×44 blue-tint shield emblem,19pt semibold concise headline and13pt supporting line. Active call headline 当前任务受到保护; unknown logs must remain uncertain. Long incident diagnosis belongs in evidence disclosure, not the giant first headline.
- 验证状态13pt semibold heading; ONE white/surface group,9 radius, hairline border. THREE rows about66px tall,13px vertical/15px horizontal padding. Three-column row:17px icon in26px slot, flexible left title13/subtitle11, right-aligned result12/time11. Status and time are stacked on the RIGHT; never old key/value/time inline followed by repeated full-width detail. Expanded 查看证据与限制 contains full existing evidence, diagnosis, safety and uncertainty wording.
- 本机活动: one task title/subtitle on left, 查看记录 button on right, bottom separator. No key/value inventory. Account is one modest inline row with plan/usage and blue 账户与同步设置 link; Pro never gets a progress bar. Finite quota can retain compact meaningful progress.
- Incidents:21pt page heading+short subtitle, timeline rows with52px time column and event title/secondary detail; detailed previous fields under disclosure. 本机恢复选项 tinted8-radius area with current impact guidance and the existing 人工授权重启本机服务… button. All previous evidence remains available; button discoverable without expanding advanced evidence.
- Settings:21pt title, group captions13, white rounded groups of65px rows, title13/subtitle11 on left, NSSwitch on right. Connection/recovery/wake are grouped, existing ping/frequency/extra guidance in clearly labeled expandable advanced options. Account and sync grouped. Preserve existing callbacks and menus.
- Records: reference table styling,3 visible columns(time/action/result), calm line separators and blue selection; duration/session remain in selected detail. Preserve filters, historical toggle, anonymous attribution, table/detail split scrolling and user divider. No giant gray alternating bands, clipping or tiny text.
- Compact360px: separate17×19 header and bottom border; content20;18pt concise headline +13pt supporting line; aligned status rows with11px vertical padding; tinted task panel full width, compact account row; separate bottom footer. Keep 恢复与重启… navigation and full-panel entry. No wall of long diagnostic text; full evidence in main window.

## Verification and finish

- [x] Implement all four pages and compact composition as one coherent batch. Extend meaningful UI checks for geometry, colors, selected state, real-data uncertainty and safe navigation; preserve backend self-tests.
- [x] Build and run complete self-test once after implementation; light/dark UI checks at940×620 and760×560; save logs/hash under build/reference-fidelity-20261021/.
- [x] Root compares actual images with original reference at SAME size and SAME fixed sample state (Pro unlimited,1 task). One batched inspection plus one correction/confirmation. A side-by-side image is required; passing layout tests alone is insufficient. Structural mismatches must be repaired before shipping.
- [x] Review code, update docs, inspect live state, install Guard only preserving prefs, verify installed code/runtime/Commander unchanged; scoped local commit/tag, no push/merge. User final visual acceptance remains separate.

## STATE / VERIFY / GIT / NEXT
STATE: Reference-fidelity rework installed and formal window opened for user inspection. All four pages and compact surface follow the approved composition. User final visual acceptance pending; heartbeat paused on delivery.
CAUSE: Earlier translation kept old controls and verbose stacks, losing the approved palette, spacing and hierarchy. This batch reproduces the actual composition and verifies screenshots instead of treating layout tests as visual approval.
VERIFY: Optimized build, complete offline self-test, light/dark default/minimum UI checks, signed-copy checks, scoped code review and diff/public-document checks PASS. Actual light/dark main, all four pages and compact inspected; comparison.png preserves equal-size/equal-sample original versus native. Final sidebar padding/footer/hairline confirmed. Installed signature, tested-code equality, fresh state, LaunchAgent and preserved preferences PASS; Commander instances unchanged. Real restart drill and full VoiceOver NOT RUN. Existing channel anomaly remains outside this UI task.
GIT: feature/authorized-recovery-20261019; scoped local commit and fix/reference-fidelity-20261021 tag identify this delivery. No push/merge.
NEXT: User judges the installed appearance against the saved original/actual comparison. No further autonomous implementation or recovery drill while awaiting that feedback.

## First visual comparison

The original reference was rendered locally without changing the approved source. reference-overview.png is940×623, shield/status header top83, verification group top184/height196, activity row top463/height68, account top549. Native first preview has the correct new topology but lacks24px top padding and CSS-like line leading; compact body is430px versus498px reference because intended margins are missing. Root supplied one consolidated correction batch; preserve first images as evidence, do not restart this task from scratch.

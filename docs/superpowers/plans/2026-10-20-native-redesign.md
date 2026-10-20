# Native compact overview and sidebar redesign

> Execution: subagent-driven development; scoped existing feature branch. User approved the exact new visual direction and implementation on 2026-10-20. Preserve existing checkout and safe recovery behavior.

**Goal:** Ship the approved native compact overview plus sidebar main window, including discoverable manual recovery.
**Architecture:** Keep AppKit and existing snapshot, actions, persistence, protection and recovery pipeline. The menu-bar click opens a compact NSPopover; its detail links open the sidebar window on the relevant page. Right-click can retain the native utility menu. Existing four pages become sidebar navigation. No dependencies or backend changes.
**Spec:** Approved preview: guard-native-directions.html in this conversation visualization workspace; user selected 紧凑速览. Local review evidence: build/ui-research-20261020/research.md.

## Constraints
- Compact approximately 360px wide; grouped aligned status rows, task summary, quota summary, footer recovery/full-window entry.
- Full window: approximately 188px sidebar; clear page toolbar; grouped rows, generous separation and system typography/colors; no global repeated evidence strip across pages.
- Manual recovery entry opens 故障与恢复; explicit 人工授权重启本机服务… retains existing impact, single-use confirmation, expiry and execution recheck. Never trigger recovery during QA.
- Preserve existing user settings, active tasks, records/history/filter/divider behavior. Preview uses fixed data, no network or formal state mutation.
- Check light/dark, default/minimum size, unknown/error/expired states, quota unlimited, records long details, compact open/refresh/navigation.

## Review Focus
Long status lines remain readable; partial evidence never claims full recovery; popover refresh must not reset main selection; compact recovery only navigates; right-click utility actions remain discoverable.

## Tasks
- [x] Implement native popover, sidebar and all four page compositions with UI regression assertions in CommanderGuard.swift. Build, self-test, isolated preview checks.
- [ ] Root: review actual screenshots against approved preview in one batched light/dark/default/minimum pass; one bounded correction pass.
- [x] Sync DESIGN.md, PRODUCT.md if needed, Chinese/English README and TODO. Review scoped diff and safety callbacks.
- [x] Inspect runtime, preserve prefs, install Guard only, verify binary/signature/runtime/Commander unchanged; scoped local commit and semantic tag.

## STATE / VERIFY / GIT / NEXT
STATE: Implementation and installed/runtime verification complete. Actual compact content and sidebar window visually checked. Manual recovery entry located in installed Faults page, no restart executed. Only user visual acceptance remains.
VERIFY: Build, complete offline self-test, light/dark UI assertions at 940x720 and actual760x560 PASS. Exact installed/release hashes and unsigned tested-code comparison PASS; signature, fresh status, LaunchAgent, retained preferences and unchanged Commander instances PASS. Fresh scoped code re-review clean. Real disruptive recovery NOT RUN; full VoiceOver NOT RUN. Existing live channel anomaly remains outside UI scope; no provider-recovery claim. Logs/hashes/screenshots: build/ui-redesign-20261020/.
GIT: Scoped local commit and feature/native-redesign-20261021 tag close this batch. No push or merge.
NEXT: User reviews the installed visual result; do not repeat implementation or perform recovery without authorization.
AUTOMATION: Pause commanderguard-2 at delivery because only human acceptance remains.

## Quota checkpoint — 2026-10-20T21:08

Five-hour usage97%; reset epoch1792517072 (verify local rendering before reporting). Heartbeat commanderguard-2 remains ACTIVE hourly in this conversation. Never use reset credits. Implementation agent native_redesign is finishing first geometry correction (NSStack distribution.fill + main width constraints). Source modifications remain uncommitted, and no new-design install has occurred. Root README/PRODUCT/TODO drafts saved. DESIGN.md still describes previous iteration; rewrite from verified new result at finish. Preview bundle build/CommanderGuardPreview.app, distinct ID com.wuwendi.commander-guard.preview, always launch with --preview-ui to avoid formal state access; --preview-popover shows compact surface. CUA binding failed timeoutReached; actual screenshot QA not yet performed. Root backup and sanitized preference/process baseline in build/ui-redesign-20261020/installed-before.app and before.json. Commander PIDs5031/5037 at baseline; refresh before install. Root must inspect final diff, complete review and screenshot QA, then Guard-only install and local commit/tag, no push.

## Resume checkpoint — 2026-10-21

Quota recovered; no reset credit used. No new-design install/commit yet. Fresh review found static service footer, missing compact recovery reason, appearance update and AX selected-state issues; implementer is fixing these. Startup hang resolved: NSLayoutConstraint activated before common ancestor; exact scroll activation order fixed. Root actual screenshots in build/ui-redesign-20261020/*-first.png proved missing content padding and narrow sidebar highlight; current correction batch addresses these, grouped evidence, record area height and preview reopen behavior. Do not repeat the first screenshot batch; inspect corrected result next. Root visual-preview app is a separate test-only copy; terminate only its exact path when refreshing.

## Final verification note

The initial install-verification helper accidentally matched its own shell command text as an extra Guard process. Rechecking exact executable argv fixed that harness error; one installed Guard instance is confirmed, binary/code and config checks passed. Compact visual proof uses the same content in a preview-only window because the UI tool cannot inspect transient NSPopover windows; normal layout verification exercises the real popover.

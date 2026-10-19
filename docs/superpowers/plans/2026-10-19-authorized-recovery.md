# Authorized recovery implementation plan

Goal: Deliver the approved offline classification, one-use manual restart consent, and layered recovery evidence in the existing native app.
Architecture: Reuse the fixed managed-service executor and native panel. Keep automatic policy strict, separate ephemeral manual consent and optional cloud verification, persist sanitized evidence rather than replayable authority.
Spec: docs/authorized-recovery-design.md

## Constraints

No dependencies, no command replay, no automatic child-service restart, no real restart during offline/UI tests. Preserve user settings, shared probe interval, current deployment and unrelated files. Both public READMEs must match final code and contain no private machine identifiers.

## Tasks and checks

- [x] Baseline: inspect source/runtime/Git; isolated feature worktree; optimized build and offline self-test PASS.
- [x] Add failing self-checks for observed offline response and strict device/error boundaries; implement minimal classifier change; run checks.
- [x] Add failing checks for one-use consent, service/impact identity, expiry, cancellation, concurrency and persistence; implement impact summary and native authorization; reuse fixed restart executor.
- [x] Add failing checks for recovery source, process/channel/tool evidence, deferred one-shot cloud verification and restart-free reload; implement bounded persisted record and panel status.
- [x] Run optimized build, full self-test, native light/dark and minimum-size UI assertions; inspect screenshots and correct concrete issues.
- [x] Independent final review of safety and scope; fix material findings and repeat relevant checks.
- [x] Update both READMEs, project AGENTS and TODO; check public documentation for sensitive literals and broken references.
- [x] Install Guard only, verify installed binary/settings/runtime; open formal panel for human inspection; make scoped local commit/tag, no push/merge.

## Review focus

Wrong-device errors must not cause restart. Authorization must not survive process reuse or changed impact. A saved recovery record is evidence, never permission. False healthy/progress reports must not hide unverified tool/business state. Manual verification must not bypass interval or silently enable recurring paid calls.

Verification: optimized build, complete offline self-test, isolated native light/dark UI checks at both sizes, independent read-only review, documentation privacy/link checks, signature and installed-binary equality all PASS. Actual installed impact dialog and cancellation verified without executing restart. Original Commander instance and preferences preserved. Live restart workflow NOT RUN; human acceptance pending. Feature branch is retained locally without push/merge.

# CommanderGuard recovery repair

Goal: prevent stale cloud-capacity evidence and external service restarts from permanently disabling recovery.

Scope: CommanderGuard.swift incident state, recovery decisions and activity process-epoch reconciliation; existing inline self-tests; README.md and README.en.md. Preserve probe budget, cooldown, process-tree checks, outstanding-call checks and activity safety.

1. Add failing regression assertions for expired capacity evidence, fresh evidence renewal, persisted legacy incidents and verified external PID changes.
2. Track last capacity event separately from generic disconnects; expire only the restart suppression after a bounded quiet window, retain fault history, update all decision/display callers.
3. Detect managed service PID changes with old-process exit proof; rebuild activity epoch safely, without clearing uncertain tasks merely because the log is quiet.
4. Build and run offline self-tests, review diff and failure cases. Update bilingual behavior documentation.
5. Install verified Guard preserving settings, verify runtime/hash/service state, then commit this scoped change locally. No push or deliberate Commander restart.

Validation: latest build/signature, offline self-test, diff check and independent review passed. Installed Guard matches build; probe/recovery settings preserved. Runtime replay has idle_proven=true, coverage_gap=false, backlog_bytes=0. Commander PID remains 90012. No deliberate live failure injection was performed.

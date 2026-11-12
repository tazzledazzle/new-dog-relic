---
status: partial
phase: 01-infrastructure-substrate
source: [01-VERIFICATION.md]
started: 2026-11-12T00:00:00Z
updated: 2026-11-12T00:00:00Z
---

## Current Test

[awaiting human testing]

## Tests

### 1. Phase 1 Full Smoke Suite Live Execution
expected: `bash scripts/smoke/phase1-full.sh` exits 0, prints all 5 ROADMAP success criteria satisfied, ELAPSED < 300s
result: [pending]

### 2. Object Lock WORM Behavior (ROADMAP SC #5)
expected: `bash scripts/smoke/audit-isolation.sh` — message lands in ndr-audit bucket with ObjectLockMode: GOVERNANCE; `aws s3 rm` fails (exit non-zero)
result: [pending]

### 3. IOx Write-Read Round-Trip (ROADMAP SC #3)
expected: `bash scripts/smoke/iox-roundtrip.sh` exits 0 with "OK: IOx 3-signal roundtrip verified"
result: [pending]

### 4. ADR 0001 Retention Probe
expected: `/tmp/iox-retention-probe.json` contains 3 probe results documenting actual 72h OSS boundary behavior
result: [pending]

## Summary

total: 4
passed: 0
issues: 0
pending: 4
skipped: 0
blocked: 0

## Gaps

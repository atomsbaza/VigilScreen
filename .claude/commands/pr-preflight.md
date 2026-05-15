---
description: Run tests, check for warnings, and summarize changes before opening a PR
---

Run pre-PR checks for Vigil Screen. Be terse — one line per result. Surface failures with enough detail to act on immediately.

## Step 1 — Xcode toolchain check

```bash
xcode-select -p
```

If output is `/Library/Developer/CommandLineTools` (not Xcode), tell the user to run:
```
! sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```
and wait before continuing.

## Step 2 — Version consistency

```bash
grep -m1 'MARKETING_VERSION' VigilScreen.xcodeproj/project.pbxproj
git log --oneline -5
```

Check that the latest `chore: bump version` commit matches `MARKETING_VERSION`. Report any mismatch — don't block on it, just warn.

## Step 3 — Build (warnings check)

```bash
xcodebuild -scheme VigilScreen -configuration Debug build 2>&1 | grep -E 'warning:|error:' | grep -v '^$'
```

Report:
- `✅ Build clean` if zero warnings/errors
- `⚠️ {n} warning(s)` — list them grouped by file
- `❌ Build failed` — show errors and stop (skip tests)

## Step 4 — Test suite

```bash
xcodebuild -scheme VigilScreenTests -destination 'platform=macOS' test 2>&1 | grep -E 'Test Suite|passed|failed|error:'
```

Report:
- `✅ {n} tests passed`
- `❌ {n} tests failed` — list failing test names

## Step 5 — Diff summary vs main

```bash
git log main..HEAD --oneline
git diff main...HEAD --stat
```

Show:
- Commits ahead of `main`
- Files changed + lines added/removed

## Step 6 — Final report

Print a summary block:

```
── PR Preflight ──────────────────────────
  Toolchain  ✅ Xcode {version}
  Version    ✅ {marketing_version} (build {build})  |  ⚠️ mismatch: ...
  Build      ✅ clean  |  ⚠️ {n} warnings  |  ❌ failed
  Tests      ✅ {n} passed  |  ❌ {n} failed
  Changes    {n} commit(s) ahead of main · +{added}/−{removed} lines
─────────────────────────────────────────
```

If any check is ❌, end with: `Fix the above before opening a PR.`
If all ✅ (warnings are acceptable), end with: `Good to open a PR.`

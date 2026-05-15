---
description: Bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in the Xcode project and commit
---

Bump the Vigil Screen version in `VigilScreen.xcodeproj/project.pbxproj` and create a standard bump commit.

## Inputs

- **New version** — from `$ARGUMENTS` (e.g. `0.3.5`). If empty, read the current version and ask the user what the new version should be.

## Step 1 — Read current versions

```bash
grep -E 'MARKETING_VERSION|CURRENT_PROJECT_VERSION' VigilScreen.xcodeproj/project.pbxproj | sort -u
```

Show the user current values. Confirm the new `MARKETING_VERSION` from `$ARGUMENTS` or ask if not provided. New `CURRENT_PROJECT_VERSION` = current value + 1.

## Step 2 — Check working tree

```bash
git status --short
```

If there are staged or unstaged changes to tracked files, stop and ask the user to commit or stash them first. Untracked files are fine.

## Step 3 — Update pbxproj

Use the Edit tool to replace both occurrences of each field in `VigilScreen.xcodeproj/project.pbxproj`:

- `MARKETING_VERSION = {old};` → `MARKETING_VERSION = {new};`
- `CURRENT_PROJECT_VERSION = {old};` → `CURRENT_PROJECT_VERSION = {new_build};`

Use `replace_all: true` — there are typically two occurrences of each (Debug + Release build configs).

## Step 4 — Verify

```bash
grep -E 'MARKETING_VERSION|CURRENT_PROJECT_VERSION' VigilScreen.xcodeproj/project.pbxproj | sort -u
```

Confirm both fields show the new values before committing.

## Step 5 — Commit

```bash
git add VigilScreen.xcodeproj/project.pbxproj
git commit -m "chore: bump version to {new_version}"
```

## Output

```
✅ Bumped {old_version} → {new_version} (build {old_build} → {new_build})
   Commit: {hash}
   Ready to run /release {new_version} after merging to main.
```

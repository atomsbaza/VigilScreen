---
description: Notarize, package, upload, and update Homebrew cask for a new Vigil Screen release
---

You are the **Vigil Screen release orchestrator**. You coordinate two sub-agents (`release-preflight` and `release-publish`) and handle the two human pause points. Be terse — one line per step result.

## Constants

- **Repo:** `atomsbaza/VigilScreen`
- **Cask repo:** `atomsbaza/homebrew-tap`
- **Bundle ID:** `com.pisit.koolplukpol.VigilScreen`
- **Team ID:** `VPTPA7XM79`
- **Default export path:** `~/Desktop/VigilScreen-export/`

## Step 1 — Pre-flight (run automatically)

```bash
git status --short
git log -1 --format='%h %s'
grep -m1 'MARKETING_VERSION' VigilScreen.xcodeproj/project.pbxproj
gh auth status
```

- If `git status --short` shows any tracked changes → stop, report, ask user to commit or stash
- Untracked-only files are fine
- Read `MARKETING_VERSION` from `project.pbxproj`. If `$ARGUMENTS` was provided, confirm it matches. If they differ, ask the user which version to use.
- If `gh auth status` fails → stop, tell user to run `gh auth login`
- Check tag absent: `gh release view "v${VERSION}" --repo atomsbaza/VigilScreen 2>&1` — if release already exists, stop and report

Show result:
```
✅ Pre-flight passed — shipping v{version} from commit {hash}
```

## Step 2 — Xcode export (USER STEP)

Tell the user:

> Xcode export needed. Please:
> 1. Open `VigilScreen.xcodeproj` in Xcode
> 2. **Product → Archive**
> 3. Organizer → **Distribute App → Direct Distribution → Distribute** (≈1–10 min)
> 4. **Export App…** → save to `~/Desktop/VigilScreen-export/`
>
> Reply with "done" (or a custom export path) when finished.

Wait for the user's reply. Extract export path from their message if they provide one, otherwise use the default.

## Step 3 — Spawn release-preflight

Spawn the `release-preflight` sub-agent with:
- `version` = the confirmed version
- `export_path` = path from step 2

Wait for it to complete. If it fails, stop and surface the error. Do not continue to publish.

On success, read `/tmp/vigil-release-state.json` and show:
```
✅ DMG ready — {size} — SHA256: {sha256}
```

## Step 4 — Publish confirmation (USER STEP)

Ask:
> Ready to publish **v{version}** to GitHub and Homebrew. This will:
> - Create a public GitHub release at `https://github.com/atomsbaza/VigilScreen/releases/tag/v{version}`
> - Upload `VigilScreen-{version}.dmg` ({size})
> - Push a cask update to `atomsbaza/homebrew-tap`
>
> Proceed?

Wait for explicit confirmation. If the user says no, stop cleanly.

## Step 5 — Spawn release-publish

Spawn the `release-publish` sub-agent. It will run automatically through GitHub release creation, then pause again before pushing the cask — that's the sub-agent's own confirmation gate, handled internally.

Wait for it to complete and surface its final summary to the user.

## Output style

- One line per step result: `✅ done` / `❌ failed — {reason}` / `⏸ waiting on user`
- No narration of commands being run
- Surface errors verbatim so the user can act on them

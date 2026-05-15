# Release Agents Design

**Date:** 2026-05-15
**Status:** Approved

## Goal

Replace the manual `/release` skill with a semi-autonomous orchestrator + two sub-agents that handle the full Vigil Screen release flow. The human pauses only for: (1) Xcode export/notarization, (2) final publish confirmation.

## Architecture

```
.claude/skills/release/SKILL.md          ← orchestrator (replaces current /release skill)
.agents/release-preflight/AGENT.md       ← packaging agent
.agents/release-publish/AGENT.md         ← publishing agent
```

### Flow

```
/release 0.3.4
    │
    ├─ Orchestrator: pre-flight checks (git clean, version match, gh auth, tag absent)
    │
    ⏸  PAUSE → instruct user to archive + export in Xcode Organizer
    │
    ├─ Spawn: release-preflight
    │     verify .app → strip xattrs → stapler/spctl/codesign → build DMG → SHA256
    │     writes: /tmp/vigil-release-state.json {version, dmg_path, sha256}
    │
    ⏸  PAUSE → show DMG size + SHA256, ask "publish?"
    │
    └─ Spawn: release-publish
          read state.json → gh release create → upload DMG →
          clone tap → edit cask → brew style → commit + push → verify assets
```

State is persisted to `/tmp/vigil-release-state.json` so either sub-agent can be re-run independently if something fails mid-way.

## Agent Details

### `release-preflight`

- **Runs:** fully automatically, no prompts
- **Inputs:** `export_path` (default `~/Desktop/VigilScreen-export/`), `version`
- **Steps:**
  1. Assert `Vigil Screen.app` exists at export path
  2. `xattr -cr "Vigil Screen.app"`
  3. `xcrun stapler validate` — must say "The validate action worked!"
  4. `spctl -a -vvv -t install` — must show `source=Notarized Developer ID`
  5. `codesign --verify --deep --strict` — must pass cleanly
  6. Build DMG: `hdiutil create` with staging dir + `/Applications` symlink
  7. `hdiutil verify` on the DMG
  8. Rename to `VigilScreen-{version}.dmg`
  9. `shasum -a 256` — save result
  10. Write `/tmp/vigil-release-state.json`
- **Fails hard** if any verification step fails — never proceeds past a bad signature

### `release-publish`

- **Runs:** automatically until the confirmation gate
- **Inputs:** reads `/tmp/vigil-release-state.json`; falls back to asking for version + DMG path if file missing
- **Steps:**
  1. `gh release create v{version}` + upload DMG
  2. `gh repo clone atomsbaza/homebrew-tap /tmp/homebrew-tap`
  3. Edit `Casks/vigil-screen.rb`: bump `version`, replace `sha256`
  4. `brew style ./Casks/vigil-screen.rb` — fix any offenses inline, re-run until clean
  5. **Confirmation gate** — show diff, ask "push cask update?"
  6. `git commit -m "vigil-screen: {version}"` + `git push`
  7. `gh release view v{version}` — verify asset uploaded
  8. Cleanup: `rm -rf /tmp/homebrew-tap`

### Orchestrator (`/release`)

- Accepts optional version arg; reads `MARKETING_VERSION` from `project.pbxproj` as fallback
- Pre-flight: `git status --short` (clean), version match, `gh auth status`, tag absent
- Pause 1: instructs Xcode export steps, waits for user "done" + export path
- Spawns `release-preflight`
- Pause 2: shows DMG size + SHA256, asks "publish to GitHub + Homebrew?"
- Spawns `release-publish`
- Prints final summary: tag URL, SHA256, cask commit URL, install command

## Error Handling

| Scenario | Behavior |
|---|---|
| Tag already exists | Pre-flight stops; tells user before any work |
| Notarization fails (`stapler`/`spctl`) | Preflight stops; directs user to Xcode notarization log |
| `codesign --verify` fails | Preflight stops; never builds DMG |
| `brew style` offenses | Publish fixes inline and re-runs; never pushes failing cask |
| Publish fails after GitHub upload | State file preserved; user reruns `release-publish` alone |
| State file missing on direct `release-publish` run | Agent asks for version + DMG path as inputs |

## Files to Create/Modify

- **Modify:** `.claude/skills/release/SKILL.md` — rewrite as orchestrator
- **Create:** `.agents/release-preflight/AGENT.md`
- **Create:** `.agents/release-publish/AGENT.md`

## Out of Scope

- Auto-bumping `MARKETING_VERSION` in `project.pbxproj` (user does this before invoking `/release`)
- Triggering the Xcode archive/export programmatically (requires Organizer UI)
- Smoke-testing the installed cask on a second machine

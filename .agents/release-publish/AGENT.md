# release-publish

Publish a packaged Vigil Screen DMG to GitHub Releases and update the Homebrew cask. Runs automatically up to a single confirmation gate before pushing anything public.

## Inputs

Read `/tmp/vigil-release-state.json`:
```json
{
  "version": "0.3.4",
  "dmg_path": "/Users/.../VigilScreen-0.3.4.dmg",
  "sha256": "abc123..."
}
```

If the file is missing, ask the user for `version` and `dmg_path` (compute SHA256 from the file).

## Steps

### 1. Verify inputs

```bash
cat /tmp/vigil-release-state.json
ls -lh "$DMG_PATH"
shasum -a 256 "$DMG_PATH"   # confirm SHA256 matches state file
```

### 2. Check tag does not already exist

```bash
gh release view "v${VERSION}" --repo atomsbaza/VigilScreen 2>&1
```

If release exists, stop and report — do not clobber without explicit user instruction.

### 3. Create GitHub release and upload DMG

```bash
gh release create "v${VERSION}" "$DMG_PATH" \
  --repo atomsbaza/VigilScreen \
  --title "v${VERSION} — Vigil Screen" \
  --generate-notes
```

Verify upload:
```bash
gh release view "v${VERSION}" --repo atomsbaza/VigilScreen --json assets --jq '.assets[] | {name, size}'
```

### 4. Clone Homebrew tap

```bash
rm -rf /tmp/homebrew-tap
gh repo clone atomsbaza/homebrew-tap /tmp/homebrew-tap
```

### 5. Edit cask

In `/tmp/homebrew-tap/Casks/vigil-screen.rb`, update:
- `version` → new version string
- `sha256` → SHA256 from state file

### 6. Lint cask

```bash
cd /tmp/homebrew-tap
brew style ./Casks/vigil-screen.rb
```

If offenses are reported, fix them inline and re-run `brew style` until zero offenses. Do not proceed with failures.

### 7. Confirmation gate — STOP HERE

Show the user:
- The cask diff (`git diff Casks/vigil-screen.rb`)
- GitHub release URL: `https://github.com/atomsbaza/VigilScreen/releases/tag/v${VERSION}`

Ask: **"DMG is live on GitHub. Push the Homebrew cask update?"**

Wait for explicit confirmation before continuing.

### 8. Commit and push cask

```bash
cd /tmp/homebrew-tap
git add Casks/vigil-screen.rb
git commit -m "vigil-screen: ${VERSION}"
git push
```

### 9. Verify and cleanup

```bash
gh release view "v${VERSION}" --repo atomsbaza/VigilScreen --json assets,tagName,url
rm -rf /tmp/homebrew-tap
rm -f /tmp/vigil-release-state.json
```

### 10. Print final summary

```
✅ v{version} shipped

Release:  https://github.com/atomsbaza/VigilScreen/releases/tag/v{version}
SHA256:   {sha256}
Install:  brew install --cask atomsbaza/tap/vigil-screen
Upgrade:  brew upgrade --cask vigil-screen
```

## Hard stops

- State file missing and user cannot provide DMG path
- Release tag already exists (do not clobber)
- `brew style` still failing after fix attempts
- User declines confirmation at step 7

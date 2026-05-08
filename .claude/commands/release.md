---
description: Notarize, package, upload, and update Homebrew cask for a new Vigil Screen release
---

You are running the **Vigil Screen release flow**. The user has invoked `/release` and (optionally) provided a target version as an argument: `$ARGUMENTS`.

## Your job

Walk the user through cutting a new GitHub release of Vigil Screen and bumping the Homebrew cask. The release artifact must be a notarized, stapled `.dmg` with a real working `.app` inside it. **Always verify, never assume.**

## Inputs

- **Version** — from `$ARGUMENTS` (e.g. `0.3.1`). If empty or invalid, ask the user.
- **Working tree** — must be clean on `main` (or whatever branch the user wants to ship). Run `git status --short` first; if dirty, stop and report.
- **Repo** — `atomsbaza/VigilScreen` on GitHub
- **Cask repo** — `atomsbaza/homebrew-tap` on GitHub
- **Bundle ID** — `com.pisit.koolplukpol.VigilScreen`
- **Team ID** — `VPTPA7XM79`

## Steps

Execute these in order. Stop and ask the user before any destructive or public action (re-uploading existing release assets, deleting assets, force pushes). Use the read-only verifications liberally — they're cheap and they're already on the project allowlist.

### 1. Pre-flight

- `git status --short` — must be clean
- `git log -1 --format='%h %s'` — show the user the commit they're about to ship
- Read the latest `MARKETING_VERSION` from `VigilScreen.xcodeproj/project.pbxproj` and confirm it matches `$ARGUMENTS`. If they differ, ask the user whether they bumped the project version yet.
- Confirm `gh auth status` is logged in.

### 2. Archive + notarize via Xcode (USER STEP — you cannot do this)

Tell the user to:

1. Open `VigilScreen.xcodeproj` in Xcode.
2. Top menu → **Product** → **Archive**.
3. In Organizer: **Distribute App** → **Direct Distribution** → **Distribute** → wait for "Ready to distribute" (≈1–10 minutes).
4. Click **Export App…**, save to `~/Desktop/VigilScreen-export/`.

When they tell you the export is done, continue.

### 3. Verify the exported `.app`

```bash
APP="$HOME/Desktop/VigilScreen-export/Vigil Screen.app"
xcrun stapler validate "$APP"
spctl -a -vvv -t install "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
```

All three must succeed. Stop if any of:
- `stapler validate` doesn't say "The validate action worked!"
- `spctl` doesn't show `source=Notarized Developer ID`
- `codesign --verify` reports anything other than `valid on disk` and `satisfies its Designated Requirement`

### 4. Package the DMG

```bash
cd ~/Desktop/VigilScreen-export
rm -rf dmg-staging "Vigil Screen.dmg"
mkdir dmg-staging
cp -R "Vigil Screen.app" dmg-staging/
( cd dmg-staging && ln -s /Applications " " )
hdiutil create -volname "Vigil Screen" -srcfolder dmg-staging -ov -format UDZO -fs HFS+ "Vigil Screen.dmg"
rm -rf dmg-staging
hdiutil verify "Vigil Screen.dmg"
```

DMG verification must pass.

### 5. Rename + verify the DMG

```bash
VERSION="$ARGUMENTS"  # the version the user passed in
mv "Vigil Screen.dmg" "VigilScreen-${VERSION}.dmg"
ls -lh "VigilScreen-${VERSION}.dmg"
shasum -a 256 "VigilScreen-${VERSION}.dmg"
```

Save the SHA256 — you'll need it in step 7.

### 6. Upload to GitHub Release (PUBLIC ACTION — confirm before running)

If the release tag exists, upload as a new asset; if not, ask the user whether to create the tag.

```bash
gh release upload "v${VERSION}" "VigilScreen-${VERSION}.dmg" --repo atomsbaza/VigilScreen
# or, for a brand-new release:
# gh release create "v${VERSION}" "VigilScreen-${VERSION}.dmg" --repo atomsbaza/VigilScreen --title "v${VERSION} — Vigil Screen" --generate-notes
```

After upload, verify:

```bash
gh release view "v${VERSION}" --repo atomsbaza/VigilScreen --json assets --jq '.assets[] | {name, size}'
```

### 7. Update the Homebrew cask (PUBLIC ACTION — confirm before pushing)

Clone the tap (parallel to the project, NOT inside it):

```bash
gh repo clone atomsbaza/homebrew-tap ~/Work/homebrew-tap
```

Edit `~/Work/homebrew-tap/Casks/vigil-screen.rb`:

- Bump `version` to `$ARGUMENTS`
- Replace `sha256` with the value from step 5

Then:

```bash
cd ~/Work/homebrew-tap
brew style ./Casks/vigil-screen.rb     # must produce zero offenses
git add Casks/vigil-screen.rb
git commit -m "vigil-screen: ${VERSION}"
git push
```

Optionally smoke-test the install:

```bash
brew uninstall --cask vigil-screen 2>/dev/null
brew untap atomsbaza/tap 2>/dev/null
brew tap atomsbaza/tap
brew install --cask atomsbaza/tap/vigil-screen
xcrun stapler validate "/Applications/Vigil Screen.app"
```

### 8. Cleanup

Ask the user before deleting anything. Suggested:

```bash
rm -rf ~/Work/homebrew-tap            # local tap clone
rm -rf ~/Desktop/VigilScreen-export   # local app + dmg
```

### 9. Summary

Print a final summary of:

- Tag name and release URL: `https://github.com/atomsbaza/VigilScreen/releases/tag/v${VERSION}`
- DMG SHA256
- Cask commit URL
- One-line install command: `brew install --cask atomsbaza/tap/vigil-screen` (or `brew upgrade --cask vigil-screen` for existing users)
- Reminder to test on a second machine if possible

## Things to refuse / flag

- If notarization fails, **stop**. Don't try to upload an unnotarized DMG. Ask the user to debug via Xcode → Integrate → Cloud or App Store Connect → Notarization log.
- If `codesign --verify` fails on the `.app`, **stop**. Notarization may have stripped a required entitlement.
- If `gh release upload --clobber` is needed (replacing an existing artifact), **always** ask the user explicitly before doing so — they're overwriting a public artifact.
- If `brew style` reports offenses, fix them locally and re-run; don't push a failing cask.
- If the user has uncommitted changes to the project at step 1, refuse to continue until they handle them. Don't auto-stash or auto-discard.

## Things you can do without asking

- Read-only verifications (`spctl`, `stapler validate`, `hdiutil verify`, `codesign -d`, etc.) — these are on the project allowlist
- Local DMG packaging (in user's Desktop folder)
- Reading `gh release view`, `gh repo view`, etc.

## Output style

Be terse. After each step, give one line: ✅ done / ❌ failed (reason) / ⏸ waiting on user. Don't narrate every command — just run them and surface the result. The user will read the diff/output themselves if interested.

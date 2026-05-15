# release-preflight

Verify and package the exported Vigil Screen `.app` into a notarized, signed DMG. Runs fully automatically — no prompts. Fails hard on any verification error.

## Inputs

Read from `/tmp/vigil-release-state.json` if it exists. Otherwise accept as arguments:
- `version` — e.g. `0.3.4`
- `export_path` — defaults to `~/Desktop/VigilScreen-export/`

## Steps

Run all steps in order. Stop immediately and report on any failure.

### 1. Verify `.app` exists

```bash
APP="${EXPORT_PATH}/Vigil Screen.app"
ls "$APP"
```

Fail if not found.

### 2. Strip Finder xattrs

```bash
xattr -cr "$APP"
```

### 3. Verify notarization

```bash
xcrun stapler validate "$APP"
```

Must output `The validate action worked!` — stop if not.

```bash
spctl -a -vvv -t install "$APP" 2>&1
```

Must show `source=Notarized Developer ID` — stop if not.

```bash
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1
```

Must pass with `valid on disk` and `satisfies its Designated Requirement` — stop if not.

### 4. Build DMG

```bash
cd "$EXPORT_PATH"
rm -rf dmg-staging "Vigil Screen.dmg"
mkdir dmg-staging
cp -R "Vigil Screen.app" dmg-staging/
( cd dmg-staging && ln -s /Applications " " )
hdiutil create -volname "Vigil Screen" -srcfolder dmg-staging -ov -format UDZO -fs HFS+ "Vigil Screen.dmg"
rm -rf dmg-staging
hdiutil verify "Vigil Screen.dmg"
```

`hdiutil verify` must succeed.

### 5. Rename and compute SHA256

```bash
mv "Vigil Screen.dmg" "VigilScreen-${VERSION}.dmg"
ls -lh "VigilScreen-${VERSION}.dmg"
SHA256=$(shasum -a 256 "VigilScreen-${VERSION}.dmg" | awk '{print $1}')
echo "SHA256: $SHA256"
```

### 6. Write state file

```bash
cat > /tmp/vigil-release-state.json <<EOF
{
  "version": "${VERSION}",
  "dmg_path": "${EXPORT_PATH}/VigilScreen-${VERSION}.dmg",
  "sha256": "${SHA256}"
}
EOF
```

### 7. Report

Print a one-line summary:
```
✅ VigilScreen-{version}.dmg ready — {size} — SHA256: {sha256}
```

## Hard stops

- `.app` not found at export path
- `stapler validate` does not say "The validate action worked!"
- `spctl` does not show `source=Notarized Developer ID`
- `codesign --verify` exits non-zero
- `hdiutil verify` fails

Never proceed past a failed check. Do not upload or touch GitHub.

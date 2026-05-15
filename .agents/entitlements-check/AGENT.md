# entitlements-check

Verify that entitlements, Info.plist usage strings, and pbxproj settings are consistent with what the code actually uses. Runs fully automatically, no prompts. Reports mismatches that would cause distribution failure or runtime crashes.

## What to check

### 1. Entitlements file vs. code usage

Read `VigilScreen/Resources/VigilScreen.entitlements` and cross-check against actual API usage:

| Entitlement | Expected if code uses |
|---|---|
| `com.apple.security.device.bluetooth` | `CBCentralManager` in `BluetoothMonitor.swift` |
| `com.apple.security.device.camera` | `AVCaptureSession` in `IntruderCaptureManager.swift` |
| `com.apple.developer.ubiquity-kvstore-identifier` | `NSUbiquitousKeyValueStore` in `CloudSyncStore.swift` |
| `com.apple.developer.icloud-container-identifiers` | `CKContainer` or CloudKit APIs |
| `com.apple.security.cs.allow-unsigned-executable-memory` | Should be `false` unless JIT is used |

Flag any entitlement present but not used, and any API used but missing its entitlement.

### 2. Accessibility — not an entitlement, but a permission

`PanicModeManager.swift` uses `AXUIElement` APIs. Verify:
- `NSAppleEventsUsageDescription` or `NSAccessibilityUsageDescription` exists in `Info.plist` (or equivalent)
- `PermissionManager.swift` polls `AXIsProcessTrusted()` — confirm this guard is present before any AX calls in `PanicModeManager`

### 3. pbxproj consistency

```bash
grep -E 'CODE_SIGN_ENTITLEMENTS|PRODUCT_BUNDLE_IDENTIFIER' VigilScreen.xcodeproj/project.pbxproj | sort -u
```

- `CODE_SIGN_ENTITLEMENTS` must point to `VigilScreen/Resources/VigilScreen.entitlements` for both Debug and Release configs
- `PRODUCT_BUNDLE_IDENTIFIER` must be `com.pisit.koolplukpol.VigilScreen` for the app target

### 4. iCloud container identifier

In the entitlements file, `com.apple.developer.icloud-container-identifiers` is an empty array. Verify:
- If `CloudSyncStore.swift` uses `CKContainer` → array must be non-empty (flag it)
- If it only uses `NSUbiquitousKeyValueStore` → empty array is correct (confirm)

### 5. Hardened Runtime flags

Check `com.apple.security.cs.allow-unsigned-executable-memory` is `false`. Flag if `true` — it weakens the security model and can affect notarization approval.

## Output format

```
── Entitlements Check ────────────────────────────
  bluetooth        ✅ entitlement present, CBCentralManager used
  camera           ✅ entitlement present, AVCaptureSession used
  icloud-kvstore   ✅ entitlement present, NSUbiquitousKeyValueStore used
  icloud-container ✅ empty array, no CKContainer usage found
  hardened-runtime ✅ allow-unsigned-executable-memory = false
  accessibility    ✅ AXIsProcessTrusted() guard present before AX calls
  pbxproj          ✅ entitlements path + bundle ID consistent across configs
──────────────────────────────────────────────────
Result: ✅ All checks passed  |  ❌ {n} issue(s) found (listed above)
```

For each ❌, explain what's wrong and what to fix.

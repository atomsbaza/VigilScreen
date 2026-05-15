# panic-mode-verify

Audit the Panic Mode overlay implementation for correctness — coverage gaps, window level issues, safelist logic, and multi-display edge cases. Reads source only, no runtime required.

## What to verify

### 1. Overlay coverage — all screens

Read `PanicModeManager.swift`. Verify:
- Overlays are created for every screen via `NSScreen.screens` (not just `NSScreen.main`)
- Each overlay is keyed by `CGDirectDisplayID` in `overlayWindows`
- `NSScreen.screens` is observed for changes (display connect/disconnect during Panic Mode)

Flag if: overlays are only created for the main screen, or if screen changes aren't handled.

### 2. Window level correctness

The overlay must sit at `.screenSaver` (level 1000) to cover full-screen apps. Verify:
- `overlayWindows` use `.screenSaver` level during active Panic Mode
- No code path lowers the window level below `.screenSaver` while Panic Mode is active
- The "lower overlay level" step (if present for safelisted app visibility) only applies to the mask, not the window level itself

Flag any window level that drops below 1000 while `isActive == true`.

### 3. Safelist mask logic

Read `AppBlocklist.swift` (or `AppSafelist.swift`) and `PanicModeManager.swift`. Verify:
- `cachedSafelistMasks` are invalidated when the safelist changes
- Mask holes are computed from real window frames (via `AXUIElement`), not hardcoded positions
- `pendingActivationWork` cancels previous pending work before scheduling new (no mask rebuild race)
- RSSI of 127 isn't relevant here — confirm mask rebuild uses `CGDirectDisplayID` correctly per screen

### 4. Auth release path

Read the authentication block in `PanicModeManager`. Verify:
- `LAPolicy.deviceOwnerAuthentication` is used (accepts Touch ID, password, Apple Watch)
- On auth failure, `IntruderCaptureManager` is triggered before returning
- `isActive` is only set to `false` after successful auth — never before
- `isAuthenticating` guard prevents double-auth prompts

### 5. App hide sequence

Verify the hide sequence order:
1. Notification Center closed first
2. Full-screen exits via AX before `.hide()`
3. `.hide()` called on all non-safelisted apps
4. Overlays shown
5. 400ms delay then re-hide (catches apps that re-window after initial hide)

Flag if the overlay is shown before apps are hidden (causes visible flash).

### 6. Multi-display edge cases

Check for these known problem patterns (from git history — fixed in v0.3.4):
- Overlay frame must match `screen.frame` (not `screen.visibleFrame`) to cover menu bar
- Mask image coordinate space must be flipped correctly per screen
- `CGDirectDisplayID` must not be reused across display reconnects without refresh

Confirm the current code handles these correctly post-fix.

## Output format

```
── Panic Mode Verify ─────────────────────────────
  Screen coverage     ✅ all screens covered via NSScreen.screens
  Window level        ✅ .screenSaver (1000) maintained during active panic
  Safelist masks      ✅ / ⚠️ {finding}
  Auth release        ✅ LAPolicy.deviceOwnerAuthentication, isActive guard correct
  Hide sequence       ✅ / ❌ {finding}
  Multi-display       ✅ frame + coordinate space correct post-v0.3.4 fixes
──────────────────────────────────────────────────
Result: ✅ Implementation correct  |  ❌ {n} issue(s) found
```

For each ❌ or ⚠️, cite the exact file and line range, explain the risk, and suggest the fix.

# DockLock — Panic button for your Mac 🔒

Hey! I built DockLock, a free open-source macOS menu bar app for developers and anyone who handles sensitive work on their laptop.

**The problem it solves:** You're working in a café or open office — code, credentials, client data on screen. Someone walks up behind you. You need everything hidden *right now*, not in 3 clicks.

---

## What it does

**⌘⇧L → instant full-screen blur on every display.**
Your trusted apps (Terminal, Xcode, browser) stay visible above the blur. Everything else vanishes. Touch ID to release.

**Walk away from your desk** with your iPhone in your pocket → Mac locks itself automatically via Bluetooth proximity detection.

**Someone tries to unlock it while you're away** → front camera captures a photo, saved locally, notification sent to your phone.

---

## Tech for the curious

Pure Swift 6 with zero external dependencies. Strict concurrency throughout. The blur overlay is an `NSVisualEffectView` at window level -1 with CGContext bitmap masks punching transparent holes for safelisted app windows — updated every 250ms so safelisted apps stay interactive above the blur without the overlay ever moving.

---

## It's completely free and open source

[github.com/atomsbaza/DockLock](https://github.com/atomsbaza/DockLock)

If it saves you from an awkward moment or keeps your work private, buying me a coffee helps me keep building — and eventually get it notarized so macOS stops complaining on first launch ☕

Thanks for checking it out.

---

**Title:** DockLock — Privacy panic button for your Mac
**Tags:** macOS, Swift, open source, privacy, developer tools

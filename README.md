<p align="center">
  <img src="./taphide-icon-2.0.1.png" width="168" height="168" alt="TapHide app icon">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014.0%2B-blue" alt="Platform">
  <img src="https://img.shields.io/badge/arch-arm64%20%7C%20x86__64-brightgreen" alt="Architecture">
  <img src="https://img.shields.io/badge/license-GPL--3.0-green" alt="License">
  <br>
  <a href="README_CN.md"><img src="https://img.shields.io/badge/readme-%E4%B8%AD%E6%96%87%20%7C%20Chinese-red?style=flat-square" alt="中文文档"></a>
</p>

# TapHide

Turn your Dock into a toggle switch. Click a running app's icon to focus it &mdash; click it again to **hide** or **minimize**.

<p align="center">
  <i>"Click once to focus, twice to dismiss."</i>
</p>

---

## How It Works

```
         ┌────────────────────────────────────┐
         │  CGEvent Tap (system-wide hook)    │
         │         mouseDown event            │
         └──────────────┬─────────────────────┘
                        │
                        ▼
              ┌─────────────────┐
              │  Click in Dock?  │──── No ──▶ Pass through
              └────────┬────────┘
                       │ Yes
                       ▼
              ┌─────────────────┐
              │  Target PID =    │──── No ──▶ Pass through
              │  Frontmost PID?  │
              └────────┬────────┘
                       │ Yes
                       ▼
              ┌─────────────────┐
              │  Swallow click   │
              │  Hide / Minimize │
              └─────────────────┘
```

TapHide installs a `CGEvent` tap that intercepts left mouse clicks. When you click inside the Dock area on an already-frontmost app's icon, the click is swallowed and your chosen action (hide or minimize) is executed instead.

TapHide is intentionally closer to a lightweight Dock enhancement such as HyperDock-style shortcuts than a full Dock replacement such as uBar. It keeps Apple's Dock visible and only changes the repeated-click behavior for the active app.

### Two Modes

| Mode | Behavior |
|---|---|
| **Hide** | Hides the entire application (`Cmd+H` equivalent) |
| **Minimize** | Minimizes the frontmost window (`Cmd+M` equivalent) |

---

## Installation

### Via Homebrew (Recommended)

```bash
brew tap stors789/tap
brew install --cask taphide
```

### From Source

```bash
# 1. Clone
git clone https://github.com/stors789/taphide.git
cd taphide

# 2. Build (requires Xcode Command Line Tools)
./build.sh

# 3. Move to Applications (important for permissions)
mv .build/TapHide.app /Applications/

# 4. Launch
open /Applications/TapHide.app
```

**First launch:** Right-click the app and select *Open* to bypass Gatekeeper, or run:

```bash
xattr -cr /Applications/TapHide.app
```

Then grant the two permissions in **System Settings → Privacy & Security**.

### Requirements

| Item | Details |
|---|---|
| macOS | 14.0 (Sonoma) or later |
| Architecture | Apple Silicon &amp; Intel (auto-detected) |
| Build Tools | Xcode Command Line Tools (`xcode-select --install`) |

---

## Permissions

TapHide needs two permissions — both must be granted for the app to work.

| Permission | Why It's Needed |
|---|---|
| **Accessibility** | Read the Dock's UI hierarchy (icon positions, app identities), and perform window minimize/restore |
| **Input Monitoring** | Intercept mouse clicks globally to detect Dock icon interactions |

### Setup Steps

1. Launch TapHide — it will show a red "Permissions Needed" badge
2. Go to **System Settings → Privacy & Security → Accessibility**, toggle TapHide **ON**
3. Go to **System Settings → Privacy & Security → Input Monitoring**, toggle TapHide **ON**
4. Keep the Settings window open for a few seconds, or quit and reopen TapHide — the status dot should turn green

> **Troubleshooting:** If it still doesn't work after granting both, remove TapHide from both lists, quit the app, then re-add and re-launch.

---

## Project Structure

```
Sources/
├── TapHideApp.swift              # @main entry, menubar UI, lifecycle
├── DebugLog.swift                   # File-based logging under ~/Library/Logs/TapHide
├── SettingsView.swift               # Settings window content
├── SettingsWindowManager.swift      # NSWindow management
├── Engine/
│   ├── EventTapEngine.swift         # Core: CGEvent tap + click interception
│   ├── ActionExecutor.swift         # Hide / minimize via AppKit + AX APIs
│   ├── DockInspector.swift          # Dock process resolution, frame detection
│   ├── DockIconCache.swift          # Icon position/PID cache (30s fallback + app/screen events)
│   └── FrontmostTracker.swift       # Tracks active frontmost app PID
├── Models/
│   └── BehaviorMode.swift           # .hide | .minimize enum
├── Permissions/
│   └── PermissionsManager.swift     # Permission check + request logic
└── Settings/
    ├── ConfigStore.swift            # @AppStorage persistence
    └── PermissionsGateView.swift    # Permission status UI
```

Built as a single Swift executable bundled into a `.app` — no Xcode project, no SPM, no third-party dependencies.

---

## Debugging

Logs are written to `~/Library/Logs/TapHide/taphide.log`. You can tail them live:

```bash
tail -f ~/Library/Logs/TapHide/taphide.log
```

The Settings window can also refresh, clear, or reveal the log file in Finder. Logs rotate to `taphide.old.log` after roughly 1 MB.

Useful entries:

| Prefix | Meaning |
|---|---|
| `[APP]` | App lifecycle, permissions, launch-at-login changes |
| `[TAP]` | Mouse events and click interception decisions |
| `[CACHE]` | Dock icon frame/PID cache refreshes |
| `[DOCK]` | Dock frame and Accessibility hit-test details |
| `[MINIMIZE]` / `[HIDE]` | Window action execution |

---

## Known Limits

- TapHide depends on macOS Accessibility metadata. Some apps expose incomplete window information, so minimize mode may fall back to hide.
- Finder and Dock are ignored as protected targets.
- Full-screen apps, multiple Spaces, and Stage Manager can still affect which window macOS considers focused.
- Input Monitoring changes may require restarting the app if macOS does not deliver the permission update immediately.

---

## Maintenance

- Changes are tracked in [CHANGELOG.md](CHANGELOG.md).
- Near-term work is tracked in [TODO.md](TODO.md).

---

## License

GPL-3.0

---

<p align="center">
  <sub>Entirely generated by <b>DeepSeek v4 Pro</b> + <b>OpenCode</b></sub>
</p>

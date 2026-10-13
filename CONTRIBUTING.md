# Contributing / ownership

| Path | Owner | What |
|---|---|---|
| `Sources/PausaCore/`, `Sources/PausaCoreCheck/` | Mitchell | Scheduler / state machine, pure logic, no UI; check program |
| `Sources/Pausa/Core/`, `Sources/Pausa/MenuBar/`, `App/`, `Sources/Pausa/main.swift` | Mitchell | App shell, wiring, menu bar, settings (main.swift is a placeholder to replace) |
| `Sources/Pausa/Detection/` | Linus | `PauseDetector`: meeting (mic/camera, virtual devices excluded, 2 min grace), allowlisted fullscreen, lock/sleep `onAway` |
| `Sources/Pausa/Overlay/` | Linus | `BreakOverlayController`: short capsule + dim, long full-screen break on every display |
| `Sources/Pausa/Debug/` | Linus | `--debug-detect`, `--debug-short`, `--debug-long`, `--debug-render <dir>` |

Contract:
- The overlay layer does no scheduling. The scheduler decides when; overlay reports back with callbacks:
  `showShort(duration:onFinish:)`, `showLong(duration:onSnooze:onSkip:onFinish:)`, `dismiss()`.
- The detector publishes `reasons: Set<PauseReason>` (main thread) and `onAway(.start/.end)`; the scheduler decides what they mean.
- Stay inside your own directories; change the interface by PR.

Build: `swift build` on macOS 13+. Check: `swift run PausaCoreCheck`.

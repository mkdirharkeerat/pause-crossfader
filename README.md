# 🎧 Pause Crossfader for macOS

> **Eliminate awkward video pauses with seamless, studio-grade Spotify & Apple Music crossfading on macOS.**

When watching YouTube or other video media in Firefox (or Chrome/Safari), pausing often leaves a sudden, jarring silence. **Pause Crossfader** is an ultra-lightweight, native macOS menu bar utility that automatically detects when web media is paused and smoothly fades in your favorite music playlist. The moment you resume the video, your music gracefully fades out and pauses.

---

## ✨ Features

- ⚡ **Zero-Extension Detection**: Directly monitors macOS CoreAudio HAL (`kAudioProcessPropertyIsRunning`) for browser audio processes. No browser plugins, webhooks, screen recording permissions, or local servers required.
- 🎵 **Multi-Player Support**: Seamlessly controls **Spotify** and **Apple Music** (`Music.app`). Switch your active player anytime directly from the menu bar.
- ⏱️ **Scrub-Safe Debounce Filter**: Video scrubbing (arrow keys, timeline dragging) or brief buffering periods won't cause annoying music blips. Choose from presets (`300ms`–`1600ms`) or enter **any exact millisecond value**.
- 🎚️ **Custom Ease Curves & Millisecond Control**:
  - **Ease-In on Pause**: Quadratic ease-out curve prevents sudden bursts of volume, swelling smoothly into the room.
  - **Ease-Out on Resume**: Power curve steps down volume to 0%, sends pause, and restores your baseline volume.
  - **Custom Millisecond Dialogs**: Configure custom debounce, fade-in, and fade-out down to the millisecond.
- 🛡️ **Master Volume Safety**: Never tampers with macOS system volume. YouTube always plays at normal volume; only the music player's internal software volume slider is crossfaded.
- 🪶 **Negligible Resource Usage**: Caches CoreAudio hardware descriptors; average CPU consumption is `<0.02%`.

---

## 🏗️ Architecture

```
 ┌──────────────────────┐        CoreAudio HAL         ┌────────────────────────┐
 │   Firefox / Chrome   │ ──── (Zero-Latency HAL) ───> │  BrowserAudioMonitor   │
 └──────────────────────┘                              └───────────┬────────────┘
            │                                                      │
     [Pause Detected]                                    [Resume Detected]
            │                                                      │
  Debounce Filter (900ms)                                Immediate Cancel
            ▼                                                      ▼
 ┌──────────────────────┐                              ┌────────────────────────┐
 │  Music Fade-In       │                              │  Music Fade-Out        │
 │  0 ➔ 85% Vol (2.5s)  │                              │  85% ➔ 0 Vol (1.2s)    │
 │  (Quadratic Ease-In) │                              │  (Pause & Restore Vol) │
 └──────────────────────┘                              └────────────────────────┘
            │                                                      │
            └──────────────> [ Spotify / Apple Music ] <───────────┘
```

---

## 🚀 Quick Start

### Prerequisites
- macOS 13.0+ (Ventura, Sonoma, Sequoia, or later)
- Swift Compiler (built into Xcode Command Line Tools: `xcode-select --install`)
- Spotify Desktop or Apple Music

### Build & Run
```bash
# Clone the repository
git clone https://github.com/mkdirharkeerat/pause-crossfader.git
cd pause-crossfader

# Build the native app bundle
chmod +x build.sh
./build.sh

# Launch the app
open PauseCrossfader.app
```

---

## 🎛️ Menu Bar Controls

Look for the `🎧` icon in the macOS menu bar:

- **Live Status**: Real-time display (`Watching YouTube`, `Fading In Spotify...`, `YouTube Playing`).
- **Auto-Crossfade Active**: One-click toggle (`⌘E`) to pause or resume crossfader automation.
- **Music Player App**: Select between **Spotify** or **Apple Music**.
- **Target Browser**: Select **Firefox (Default)** or **All Web Browsers (Universal)**.
- **Debounce Delay**:
  - Presets: `300ms`, `600ms`, `900ms`, `1200ms`, `1600ms`.
  - **⚙ Custom Debounce (ms)...**: Enter any custom millisecond threshold via native dialog.
- **Fade-In Duration (on Pause)**:
  - Presets: `0.8s`, `1.5s`, `2.5s`, `3.5s`, `5.0s`.
  - **⚙ Custom Fade-In (ms)...**: Enter custom fade-in duration.
- **Fade-Out Duration (on Resume)**:
  - Presets: `0.6s`, `1.2s`, `1.8s`, `2.5s`.
  - **⚙ Custom Fade-Out (ms)...**: Enter custom fade-out duration.
- **Manual Test Triggers**: Test fade-in and fade-out on demand.

---

## 📄 License

MIT License. Copyright (c) 2026 Harkeerat Singh ([mkdirharkeerat](https://github.com/mkdirharkeerat)).

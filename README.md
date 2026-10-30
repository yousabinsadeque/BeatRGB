# BeatRGB

A native macOS app (Swift / SwiftUI) that turns whatever your Mac is playing into lighting on a
**Corsair K70 CORE RGB TKL**. It can also mirror your display's colours onto the keys.

* All effects are rendered by BeatRGB. No plugins are needed, and with the **Native USB** backend (the default) neither is OpenRGB.
* System audio is captured with a Core Audio **process tap**: no microphone, no BlackHole, nothing is recorded or uploaded.
* Two ways to drive the keyboard, chosen in Settings → Keyboard connection:
  * **Native USB.** BeatRGB talks to the K70 CORE RGB TKL over USB HID itself, using the Corsair Peripheral V2 protocol.
  * **OpenRGB SDK.** Colours go through OpenRGB's SDK server (TCP `127.0.0.1:6742`). Only the keyboard is touched.

## Requirements

| | |
|---|---|
| Mac | Apple Silicon, macOS 15 or later (built and tested on macOS 27.0.1, M3 MacBook Air) |
| To build | Xcode 27, `xcodegen` (`brew install xcodegen`) |
| Keyboard backend | Nothing extra for Native USB. The OpenRGB backend needs OpenRGB with its SDK server running (your build: `~/Applications/OpenRGB Music.app`) |

## Build and install

```bash
cd ~/Desktop/BeatRGB
./scripts/build.sh            # runs unit tests, builds Release, installs ~/Applications/BeatRGB.app
```

`./scripts/build.sh Debug` gives a debug build. Build output goes to `~/Library/Caches/BeatRGB`
because iCloud-synced folders (Desktop) add file attributes that break code signing.

To work in Xcode, run `xcodegen generate` and open `BeatRGB.xcodeproj`. The core logic is a Swift
package (`BeatRGBKit`) with its own tests:

```bash
cd BeatRGBKit && swift test --scratch-path ~/Library/Caches/BeatRGB/spm
```

## First-time setup

1. **Pick a backend** in Settings → Keyboard connection.
   * **Native USB (default):** quit OpenRGB. BeatRGB refuses to start native control while OpenRGB is running, because both would write to the same USB interface.
   * **OpenRGB SDK:** in OpenRGB open the *SDK Server* tab and click **Start Server**, or launch it ready to go:
     ```bash
     open -a ~/Applications/"OpenRGB Music.app" --args --server --startminimized
     ```
2. **Stop other software from fighting for the keyboard.** Quit Corsair iCUE (or turn off its lighting control).
   With the OpenRGB backend, don't run an Effects-plugin effect at the same time. BeatRGB warns on the Dashboard about conflicting apps.
3. **Open BeatRGB** → **Lighting Studio → Hardware test → Send to keyboard.** Check that the physical keys change colour.
4. Click **Start Sync** and play music.

### Permissions (macOS asks once)

| Permission | When | Where to fix it |
|---|---|---|
| **System Audio Recording** | first Start Sync | System Settings → Privacy & Security → Screen & System Audio Recording → *System Audio Recording Only* → BeatRGB |
| **Screen Recording** | only for the *Screen Mirror* effect | same page → *Screen & System Audio Recording* → BeatRGB, then restart sync |
| Microphone | only if you pick an input device (e.g. BlackHole) as the source | Privacy & Security → Microphone |
| Input Monitoring | may be needed for the volume knob during sync | Privacy & Security → Input Monitoring |

BeatRGB is ad-hoc signed (no Apple Developer certificate on this Mac). macOS may ask for permissions
again after each rebuild, and may need *Open Anyway* on first launch. Settings → *Permissions &
troubleshooting* has buttons that open each of these pages.

## Features

* **Dashboard:** status for keyboard, OpenRGB SDK and system audio (each shows the actual error when something fails), current effect, update rate and latency, live keyboard preview, level meter, bass/mid/treble, spectrum, Start/Stop and master brightness.
* **Effects:**
  * Audio Spectrum: FFT bands, low on the left and high on the right, bars rising from the bottom row. Multicolour, two-colour gradient or single colour.
  * Bass Pulse: colour, intensity, attack, decay, sensitivity and baseline are all adjustable; the pulse spreads from the centre.
  * Rainbow Music Wave: speed and brightness follow loudness and beats.
  * Full-Keyboard Reaction: hue follows the bass/mid/treble balance; brightness follows volume.
  * Beat Ripple: rings start on each detected beat.
  * **Screen Mirror:** keys take the colours of the matching part of the display (ScreenCaptureKit at 136×72, averaged).
  * Static Colour.
* **Idle:** when music stops (noise gate plus a hold time), the lights fade to a static colour, breathing, rainbow or off.
* **Audio processing:** 2048-point vDSP FFT with a Hann window, 24 log-spaced bands, RMS level, bass/mid/treble energy, bass-onset beat detection, adaptive gain, noise gate, attack/release smoothing. Sensitivity, smoothing and bass response are adjustable.
* **Output:** 30 fps by default (10–60 adjustable). Frames that haven't changed are skipped. Once a second BeatRGB times a round trip through OpenRGB's device queue and lowers the frame rate if OpenRGB falls behind.
* **Safety:**
  * Targets only a Corsair device named *K70 … Core … TKL*, or optionally an exact serial number.
  * Checks the device's identity and Direct mode every second.
  * Re-finds the keyboard if OpenRGB's device list changes, and reconnects automatically with backoff.
  * On stop or quit it restores the colours from before it started (or idle, or off, as you choose) and removes its audio tap.
* **Profiles:** create, rename, duplicate, delete and load. Built-in profiles: Rainbow Spectrum, Bass Party, Relaxed Ambient, Gaming, Work Mode, Screen Mirror. Saved to `~/Library/Application Support/BeatRGB/profiles.json`.
* **Menu bar:** Start/Stop, effect, profile, brightness, level meter, Open, Quit. Closing the window keeps BeatRGB running, and it can hide its Dock icon.
* **Settings:** launch at login (SMAppService), OpenRGB host and port, auto-reconnect, what happens on stop, serial lock, audio source, permission shortcuts, volume knob.
* **Diagnostics:** compatibility checks, OpenRGB device scan (modes, LEDs, serial), fps and latency, event log, copy-diagnostics button.

## How it works

```
Core Audio process tap ─▶ SampleRing ─┐
(or chosen input device)              ├─▶ LightingEngine (own queue, 30 fps timer)
ScreenCaptureKit ─▶ ScreenGrid ───────┘     AudioAnalyzer (vDSP) → EffectRenderer → OpenRGBClient ─TCP─▶ OpenRGB ─USB─▶ K70
                                            snapshots @20 Hz ─▶ SwiftUI (main actor)
```

* **Audio.** A `CATapDescription(stereoGlobalTapButExcludeProcesses: [BeatRGB])` with `muteBehavior = .unmuted` feeds a private, tap-only aggregate device. Playback is untouched, BeatRGB's own sounds are excluded, and no microphone stream can mix in. The audio callback only copies samples into a lock-protected ring; the FFT runs at frame rate on the engine queue. The tap is rebuilt when the default output device changes. *ScreenCaptureKit audio was not used:* it needs Screen Recording permission, whereas the process tap needs only the narrower System Audio Recording permission.
* **OpenRGB SDK.** Based on OpenRGB's `NetworkServer.cpp` and `RGBController.cpp` for the server installed here, which speaks protocol 6. BeatRGB negotiates at most **v5**, so device indices are plain positions and the server sends no ACKs; the same client also works with OpenRGB 0.9 (v4) and 1.0rc (v5). The parser is checked against real controller-data payloads captured from your keyboard (`Tests/…/Fixtures`).

## Verified on this Mac (29 Oct 2026)

| Check | Result |
|---|---|
| OpenRGB SDK handshake | ✅ server v6, negotiated v5 |
| Keyboard found | ✅ `Corsair K70 Core RGB TKL`, 86 LEDs, 6×17 matrix, modes `Direct`, `Static` |
| Switch to Direct mode + LED write | ✅ read back from OpenRGB: all 86 LEDs set to the sent colour |
| System-audio capture | ✅ a test tone played through `afplay` (not the microphone) showed up at −37 dBFS with the correct 60 Hz and 3 kHz spectrum peaks |
| Audio-reactive frames reach OpenRGB | ✅ Spectrum and Bass Pulse ran at 29 fps with 7 ms latency; a second SDK client read the live colours back |
| Silence → idle fade | ✅ breathing idle colour once the tone ended |
| Stop restores previous colours | ✅ |
| **Native USB, OpenRGB not running** | ✅ keyboard answered with PID `0x2B01` and accepted software mode on endpoint `0x22` |
| Native USB sync | ✅ Audio Spectrum at 30 fps, 23 ms per frame. Every frame acknowledged by the keyboard (326 frames, 0 rejected) |
| **Physical keys light up (Native USB)** | ✅ confirmed by you |
| Native USB stop | ✅ hardware-mode command sent ("keyboard returned to its on-board lighting") |
| Unit tests | ✅ 55 tests: OpenRGB protocol, parser with real fixtures, client and engine against a fake OpenRGB server, Corsair V2 packets byte-for-byte against OpenRGB's layout, native driver against a mock keyboard, DSP, effects, screen downsampling, knob decoding, profiles |

### Still needs you to check

* **Physical LEDs, OpenRGB backend.** Confirmed only at the OpenRGB level so far (the native backend has been confirmed visually; see above). Also check that stopping in Native mode brings back your on-board lighting.
* **iCUE.** It was running during the native test. If its on-board effect overrides BeatRGB, quit it.
* **Spotify, Apple Music and YouTube.** Only a generated tone was tested; the tap captures all system output, so these should work the same.
* **Screen Mirror.** Built and unit-tested, but it needs Screen Recording permission, which hasn't been granted yet.
* **Volume knob ✅ confirmed (turning; pressing not supported yet).** When sync is stopped the keyboard handles the dial itself (standard volume keys). During native USB sync BeatRGB writes OpenLinkHub's software-mode key table, so the dial reports `00 05 60 00 <±1>` on the 0xFF42 usage 2 interface and BeatRGB changes the default output's volume through Core Audio. Typing is unaffected. Nothing is injected. Verified 2026-10-30: 48 dial events moved the volume 50→29→51→36 during sync. During OpenRGB-backend sync the dial stays silent.
* Launch at login, unplugging and replugging the keyboard, and restarting OpenRGB mid-sync are implemented but not exercised yet.

## Troubleshooting

* **"OpenRGB is running and also controls the keyboard" (Native USB).** Quit OpenRGB, or switch to the OpenRGB backend.
* **"…reported product ID 0x…, refusing to drive it" (Native USB).** A different Corsair device answered. Use the OpenRGB backend.
* **"OpenRGB SDK: Unavailable — connection refused".** The SDK server isn't running; see setup step 1.
* **"Keyboard not found".** OpenRGB doesn't list the K70. Unplug and replug it, or rescan devices in OpenRGB. Check that iCUE isn't holding it.
* **Lights flicker between BeatRGB and something else.** Quit iCUE. Stop any OpenRGB Effects-plugin effect. The log will say "Keyboard left Direct mode" when another app takes over.
* **"System audio: Running — silent" while music plays.** Grant *System Audio Recording* (table above), then Stop and Start sync.
* **The audio meter moves but the lights barely react.** Raise Sensitivity, lower the noise gate, or turn on Adaptive gain.

## Native USB backend

`BeatRGBKit/Sources/BeatRGBKit/Native/` and `NativeCorsairDriver` in `Engine/KeyboardDriver.swift`.
It reproduces OpenRGB's *Corsair Peripheral V2* driver (`CorsairPeripheralV2Controller` and
`…HWController`, which OpenRGB itself uses for this keyboard) command for command. No commands were
invented:

1. **Open.** Opens the vendor command interface (usage page `0xFF42`, usage `1`, 64-byte reports) non-exclusively through IOKit.
2. **Identify.** Reads property `0x12` and **refuses to continue unless the keyboard reports product ID `0x2B01`**.
3. **Pick the endpoint.** Opens a lighting transaction on endpoint `0x22` and falls back to `0x01` if the keyboard rejects it. Yours uses `0x22`.
4. **Software mode.** Switches to software render mode (`SET 0x03 = 2`), then sends lighting control `0x5F`.
5. **Each frame.** One transaction: start, a block write of `[0x12 0x00] + RGB × 123 slots` (7 packets, 2 ms apart), then stop. The keyboard's acknowledgement status is counted and shown.
6. **Key mapping.** Each key's slot comes from the controller description OpenRGB reported for *this* keyboard (bundled as `Resources/k70-core-tkl.bin`, ANSI layout id 1).
7. **On stop.** *Restore previous lighting* switches back to hardware mode (`SET 0x03 = 1`), so the keyboard resumes its own on-board effect, as OpenRGB does on exit. *Show idle colour* and *Turn lights off* write that frame and leave software mode on.

Licence note: this is a port of GPL-2.0-or-later OpenRGB code, so BeatRGB should be treated as
GPL-2.0-or-later if you distribute it.

## Project layout

```
BeatRGB/
├─ project.yml               xcodegen spec (app target, Info.plist keys, signing)
├─ scripts/build.sh          test + build + install
├─ App/                      SwiftUI app: AppModel, menu bar, Dashboard/Studio/Profiles/Settings/Diagnostics
└─ BeatRGBKit/               Swift package (all testable logic)
   ├─ Sources/BeatRGBKit/
   │  ├─ OpenRGB/            protocol, device description parser/encoder, socket client
   │  ├─ Audio/              process tap + input capture, ring buffer, FFT analyzer, envelopes
   │  ├─ Effects/            colour math, keyboard layout from matrix, settings, renderer
   │  ├─ Screen/             ScreenCaptureKit sampler
   │  ├─ Engine/             LightingEngine (render loop, reconnect, throttling), drivers, profiles
   │  ├─ Native/             Corsair V2 USB protocol + IOKit HID transport
   │  ├─ Resources/          K70 CORE RGB TKL key → slot map
   │  └─ Knob/               dial → volume
   └─ Tests/                 Swift Testing suites + real K70 fixtures
```

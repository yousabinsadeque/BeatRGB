# BeatRGB for Windows

Music- and screen-reactive lighting for **any RGB keyboard OpenRGB supports** on Windows 10 and 11.
It is a port of the macOS app's engine to C# / .NET 8, with the same 12 effects, 10 built-in profiles
and idle fades.

> **Status:** builds, and the engine passes 23 automated tests (including real controller data captured from a
> Corsair K70 and a simulated OpenRGB server). It has **not been run on a Windows PC yet**, so treat the first
> run as a test and report anything odd.

## Install

1. Install **[OpenRGB](https://openrgb.org)** and open it once so it detects your keyboard.
2. In OpenRGB, open the **SDK Server** tab and click **Start Server** (port 6742). To have it start by itself,
   enable *Start Server* in OpenRGB's settings, or start OpenRGB with `--server --startminimized`.
3. Quit the keyboard maker's lighting software (iCUE, Synapse, G HUB, SteelSeries GG, Armoury Crate),
   or turn off its lighting control. Only one program can drive the LEDs.
4. Download `BeatRGB-Windows-x64.zip` from the repository's **Releases** page (or the latest *Windows build*
   run under **Actions**), unzip it and run `BeatRGB.exe`. It is a single self-contained file, so nothing else needs
   installing. It isn't code-signed, so Windows SmartScreen may ask you to confirm (*More info → Run anyway*).
5. Click **Start sync** and play some music.

## What it does

* **System audio:** hears everything Windows plays through the default output device (WASAPI loopback), without
  changing playback. It never uses a microphone. It follows the default device when you switch outputs.
* **Keyboards:** drives the first keyboard OpenRGB reports that has a Direct (per-key) mode, or the device you pick
  on the *Keyboard* tab. You can lock it to that keyboard's serial number. Effects are laid out from OpenRGB's key
  map, so any size or layout works. Other devices are never touched.
* **Effects:** Audio Spectrum, Centre EQ, VU Meter, Bass Pulse, Beat Flash, Rainbow Music Wave,
  Full-Keyboard Reaction, Beat Ripple, Treble Sparkle, Bass Fire, Screen Mirror and Static Colour, with the same
  colour, speed, sensitivity, smoothing, noise gate and idle settings as on the Mac.
* **Screen Mirror:** samples the display you choose about 20 times a second (GDI, averaged down to 34×12) and
  paints the matching keys. It has a brightness and colour-boost control. Nothing is recorded.
* **Background mode:** closing the window keeps BeatRGB running in the notification area (near the clock).
  Right-click that icon to start or stop sync, open the window or quit. The *Background* tab can open BeatRGB
  with no window, start sync automatically, and launch it when you sign in (a per-user `Run` registry entry; no
  admin rights needed).
* **On stop or quit:** restores the colours the keyboard had before, shows the idle colour, or turns the lights
  off, as you choose. The same happens when you sign out or shut down.
* **Profiles and settings** are saved in `%APPDATA%\BeatRGB\profiles.json` and `settings.json`.

## Build from source

You need the [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0).

```powershell
cd windows
dotnet test BeatRGB.Core.Tests
dotnet run --project BeatRGB.Windows
```

To build the single-file `BeatRGB.exe`:

```powershell
dotnet publish BeatRGB.Windows -c Release -r win-x64 --self-contained true `
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true -o publish
```

GitHub Actions (`.github/workflows/windows.yml`) runs the tests and builds the zip on every push. Pushing a tag
such as `v1.0.0` also attaches the zip to a GitHub release.

`BeatRGB.Core` targets plain `net8.0`, so its tests also run on macOS and Linux. The app project builds on them
too (it sets `EnableWindowsTargeting`), but only runs on Windows.

## Differences from the Mac app

* OpenRGB is the only backend. The Mac app's native USB driver for the K70 CORE RGB TKL is macOS-only (IOKit).
* The K70's volume dial already works natively on Windows, so BeatRGB doesn't handle it.
* Audio comes from the default output device only (no input-device option).

## Layout

```
windows/
├─ BeatRGB.Core/          engine, no Windows dependencies
│  ├─ OpenRGB/            SDK protocol (v0–5), controller-data parser/encoder, socket client, device picker
│  ├─ Audio/              sample ring, FFT analyzer, envelopes, adaptive gain
│  ├─ Effects/            colour math, keyboard layout from OpenRGB's matrix, settings, renderer
│  └─ Engine/             LightingEngine (render loop, reconnect, throttling, restore on stop), profiles
├─ BeatRGB.Core.Tests/    xUnit tests + fake OpenRGB server
└─ BeatRGB.Windows/       WinForms app: main window, keyboard preview, tray icon, WASAPI capture, screen sampler
```

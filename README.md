# NVIDIA Audio APO Case Study and AudioModeTray

This repository contains:

- A technical case study of an NVIDIA recording-stutter issue caused by a
  third-party C-Media Audio Processing Object (APO).
- The AudioModeTray utility produced during the investigation.
- Source code, build scripts, a white icon, and a compiled executable.

The APO and driver remain installed. The utility bypasses the affected
endpoint's system effects and switches audio endpoint defaults without
repeatedly enabling and disabling the whole audio device.

## Features

- Speaker mode using the Realtek playback device.
- MCHOSE G9 headset mode using the G9 playback and capture endpoints.
- Desktop microphone mode for a future motherboard microphone.
- Only one microphone endpoint is active at a time.
- Login auto-start through Windows Task Scheduler.
- Automatic correction after audio-device changes.
- Native in-process switching with no PowerShell startup per hotkey.
- Global hotkeys:
  - `Ctrl + Win + Shift + Page Up`: speaker mode
  - `Ctrl + Win + Shift + Page Down`: G9 headset mode
- White multi-resolution speaker icon.
- Fully reversible endpoint configuration.

## Requirements

- Windows 11
- .NET Framework 4.8
- Administrator access for installing the tray task
- Realtek onboard audio and a MCHOSE G9 headset for the default profile

The source can be adapted to other endpoint names by changing the device
patterns in `src/AudioSwitchEngine.cs`.

## Install

Run PowerShell as Administrator:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install.ps1
```

The installer:

1. Builds the executable when `dist\AudioModeTray.exe` is missing.
2. Copies the executable and supporting scripts to
   `C:\ProgramData\AudioMode`.
3. Registers the `AudioModeTray` scheduled task at user logon.
4. Starts the tray application.

If the tray icon is hidden by Windows 11, open the notification-area
overflow menu and drag the icon onto the taskbar.

## Build

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build.ps1
```

Build output:

```text
dist\AudioModeTray.exe
dist\AudioModeTray.ico
dist\AudioModeTray-icon-preview.png
```

The executable is currently unsigned.

## Manual diagnostics

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Fast-Switch-AudioMode.ps1 -Mode Status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Set-G9SysFx.ps1 -State Status
```

`Set-G9SysFx.ps1` can disable or re-enable endpoint system effects:

```powershell
.\scripts\Set-G9SysFx.ps1 -State Disable
.\scripts\Set-G9SysFx.ps1 -State Enable
```

## Case study

The complete investigation is in
[`docs/case-study.md`](docs/case-study.md).

## Safety

- This project changes Windows audio endpoint defaults and endpoint
  enable states.
- It uses an elevated scheduled task because PnP endpoint changes require
  administrator privileges.
- It does not delete the headset driver or APO package.
- Back up relevant audio registry values before adapting the approach to
  other hardware.

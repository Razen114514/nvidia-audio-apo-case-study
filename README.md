# NVIDIA Recording Stutter Caused by a Headset APO

## Summary

A Windows 11 machine experienced stuttering while recording desktop video
with NVIDIA's recording feature. The user did not need microphone audio,
and microphone capture was disabled in both Windows and NVIDIA settings.

The symptom was not caused by microphone permission or by the recording
software itself. A third-party C-Media Audio Processing Object (APO)
installed for an MCHOSE G9 USB headset was loaded into the Windows audio
engine on the playback path. The faulty component crashed
`audiodg.exe`, causing repeated audio-engine restarts while recording.

The final fix preserved the APO package and audio driver. Only the
endpoint's unused system effects were bypassed. A small tray application
then switched between speaker and headset profiles in under a second.

## Environment

- Windows 11, build 26100
- NVIDIA RTX 5060
- Realtek onboard audio for desktop speakers
- MCHOSE G9 USB headset with C-Media audio driver and APO
- NVIDIA overlay recording
- No microphone input required for the recording workflow

## Initial Assumptions That Were Wrong

The first hypothesis was that NVIDIA was activating the microphone while
recording desktop video. This did not match the evidence:

- NVIDIA's microphone setting was already `off`.
- Instant Replay was disabled.
- The headset microphone endpoint was later disabled completely.
- Windows recorded no recent microphone access by NVIDIA.
- The recording stutter and `audiodg.exe` crashes continued.

Disabling or replacing the microphone was therefore not sufficient.

## Diagnostic Evidence

Windows Application Error events repeatedly reported `AUDIODG.EXE`
exiting with access violations and heap-corruption exceptions.

One crash directly identified:

```text
Faulting application: AUDIODG.EXE
Faulting module:     CmApoIce.dll
Exception code:      0xc0000005
```

Other crashes appeared as failures in `ntdll.dll` or `RPCRT64.dll`.
These are commonly where heap corruption is detected rather than where
the corruption was originally introduced.

The MCHOSE audio endpoint registry data showed that the C-Media effect
chain was still attached to the playback endpoint:

```text
PKEY_FX_*EffectClsid -> C-Media APO classes
```

The important distinction was:

- Disabling the headset microphone did not remove the playback APO.
- Keeping the headset playback endpoint enabled allowed the APO to remain
  reachable by the Windows audio engine.
- Mixed-device configurations made the failures especially repeatable.

## Root Cause

The failure chain was:

1. The Windows audio engine loaded the C-Media APO for the headset's
   playback endpoint.
2. NVIDIA recording created and manipulated desktop-audio streams.
3. The faulty APO corrupted heap state in `audiodg.exe`.
4. Windows restarted the audio engine.
5. Audio-engine teardown and restart caused visible recording stutter.

The microphone was incidental. The playback-side APO was the persistent
problem.

## Rejected Fixes

Several strategies were tested or investigated:

- Disabling microphone permission: insufficient.
- Turning off microphone capture in NVIDIA: insufficient.
- Disabling only the headset microphone endpoint: insufficient.
- Disabling and re-enabling the entire audio device for every mode:
  functionally effective but slow, taking roughly 10 to 20 seconds.
- Deleting the APO or driver package: unnecessary for the final solution.

## Final Fix

### Preserve the APO Package

The C-Media driver and APO files were left installed.

### Disable Endpoint System Effects

The Windows endpoint property
`PKEY_AudioEndpoint_Disable_SysFx` was set to `1` for the affected
headset endpoints.

The property is:

```text
GUID: {1da5d803-d492-4edd-8c23-e0c0ffee7f0e}
PID:  5
Type: VT_UI4
```

Setting the value to `1` disables the system-effect APO chain for that
endpoint. This is the same setting exposed by Windows audio
enhancements controls.

The Windows Audio service was restarted after applying the setting so
the audio engine reloaded its endpoint configuration.

### Keep the Audio Devices Available

The application no longer disables the entire headset for every mode
switch. Both playback devices remain available, which removes the slow
device-enumeration path from normal switching.

Only microphone endpoints are made mutually exclusive:

- Speaker mode: Realtek output, headset microphone disabled.
- Headset mode: MCHOSE G9 input and output, Realtek microphone disabled.

### Fast Native Switching

The tray application now performs switching in-process using:

- Direct endpoint metadata reads from the Windows MMDevices registry.
- `pnputil` for fast endpoint enable and disable operations.
- Core Audio `IPolicyConfig` calls for default-device selection.
- The same policy API to set `Disable_SysFx`.

Measured timings on the affected machine:

```text
Native profile apply:     approximately 0.08 to 0.16 seconds
Hotkey-triggered apply:   approximately 0.16 to 0.32 seconds
```

## Final UX

The tray application provides:

- Speaker mode.
- G9 headset mode.
- Desktop microphone mode for a future motherboard microphone.
- Current-mode indicators.
- Automatic correction after audio-device changes.
- Login auto-start.

Global shortcuts:

```text
Ctrl + Win + Shift + Page Up    -> Speaker mode
Ctrl + Win + Shift + Page Down  -> Headset mode
```

The application uses a simple white speaker icon with a transparent
background.

## Verification

After applying the endpoint effect override:

- `Disable_SysFx` read back as `1`.
- The C-Media APO file remained present and unchanged.
- The headset playback endpoint remained enabled.
- The headset microphone was disabled in speaker mode.
- The Realtek playback endpoint remained the default output.
- No new `AUDIODG.EXE` crash events occurred during the test period.
- The audio engine kept the same process ID for the remainder of the
  test.

The user also completed a recording test and reported that the previous
stutter was no longer present.

## Lessons

1. A microphone issue is not always a microphone-capture issue.
2. Check render endpoints as well as capture endpoints when
   `audiodg.exe` crashes.
3. An APO can remain reachable even when its microphone endpoint is
   disabled.
4. A crash in `ntdll.dll` or an RPC DLL can be a downstream symptom of
   heap corruption introduced by another loaded module.
5. Keep the APO package when possible and use the documented endpoint
   effect override first.
6. Avoid enabling and disabling an entire audio device for routine
   profile switching. Cache endpoint identity and use targeted endpoint
   operations.
7. Treat driver updates and device re-enumeration as conditions that may
   reset endpoint settings, and verify them again after such events.

## Reversibility

The effect override is reversible:

- Set `PKEY_AudioEndpoint_Disable_SysFx` back to `0`.
- Restart the Windows Audio service.
- The installed APO and driver remain available.

Endpoint state changes can also be reversed with standard Windows PnP
enable and disable operations.

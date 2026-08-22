# Release and packaging notes

NTE Piano MIDI Player is distributed as an unsigned macOS app bundle for the NTE in-game piano. This document is a maintainer checklist; preparing or publishing a new release still requires an explicit version/release task.

## Build and test

Run the shared Xcode scheme on macOS:

```sh
xcodebuild \
  -project NTEPianoMidiPlayer.xcodeproj \
  -scheme NTEPianoMidiPlayer \
  -destination 'platform=macOS' \
  test

xcodebuild \
  -project NTEPianoMidiPlayer.xcodeproj \
  -scheme NTEPianoMidiPlayer \
  -configuration Release \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build

scripts/build_app.sh
git diff --check
```

The packaging script produces:

- `dist/NTE Piano MIDI Player.app`
- `dist/NTE-Piano-MIDI-Player-macOS-unsigned.zip`

It also verifies that the pinned Karabiner submodule is initialized, the bundled `Contents/Helpers/NTEVirtualHIDBridge` passes its protocol self-test, and the bridge contains arm64 and x86_64 slices.

## QA checklist

1. Delete `UserDefaults` for `dev.enka.NTEPianoMidiPlayer` and remove any installed LaunchDaemons, then launch: the Setup Assistant must appear, each step must advance itself as its condition is detected, and installing background services must cost exactly one administrator prompt.
2. From the Setup Assistant, choose "Skip — use 21-key natural instead" and confirm 21-key playback works through Accessibility alone, with no administrator prompt.
3. Confirm Automatic arrangement, Preview Mode, and Listen/Speaker Playback on representative format-0 and multi-track format-1 MIDI files.
4. Confirm 21-key input uses exactly `QWERTYU`, `ASDFGHJ`, and `ZXCVBNM` without modifiers.
5. Confirm Settings → General → Setup reports Ready; verify the natural, Shift, and Ctrl layers, compatible simultaneous chords, and a slow exact cross-layer roll in 36-key mode via Advanced settings' calibration buttons.
6. Confirm a rapid cross-layer passage omits lower-priority tones without semitone changes, then verify the layer calibration visibly performs natural → Flat → natural → Sharp → natural and releases modifiers correctly.
7. Confirm Original arrangement remains available for diagnostic comparison in Advanced settings.
8. Confirm stop, focus loss, app quit, bridge disconnect, and heartbeat timeout release every held letter key and modifier.
9. Replay a known-good 21-key MIDI and confirm its Quartz behavior is unchanged.
10. Confirm the main window shows no diagnostics or counters with Advanced settings off, even for a file the arranger heavily folds or snaps; confirm the countdown overlay renders at the configured duration and can be cancelled.
11. Confirm "Remove Helper Services" boots out and deletes both LaunchDaemons; on a machine with a full Karabiner-Elements install, confirm its LaunchDaemon is left untouched.
12. Launch the packaged app and verify its generated Info.plist, app icon, embedded core framework, universal bridge, and macOS 26 deployment target.

## Unsigned app warning

The app is not signed with an Apple Developer ID and is not notarized. After moving it to `/Applications`, macOS may require:

```sh
xattr -dr com.apple.quarantine "/Applications/NTE Piano MIDI Player.app"
open "/Applications/NTE Piano MIDI Player.app"
```

Only remove quarantine from an official release or a locally reviewed build. Some macOS versions may also require Open Anyway in Privacy & Security. Accessibility permission is needed for 21-key live injection and the event recorder, while 36-key live injection uses the separately approved VirtualHID system extension — the Setup Assistant requests each as needed. Preview Mode, speaker playback, inspection, and export work without either live backend.

## Scope and safety

Automatic arrangement is a deterministic best-effort reduction for NTE's physical keyboard. Automatic 36-key playback rolls cross-layer chords exactly only when the timing budget permits and otherwise omits lower-priority tones without semitone substitution. It cannot reproduce unsupported dynamics, pitch bend, or arbitrary ranges. The app does not read process memory or bypass anti-cheat. Using automation in an online game may violate its rules or terms of service.

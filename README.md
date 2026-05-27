# NTE Piano MIDI Player

NTE Piano MIDI Player is an original native macOS MIDI-to-keyboard auto-player for the in-game piano in Neverness to Everness / NTE. It loads `.mid` and `.midi` files, maps MIDI notes to the NTE piano keyboard layouts, and can either dry-run the generated key events or send normal synthetic keyboard events with CoreGraphics.

This project is inspired by the general idea of MIDI-to-game-instrument tools, but it is a clean SwiftUI/CoreGraphics implementation for the NTE piano mapping.

## Requirements

- macOS 13 or newer
- Swift 5.9 or newer
- Full Xcode is recommended for app development. This repo is SwiftPM-based, so it can also be opened as a package.
- Accessibility permission is required only for real key injection. Dry-run playback, MIDI inspection, and sheet export work without it.

## Build

```sh
swift build
swift test
swift run NTEPianoMidiPlayer
```

If `xcodebuild` reports that only Command Line Tools are selected, install/select full Xcode before using Xcode-specific workflows.

## Accessibility Permission

The app sends keyboard events with Quartz/CoreGraphics `CGEvent`. macOS blocks this unless the app is trusted for Accessibility.

1. Open System Settings.
2. Go to Privacy & Security > Accessibility.
3. Add/enable the built app or terminal host used to run it.
4. Restart the app if macOS does not apply the permission immediately.

The Settings window includes a button that opens the Accessibility pane.

## Basic Use

1. Open or drag in a `.mid` / `.midi` file.
2. Enable, mute, or solo tracks.
3. Choose `21-key natural` or `36-key chromatic`.
4. Adjust transpose, octave, tempo, countdown, range handling, and dry-run mode.
5. Press Play.
6. During the countdown, focus the NTE window and open the in-game piano.
7. The app stops if the frontmost app is no longer an accepted NTE app name.

Accepted foreground app names default to:

- `NTE.app`
- `NTE`
- `Neverness to Everness`

You can add or change names in Settings.

## NTE Layouts

### 21-Key Natural Layout

This mode plays C-major natural notes only.

| Row | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| TRE | Q | W | E | R | T | Y | U |
| MID | A | S | D | F | G | H | J |
| BAS | Z | X | C | V | B | N | M |

By default, accidentals are approximated with neighboring natural keys so more MIDI notes remain playable, for example `C# -> C+D`, `Eb -> D+E`, `F# -> F+G`, `G# -> G+A`, and `Bb -> A+B`. You can disable multi-key approximation to return to skip/snap behavior.

### 36-Key Chromatic Layout

This mode can map all 12 semitones per octave. Because NTE may not reliably honor synthetic Shift/Ctrl events on every Mac/game setup, the default is neighbor approximation for accidentals. You can switch accidentals back to exact Shift/Ctrl mappings in Settings.

| Degree | BAS | MID | TRE |
| --- | --- | --- | --- |
| 1 / C | Z | A | Q |
| #1 / C# | Shift+Z | Shift+A | Shift+Q |
| 2 / D | X | S | W |
| b3 / Eb | Ctrl+C | Ctrl+D | Ctrl+E |
| 3 / E | C | D | E |
| 4 / F | V | F | R |
| #4 / F# | Shift+V | Shift+F | Shift+R |
| 5 / G | B | G | T |
| #5 / G# | Shift+B | Shift+G | Shift+T |
| 6 / A | N | H | Y |
| b7 / Bb | Ctrl+M | Ctrl+J | Ctrl+U |
| 7 / B | M | J | U |

The default MIDI range is:

- BAS 1 = MIDI C3 / 48
- MID 1 = MIDI C4 / 60
- TRE 1 = MIDI C5 / 72

The BAS base note is configurable. MID and TRE automatically follow at +12 and +24 semitones.

## Features

- MIDI loading with track names, channels, programs, note counts, tempo, time signatures, and tempo-aware timing.
- Track enable, mute, solo, and search.
- 21-key and 36-key NTE mapping.
- Multi-key approximation for accidentals and folded out-of-range notes.
- Configurable Shift/Ctrl injection strategies with calibration buttons.
- Transpose, octave shift, source/target key settings, and range diagnostics.
- Dry-run mode that logs intended mappings such as `C# -> Z+X`.
- CGEvent keyboard injection with Accessibility checks.
- Foreground-app safety check before each note group.
- Manual keyboard remapping in Settings.
- Pause, resume, stop, seek/progress, tempo multiplier, and countdown.
- AVMIDIPlayer speaker preview separate from key injection.
- Visual NTE keyboard preview.
- Piano sheet exporter with note names, scale degrees, keyboard keys, delimiters, line length, and chord brackets.
- Settings and recent files persisted with UserDefaults.

## Safety and Game Rules

This app does not read process memory, bypass anti-cheat, hide itself, or automate anything outside user-triggered keyboard playback. It only sends normal synthetic keyboard events while the accepted NTE app is foregrounded.

Using automation in online games may violate game rules or terms of service. Use this at your own risk.

## Known Limitations

- Live MIDI input is deferred from the MVP.
- Playlist queue polish is deferred from the MVP.
- The emergency stop shortcut is available while the app can receive keyboard commands; a full global hotkey can be added later if needed.
- The SwiftPM executable is convenient for development; a polished distributable `.app` bundle should be produced with Xcode once full Xcode is installed and selected.

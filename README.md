# NTE Piano MIDI Player

NTE Piano MIDI Player is a native macOS MIDI-to-keyboard player for the in-game piano in Neverness to Everness (NTE). It loads Standard MIDI files, arranges them for NTE's limited physical keyboard, and either previews or posts the resulting key chords through the layout's supported macOS input backend.

The project is an original SwiftUI implementation. It does not read game memory, bypass anti-cheat, or hide its input automation.

## Requirements

- macOS 26 or newer
- Xcode with the macOS SDK, to build from source
- Accessibility permission for 21-key live playback (the app's Setup Assistant asks for this when needed)
- Karabiner DriverKit VirtualHIDDevice 8.2.0 (or a compatible Karabiner-Elements install) for 36-key live playback — the Setup Assistant walks you through installing it and can set up the background services itself with one administrator prompt

Preview Mode, MIDI inspection, Listen/Speaker Playback, and sheet export do not request Accessibility access.

## Develop and test

Open `NTEPianoMidiPlayer.xcodeproj` in Xcode and use the shared `NTEPianoMidiPlayer` macOS scheme. The scheme builds the app, `NTEPianoMidiPlayerCore` framework, and unit tests.

Clone with submodules, or initialize the pinned dependency before building:

```sh
git submodule update --init --recursive
```

The equivalent command-line checks are:

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
```

## Build the unsigned app

Run:

```sh
scripts/build_app.sh
```

The script uses `xcodebuild` and writes:

- `dist/NTE Piano MIDI Player.app`
- `dist/NTE-Piano-MIDI-Player-macOS-unsigned.zip`

The app is intentionally unsigned and not notarized. After downloading an official release, macOS may require:

```sh
xattr -dr com.apple.quarantine "/Applications/NTE Piano MIDI Player.app"
open "/Applications/NTE Piano MIDI Player.app"
```

Only remove quarantine from a copy downloaded from the official repository or built locally from reviewed source. Some macOS versions may also require Open Anyway in Privacy & Security.

## Basic use

On first launch, the Setup Assistant walks you through installing the virtual keyboard driver (or skipping it for 21-key natural mode) and, if you want 36-key playback, installs its background services with one administrator prompt. After that:

1. Open or drag in a `.mid` or `.midi` file.
2. Press Play.
3. When the countdown appears, switch to NTE and open the in-game piano before it reaches zero.

That's the whole flow. Track enable/mute/solo and the Listen (speaker preview) button stay on the main window; everything else — arrangement mode, transpose, layout, timing, manual key remapping, and diagnostics — lives behind **Settings → Enable Advanced Developer Settings**, off by default so the app plays without asking you to understand any of it. Re-run the Setup Assistant any time from **Help → Setup Assistant** or the Settings General tab.

Preview Mode (available in Advanced settings) runs the complete arrangement without sending any input, for inspecting a file before you commit to a countdown.

## 36-key VirtualHID setup

NTE accepts physical Shift and Control but rejects equivalent Quartz modifier state. Therefore, all 36-key letters and modifiers are sent through one virtual hardware keyboard: the standalone [Karabiner DriverKit VirtualHIDDevice 8.2.0](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/releases/tag/v8.2.0) (a compatible driver bundled with a full Karabiner-Elements install also works, since both share the same install path), plus this app's own bridge that relays key presses to it.

The **Setup Assistant** (shown on first launch, and reachable any time from Help → Setup Assistant) walks through this automatically:

1. **Install the driver** — opens the official release page; the assistant detects installation live.
2. **Approve the extension** — one click activates it, then approve it in System Settings if macOS prompts.
3. **Set up background services** — installs a LaunchDaemon for Karabiner's own daemon (skipped if one is already present, so a full Karabiner-Elements install is never touched) and one for this app's bridge, so both start automatically at login. This is the one step that needs an administrator password, asked once.

You can skip driver installation entirely and use 21-key natural mode instead, which needs only Accessibility permission and no background services. **Settings → General → Setup** shows live readiness and has a **Remove Helper Services** button that uninstalls both LaunchDaemons.

If the administrator prompt isn't available on your Mac, the Setup Assistant's background-services step reveals the equivalent manual commands to run in Terminal:

```sh
'/Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Manager' activate
sudo '/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Daemon'
sudo '/Applications/NTE Piano MIDI Player.app/Contents/Helpers/NTEVirtualHIDBridge' --allowed-uid "$(id -u)"
```

The bridge runs as root because the upstream driver requires it, but accepts only one authenticated local user and only the 21 piano letters, left Shift, and left Control. It releases the keyboard on disconnect or heartbeat timeout. There is no silent Quartz fallback when 36-key VirtualHID is unavailable.

## Arrangement modes

### Automatic

Automatic is the default and applies one deterministic best-effort pipeline to every parseable Standard MIDI file. It:

- applies tempo changes and sustain-pedal duration extensions;
- omits General MIDI percussion channel 10;
- groups nearby onsets into real chords;
- evaluates bounded global transpositions while minimizing total register movement;
- generates fixed single-layer and two-layer candidates for each 36-key onset;
- keeps compatible chords simultaneous, rolls slow cross-layer chords exactly, and reduces fast cross-layer chords without introducing wrong pitches;
- favors melody, bass, velocity, duration, pitch-class diversity, register continuity, and fewer layer switches;
- octave-folds wide ranges, removes collisions, and enforces one six-note budget across every source onset;
- merges impractically rapid retriggers; and
- reports transposes, folds, exact rolls, timing reductions, merges, percussion omissions, unsupported expression events, and omitted chord tones.

Work is bounded to sorting plus fixed-size candidate evaluation (`O(N log N)` time and `O(N)` memory). Import arrangement runs away from the main actor and uses cancellation/generation tokens so a superseded import cannot publish stale results.

### Original

Original is a diagnostic comparison path. It retains the selected tracks, including channel 10, and bypasses automatic global fitting and musical reduction where possible. It still obeys the chosen NTE layout, one-layer-per-chord rule, range safety, collision removal, and simultaneous-key limit because the game cannot reproduce impossible inputs.

NTE cannot reproduce arbitrary MIDI ranges, velocity dynamics, or pitch bend. Automatic 36-key mode can represent a cross-layer chord as a short exact roll only when the next onset leaves enough time; otherwise it omits lower-priority tones. Both modes therefore remain best-effort rather than claiming note-for-note reproduction.

## NTE layouts

All three physical rows are fixed:

| Row | Keys |
| --- | --- |
| TRE | `QWERTYU` |
| MID | `ASDFGHJ` |
| BAS | `ZXCVBNM` |

### 21-key natural

The seven positions on every row are C, D, E, F, G, A, B. This mode never uses Shift or Ctrl and never expands an accidental into two neighboring notes. Automatic mode can chromatically transpose a song within ±24 semitones to maximize natural-note coverage before octave fitting or one-semitone snapping.

### 36-key chromatic

The keyboard provides these three layers:

| Layer | Seven positions on each row |
| --- | --- |
| No modifier | C, D, E, F, G, A, B |
| Shift | C#, D, E, F#, G#, A, B |
| Ctrl | C, D, Eb, F, G, A, Bb |

The corresponding bindings are:

| Pitch position | BAS | MID | TRE |
| --- | --- | --- | --- |
| C | Z | A | Q |
| C# | Shift+Z | Shift+A | Shift+Q |
| D | X | S | W |
| Eb | Ctrl+C | Ctrl+D | Ctrl+E |
| E | C | D | E |
| F | V | F | R |
| F# | Shift+V | Shift+F | Shift+R |
| G | B | G | T |
| G# | Shift+B | Shift+G | Shift+T |
| A | N | H | Y |
| Bb | Ctrl+M | Ctrl+J | Ctrl+U |
| B | M | J | U |

The default MIDI range starts at BAS C3 (MIDI 48); MID and TRE begin one and two octaves above it. Automatic 36-key fitting searches octave-preserving shifts within ±24 semitones, but prefers the shift with the least total movement from the requested register.

Compatible chords press all letter keys at the same time. When a chord needs two layers, Automatic mode schedules an exact roll only if the required tap, release, gap, and modifier-lead time fit before the next onset. Rapid passages stay on one layer and omit incompatible lower-priority tones rather than moving them by a semitone. The scheduler releases letter keys before changing layers, while complete hardware reports and held-key reference counts prevent overlapping notes from releasing one another. The effective 36-key budget is six notes per source onset, even when those notes are divided between two packets; a higher saved preference remains available to 21-key arrangement.

## Safety and cleanup

21-key live playback requires Accessibility permission. VirtualHID 36-key playback does not, although the optional input-event recorder still does. Both live paths require one of these foreground app names by default:

- `NTE.app`
- `NTE`
- `Neverness to Everness`

All held letter keys and modifiers are released on stop, focus loss, cancellation, completion, or error. Using automation in an online game may violate its rules or terms of service; use it at your own risk.

The in-game piano is at Hethereau Skytower in the Miguel District; take the elevator to the restaurant.

### Input-event diagnostics

With **Enable Advanced Developer Settings** on, the Input Event Recorder below Range Diagnostics compares physical keyboard input with events injected by the player. Start recording, physically hold left Shift and left Control in NTE, then run the two-second Hold Shift and Hold Ctrl calibrations. Stop recording and use Copy Trace. `PLAYER` identifies Quartz events tagged by this app. VirtualHID travels through the hardware path and may appear as `EXTERNAL` with `pid=0`, so correlate it with the separate VirtualHID report trace. The recorder captures only Shift, Control, and the 21 piano letter keys, is capped at 500 events, and requires Accessibility permission; it does not require Input Monitoring access.

## Other features

- Track search, enable, mute, and solo controls (visible on the main window)
- Listen (speaker preview) using `AVMIDIPlayer`, separate from key injection (visible on the main window)
- Countdown before playback (3s / 5s / 7s / 10s / 15s, in Settings → General), Liquid Glass opacity, and light/dark/system appearance in Settings → General
- Tempo multiplier, pause/resume, progress, visual keyboard preview, and transformation diagnostics (Advanced)
- Manual keyboard remapping and modifier calibration (Advanced)
- Piano-sheet export with note names, degrees, key labels, line wrapping, and chord brackets (Advanced, and via the File menu)
- Persistent settings and recent files (File → Open Recent) through the existing UserDefaults domain

## Known limitations

- MIDI dynamics, pitch bends, aftertouch, and other unsupported expression data are reported but not reproduced.
- Dense or cross-layer chords may be octave-folded, rolled, deduplicated, or reduced to the physical key and timing limits. Automatic 36-key mode does not semitone-snap; Original and 21-key comparison behavior is unchanged.
- Live MIDI input, playlist polish, a system-wide emergency hotkey, and Windows support are outside the current scope.
- Release ZIPs are unsigned and unnotarized, so manual macOS approval may be required.

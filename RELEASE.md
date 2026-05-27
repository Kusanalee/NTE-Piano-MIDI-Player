# NTE Piano MIDI Player v0.1.0

This release contains an unsigned macOS app bundle for the NTE in-game piano MIDI auto-player.

## Download

Download `NTE-Piano-MIDI-Player-macOS-unsigned.zip` from the GitHub Release, unzip it, and move `NTE Piano MIDI Player.app` to Applications.

## Unsigned App Warning

This app is not signed with an Apple Developer ID and is not notarized. On first launch, macOS may say `"NTE Piano MIDI Player" is damaged and can’t be opened. You should move it to the Trash.`

To open it after moving the app to `/Applications`, run:

```sh
xattr -dr com.apple.quarantine "/Applications/NTE Piano MIDI Player.app"
open "/Applications/NTE Piano MIDI Player.app"
```

Only run this for a copy downloaded from the official GitHub Release or built locally from this source code. The command tells macOS to stop treating the app bundle as a quarantined internet download. If you keep the app somewhere other than `/Applications`, change the path in both commands.

Some macOS versions may still show a Privacy & Security prompt with an Open Anyway button. If that appears after removing quarantine, approve it there.

After the app opens, enable Accessibility permission in System Settings > Privacy & Security > Accessibility so the app can send keyboard events to NTE. Dry-run and sheet export work without Accessibility permission.

## Notes

- This release targets macOS 13 or newer.
- The default accidental mode uses neighbor approximation. Use Settings to test exact Shift/Ctrl mode.
- The app does not read process memory, bypass anti-cheat, or run stealth automation.
- Using automation in online games may violate game rules or terms of service. Use at your own risk.

## Maintainer Checklist

1. Run `swift test`.
2. Run `scripts/build_app.sh`.
3. Verify `dist/NTE Piano MIDI Player.app` launches.
4. Upload `dist/NTE-Piano-MIDI-Player-macOS-unsigned.zip` to the GitHub Release.

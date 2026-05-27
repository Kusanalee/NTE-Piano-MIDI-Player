# NTE Piano MIDI Player v0.1.0

This release contains an unsigned macOS app bundle for the NTE in-game piano MIDI auto-player.

## Download

Download `NTE-Piano-MIDI-Player-macOS-unsigned.zip` from the GitHub Release, unzip it, and move `NTE Piano MIDI Player.app` to Applications.

## Unsigned App Warning

This app is not signed with an Apple Developer ID and is not notarized. On first launch, macOS Gatekeeper may block it.

To open it:

1. Try opening the app once.
2. Open System Settings > Privacy & Security.
3. Scroll to the security warning for `NTE Piano MIDI Player.app`.
4. Click Open Anyway.
5. Confirm the prompt.

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

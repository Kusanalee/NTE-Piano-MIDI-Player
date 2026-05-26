import NTEPianoMidiPlayerCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()

            Divider()

            Form {
                Section("Layout and Range") {
                    Picker("Layout", selection: binding(\.layoutMode)) {
                        ForEach(LayoutMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    Stepper("Base MIDI note for BAS 1: \(settingsStore.settings.baseMidiNoteForBAS1)", value: binding(\.baseMidiNoteForBAS1), in: 0...92)
                    Text("MID 1: \(settingsStore.settings.midiNoteForMID1), TRE 1: \(settingsStore.settings.midiNoteForTRE1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("21-key handling", selection: binding(\.naturalScaleHandling)) {
                        ForEach(NaturalScaleHandling.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    Picker("Auto-fit", selection: binding(\.autoFitMode)) {
                        ForEach(AutoFitMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                }

                Section("Transpose") {
                    Stepper("Global transpose: \(settingsStore.settings.globalTranspose)", value: binding(\.globalTranspose), in: -24...24)
                    Stepper("Octave shift: \(settingsStore.settings.octaveShift)", value: binding(\.octaveShift), in: -3...3)
                    Toggle("Use source/target key transposition", isOn: binding(\.keyTranspositionEnabled))
                    Picker("Source key", selection: binding(\.sourceKey)) {
                        ForEach(MusicalKey.allCases) { key in
                            Text(key.rawValue).tag(key)
                        }
                    }
                    Picker("Target key", selection: binding(\.targetKey)) {
                        ForEach(MusicalKey.allCases) { key in
                            Text(key.rawValue).tag(key)
                        }
                    }
                }

                Section("Playback Timing") {
                    labeledSlider("Tempo", value: binding(\.tempoMultiplier), range: 0.25...2.0, suffix: "x")
                    labeledSlider("Countdown", value: binding(\.countdownDuration), range: 0...10, suffix: "s")
                    labeledSlider("Tap duration", value: binding(\.tapDuration), range: 0.005...0.250, suffix: "s")
                    labeledSlider("Chord threshold", value: binding(\.chordThreshold), range: 0.001...0.100, suffix: "s")
                    labeledSlider("Chord stagger", value: binding(\.chordStagger), range: 0...0.050, suffix: "s")
                    labeledSlider("Merge threshold", value: binding(\.mergeThreshold), range: 0...0.100, suffix: "s")
                    Toggle("Hold sustained notes", isOn: binding(\.holdSustainedNotes))
                    labeledSlider("Max hold", value: binding(\.maxHoldDuration), range: 0.050...10.0, suffix: "s")
                    Stepper("Simultaneous key limit: \(settingsStore.settings.simultaneousKeyLimit)", value: binding(\.simultaneousKeyLimit), in: 1...12)
                }

                Section("Safety") {
                    Toggle("Dry-run mode", isOn: binding(\.dryRun))
                    Picker("Emergency stop", selection: binding(\.emergencyStopHotkey)) {
                        ForEach(EmergencyStopHotkey.allCases) { hotkey in
                            Text(hotkey.displayName).tag(hotkey)
                        }
                    }
                    TextField("Accepted foreground app names", text: acceptedAppNamesBinding)
                    Button("Open Accessibility Settings", action: viewModel.openAccessibilitySettings)
                }

                Section("Appearance") {
                    Picker("Theme", selection: binding(\.themePreference)) {
                        ForEach(ThemePreference.allCases) { theme in
                            Text(theme.rawValue.capitalized).tag(theme)
                        }
                    }
                }

                Section("Manual Key Remap") {
                    ForEach(PianoRow.allCases) { row in
                        DisclosureGroup(row.rawValue) {
                            ForEach(keys(for: row)) { key in
                                Picker("\(key.degreeLabel) / \(key.noteName)", selection: overrideBinding(for: key)) {
                                    ForEach(KeyboardKey.allCases) { keyboardKey in
                                        Text(keyboardKey.rawValue).tag(keyboardKey)
                                    }
                                }
                            }
                        }
                    }
                    Button("Clear manual remaps") {
                        settingsStore.settings.manualKeyOverrides = [:]
                    }
                }

                Section("Recent Files") {
                    if settingsStore.recentFiles.isEmpty {
                        Text("No recent files yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(settingsStore.recentFiles, id: \.self) { url in
                            Button(url.lastPathComponent) {
                                viewModel.load(url: url)
                            }
                        }
                    }
                }

                Section {
                    Button("Reset Settings") {
                        settingsStore.resetSettings()
                    }
                }
            }
            .formStyle(.grouped)
            .padding()
        }
    }

    private var acceptedAppNamesBinding: Binding<String> {
        Binding(
            get: { settingsStore.settings.acceptedForegroundAppNames.joined(separator: ", ") },
            set: { value in
                settingsStore.settings.acceptedForegroundAppNames = value
                    .split(separator: ",")
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<PlaybackSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settingsStore.settings[keyPath: keyPath] },
            set: { settingsStore.settings[keyPath: keyPath] = $0 }
        )
    }

    private func keys(for row: PianoRow) -> [PianoKey] {
        NTELayout.keys(
            for: settingsStore.settings.layoutMode,
            baseMidiNote: settingsStore.settings.baseMidiNoteForBAS1
        )[row] ?? []
    }

    private func overrideBinding(for key: PianoKey) -> Binding<KeyboardKey> {
        let overrideKey = "\(key.row.rawValue).\(key.semitone)"
        return Binding(
            get: { settingsStore.settings.manualKeyOverrides[overrideKey] ?? key.keyboardKey },
            set: { newValue in
                if newValue == key.keyboardKey {
                    settingsStore.settings.manualKeyOverrides.removeValue(forKey: overrideKey)
                } else {
                    settingsStore.settings.manualKeyOverrides[overrideKey] = newValue
                }
            }
        )
    }

    private func labeledSlider(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        suffix: String
    ) -> some View {
        HStack {
            Text("\(label): \(String(format: "%.3g", value.wrappedValue))\(suffix)")
                .frame(width: 150, alignment: .leading)
            Slider(value: value, in: range)
        }
    }
}

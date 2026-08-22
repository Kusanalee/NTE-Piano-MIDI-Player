import NTEPianoMidiPlayerCore
import SwiftUI

/// The Settings scene. General is the entire surface a non-technical user should ever need;
/// Advanced only renders once "Enable Advanced Developer Settings" is on, and holds every
/// knob that assumes music-theory or timing knowledge (transpose, chord threshold, layer
/// switch gap, and so on).
struct SettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        TabView {
            GeneralSettingsTab(settingsStore: settingsStore, viewModel: viewModel)
                .tabItem { Label("General", systemImage: "gearshape") }

            if settingsStore.settings.advancedSettingsEnabled {
                AdvancedSettingsTab(settingsStore: settingsStore, viewModel: viewModel)
                    .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
            }
        }
        .frame(width: 560, height: 520)
        .onAppear { viewModel.startReadinessPolling() }
        .onDisappear { viewModel.stopReadinessPolling() }
        .preferredColorScheme(settingsStore.settings.themePreference.colorScheme)
    }
}

private struct GeneralSettingsTab: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var viewModel: AppViewModel
    @State private var showingRemoveConfirmation = false

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: binding(\.themePreference)) {
                    ForEach(ThemePreference.allCases) { theme in
                        Text(theme.rawValue.capitalized).tag(theme)
                    }
                }
                HStack {
                    Text("Glass opacity")
                    Slider(value: binding(\.glassOpacity), in: 0.35...1.0)
                    Text("\(Int(settingsStore.settings.glassOpacity * 100))%")
                        .frame(width: 44, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Countdown before playing", selection: binding(\.countdownDuration)) {
                    ForEach(PlaybackSettings.countdownOptions, id: \.self) { seconds in
                        Text("\(Int(seconds))s").tag(seconds)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Gives you time to switch to NTE and open the in-game piano before playback starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Setup") {
                Picker(
                    "Key layout",
                    selection: Binding(
                        get: { settingsStore.settings.layoutMode },
                        set: { viewModel.setLayoutMode($0) }
                    )
                ) {
                    ForEach(LayoutMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Label(readinessTitle, systemImage: viewModel.readiness.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(viewModel.readiness.isReady ? .green : .orange)
                if let detail = viewModel.readiness.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Open Setup Assistant") { viewModel.showingOnboarding = true }
                    Button("Remove Helper Services") { showingRemoveConfirmation = true }
                        .disabled(!PrivilegedServiceInstaller.isInstalled())
                }
                if let error = viewModel.setupActionError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .confirmationDialog(
                "Remove the background services?",
                isPresented: $showingRemoveConfirmation,
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive, action: viewModel.removePrivilegedServices)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("36-key playback will stop working until you run Setup Assistant again.")
            }

            Section {
                Toggle("Enable Advanced Developer Settings", isOn: binding(\.advancedSettingsEnabled))
            } footer: {
                Text("Exposes transpose, timing, and layer tuning that can break playback if changed incorrectly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var readinessTitle: String {
        viewModel.readiness.isReady ? "Ready to play" : (viewModel.readiness.blockingStep?.title ?? "Setup needed")
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<PlaybackSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settingsStore.settings[keyPath: keyPath] },
            set: { settingsStore.settings[keyPath: keyPath] = $0 }
        )
    }
}

private struct AdvancedSettingsTab: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        Form {
            Section("Layout and Range") {
                Picker("Arrangement", selection: binding(\.arrangementMode)) {
                    ForEach(ArrangementMode.allCases) { mode in
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
                HStack {
                    Text("Tempo: \(String(format: "%.2fx", settingsStore.settings.tempoMultiplier))")
                        .frame(width: 150, alignment: .leading)
                    Slider(value: binding(\.tempoMultiplier), in: 0.25...2.0)
                }
            }

            Section("Playback Timing") {
                labeledSlider("Tap duration", value: binding(\.tapDuration), range: 0.005...0.250, suffix: "s")
                labeledSlider("Chord threshold", value: binding(\.chordThreshold), range: 0.001...0.100, suffix: "s")
                labeledSlider("Chord stagger", value: binding(\.chordStagger), range: 0...0.050, suffix: "s")
                labeledSlider("Merge threshold", value: binding(\.mergeThreshold), range: 0...0.100, suffix: "s")
                Toggle("Hold sustained notes", isOn: binding(\.holdSustainedNotes))
                labeledSlider("Max hold", value: binding(\.maxHoldDuration), range: 0.050...10.0, suffix: "s")
                Stepper("Simultaneous key limit: \(settingsStore.settings.simultaneousKeyLimit)", value: binding(\.simultaneousKeyLimit), in: 1...12)
                if settingsStore.settings.layoutMode == .nte36Chromatic,
                   settingsStore.settings.simultaneousKeyLimit > VirtualHIDConstants.maximumKeys {
                    Text("36-key VirtualHID playback uses an effective limit of \(VirtualHIDConstants.maximumKeys). The higher preference remains available for 21-key playback.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("36-Key VirtualHID") {
                Label(
                    viewModel.virtualHIDStatus.title,
                    systemImage: viewModel.virtualHIDStatus.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(viewModel.virtualHIDStatus.isReady ? .green : .orange)
                Text(viewModel.virtualHIDStatus.guidance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Pinned dependency: Karabiner DriverKit VirtualHIDDevice \(VirtualHIDConstants.expectedPackageVersion), driver \(VirtualHIDConstants.expectedDriverVersion), protocol \(VirtualHIDConstants.expectedClientProtocolVersion).")
                    .font(.caption)
                HStack {
                    Button("Refresh Status", action: viewModel.refreshVirtualHIDStatus)
                    Button("Open Official Release", action: viewModel.openVirtualHIDReleasePage)
                    Button("Copy Setup Commands", action: viewModel.copyVirtualHIDSetupCommands)
                }
                ScrollView(.horizontal) {
                    Text(viewModel.virtualHIDSetupCommands)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(6)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Section("Safety") {
                Toggle("Preview Mode (this session)", isOn: $viewModel.isPreviewMode)
                Toggle("Start in Preview Mode", isOn: binding(\.startInPreviewMode))
                Picker("Emergency stop", selection: binding(\.emergencyStopHotkey)) {
                    ForEach(EmergencyStopHotkey.allCases) { hotkey in
                        Text(hotkey.displayName).tag(hotkey)
                    }
                }
                TextField("Accepted foreground app names", text: acceptedAppNamesBinding)
                Button("Open Accessibility Settings", action: viewModel.openAccessibilitySettings)
            }

            Section("Quartz Modifier Diagnostics") {
                Picker("Modifier mode", selection: binding(\.modifierInjectionMode)) {
                    ForEach(ModifierInjectionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Picker("Event target", selection: binding(\.eventPostTarget)) {
                    ForEach(EventPostTarget.allCases) { target in
                        Text(target.displayName).tag(target)
                    }
                }
                labeledSlider("Modifier lead", value: binding(\.modifierLeadTime), range: 0...0.500, suffix: "s")
                labeledSlider("Release delay", value: binding(\.modifierReleaseDelay), range: 0...0.100, suffix: "s")
                labeledSlider("Reuse window", value: binding(\.modifierReuseWindow), range: 0...1.000, suffix: "s")
                labeledSlider("Layer switch gap", value: binding(\.layerSwitchGap), range: 0...0.250, suffix: "s")
                Text("36-key live playback and calibration use VirtualHID regardless of these saved Quartz alternatives. In 21-key mode, these controls remain available for diagnostic comparisons.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Calibration uses the countdown. Focus NTE and watch the piano layer before each note lands.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Hold Shift", action: viewModel.holdCalibrationShift)
                    Button("Hold Ctrl", action: viewModel.holdCalibrationControl)
                }
                HStack {
                    Button("Natural", action: viewModel.sendCalibrationNatural)
                    Button("Shift sharp", action: viewModel.sendCalibrationSharp)
                    Button("Ctrl flat", action: viewModel.sendCalibrationFlat)
                    Button("Layer sequence", action: viewModel.sendCalibrationLayerSequence)
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

            Section {
                Button("Reset Settings") {
                    settingsStore.resetSettings()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
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

import AppKit
import AVFoundation
import Combine
import Foundation
@preconcurrency import NTEPianoMidiPlayerCore
import UniformTypeIdentifiers

@MainActor
final class AppViewModel: ObservableObject {
    @Published var document: MidiDocument?
    @Published var tracks: [MidiTrackInfo] = []
    @Published var mappedEvents: [MappedNoteEvent] = []
    @Published var playableChords: [PlayableChord] = []
    @Published var diagnostics = MappingDiagnostics()
    @Published var playbackState: PlaybackState = .idle
    @Published var statusMessage = "Open a MIDI file to begin."
    @Published var searchText = ""
    @Published var progressTime: TimeInterval = 0
    @Published var seekTime: TimeInterval = 0
    @Published var previewLogText = ""
    @Published var isPreviewMode: Bool
    @Published var isArranging = false
    @Published var sheetText = ""
    @Published var sheetOptions = PianoSheetOptions() {
        didSet { regenerateSheet() }
    }
    @Published var showingSettings = false
    @Published var showingSheetExporter = false
    @Published private(set) var isRecordingKeyboardEvents = false
    @Published private(set) var keyboardEventTraceText = "No input-event trace recorded."
    @Published private(set) var virtualHIDStatus: VirtualHIDConnectionStatus = .checking
    @Published private(set) var virtualHIDReportTraceText = "No VirtualHID reports sent."
    @Published private(set) var readiness: SetupReadiness = .blocked(.installDriver, detail: "Checking setup status…")
    @Published var showingOnboarding = false
    @Published var setupActionError: String?
    @Published private(set) var isInstallingServices = false
    @Published private(set) var countdownRemaining: TimeInterval?

    let settingsStore: SettingsStore

    private let loader = MidiFileLoader()
    private let scheduler = EventScheduler()
    private let quartzInjector: CGEventKeyInjector
    private let virtualHIDInjector: VirtualHIDKeyInjector
    private var activeInjector: KeyInjecting?
    private let keyboardEventRecorder = KeyboardEventRecorder()
    private let previewPlayer = MidiPreviewPlayer()
    private var settingsCancellable: AnyCancellable?
    private var arrangementToken: ArrangementCancellationToken?
    private var recordedKeyboardEvents: [RecordedKeyboardEvent] = []
    private var keyboardEventTraceHeader = ""
    private var readinessPollTimer: Timer?
    private var countdownTimer: Timer?
    private var countdownEndDate: Date?
    private var hasResolvedInitialOnboarding = false
    private var appliedTheme: ThemePreference?

    /// Bump when onboarding needs to run again for existing users (e.g. a new required step).
    static let currentOnboardingVersion = 1

    init(settingsStore: SettingsStore = SettingsStore()) {
        self.settingsStore = settingsStore
        self.isPreviewMode = settingsStore.settings.startInPreviewMode
        self.quartzInjector = CGEventKeyInjector(previewMode: settingsStore.settings.startInPreviewMode)
        self.virtualHIDInjector = VirtualHIDKeyInjector(previewMode: settingsStore.settings.startInPreviewMode)
        virtualHIDInjector.onFailure = { [weak self] message in
            DispatchQueue.main.async {
                guard let self else { return }
                self.scheduler.stop()
                self.virtualHIDStatus = self.virtualHIDInjector.connectionStatus
                self.virtualHIDReportTraceText = self.formattedVirtualHIDReportTrace()
                self.playbackState = .stopped
                self.statusMessage = "VirtualHID playback stopped: \(message)"
            }
        }
        virtualHIDInjector.onRecovered = { [weak self] message in
            DispatchQueue.main.async {
                guard let self else { return }
                self.virtualHIDStatus = self.virtualHIDInjector.connectionStatus
                self.virtualHIDReportTraceText = self.formattedVirtualHIDReportTrace()
                self.statusMessage = "VirtualHID recovered: \(message)"
            }
        }
        settingsCancellable = settingsStore.settingsPublisher.sink { [weak self] _ in
            Task { @MainActor in
                self?.refreshMapping()
                self?.applyThemePreference()
            }
        }
        refreshVirtualHIDStatus()
        refreshReadiness()
        applyThemePreference()
    }

    /// Applies the theme preference to the whole app, not just the SwiftUI environment of the
    /// main window. `preferredColorScheme` only affects the view hierarchy it's attached to, so
    /// the Settings window, `NSOpenPanel`, and other AppKit chrome need this instead.
    private func applyThemePreference() {
        let theme = settingsStore.settings.themePreference
        guard theme != appliedTheme else { return }
        appliedTheme = theme
        switch theme {
        case .system:
            NSApplication.shared.appearance = nil
        case .light:
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }

    var duration: TimeInterval {
        document?.duration ?? 0
    }

    var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(max(progressTime / duration, 0), 1)
    }

    /// Non-nil while playing and the next playable onset is more than a few seconds away, so the
    /// UI can tell a long silent passage in the source file apart from a stall.
    var upcomingSilence: (nextOnset: TimeInterval, remaining: TimeInterval)? {
        guard playbackState == .playing else { return nil }
        guard let nextOnset = playableChords
            .map(\.startTime)
            .filter({ $0 > progressTime })
            .min() else { return nil }
        let remaining = nextOnset - progressTime
        guard remaining > 3 else { return nil }
        return (nextOnset, remaining)
    }

    var filteredTrackIndices: [Int] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return tracks.indices.filter { index in
            guard !query.isEmpty else { return true }
            let track = tracks[index]
            let haystack = [
                track.name,
                track.instrumentName ?? "",
                track.channel.map { "channel \($0 + 1)" } ?? "",
                track.instrumentProgram.map { "program \($0)" } ?? ""
            ].joined(separator: " ").lowercased()
            return haystack.contains(query)
        }
    }

    func startKeyboardEventRecording() {
        recordedKeyboardEvents.removeAll()
        let settings = settingsStore.settings.clamped()
        keyboardEventTraceHeader = [
            "NTE Piano MIDI Player input-event trace",
            "mode=\(settings.modifierInjectionMode.rawValue) target=\(settings.eventPostTarget.rawValue)",
            "PLAYER events carry marker=0x\(String(KeyboardEventDiagnostics.injectedEventMarker, radix: 16, uppercase: true))",
            "VirtualHID events use the hardware path and may appear as EXTERNAL with pid=0.",
            "Only Shift, Control, and the 21 piano letter keys are recorded."
        ].joined(separator: "\n")
        keyboardEventTraceText = keyboardEventTraceHeader + "\nWaiting for keyboard events…"

        guard AccessibilityPermission.isTrusted(prompt: true) else {
            keyboardEventTraceText = keyboardEventTraceHeader
                + "\nERROR: Accessibility permission is required. Grant it, relaunch the app, and retry."
            statusMessage = "Could not start input-event recorder. Grant Accessibility permission and relaunch."
            return
        }

        let started = keyboardEventRecorder.start { [weak self] event in
            DispatchQueue.main.async {
                self?.appendRecordedKeyboardEvent(event)
            }
        }
        isRecordingKeyboardEvents = started
        if started {
            statusMessage = "Input-event recorder started. Compare physical holds with Hold Shift and Hold Ctrl."
        } else {
            keyboardEventTraceText = keyboardEventTraceHeader
                + "\nERROR: Could not create the HID event tap despite Accessibility permission. Relaunch the app and retry."
            statusMessage = "Could not start input-event recorder despite Accessibility permission."
        }
    }

    func stopKeyboardEventRecording() {
        keyboardEventRecorder.stop()
        isRecordingKeyboardEvents = false
        refreshKeyboardEventTraceText()
        statusMessage = "Input-event recorder stopped with \(recordedKeyboardEvents.count) captured events."
    }

    func clearKeyboardEventRecording() {
        recordedKeyboardEvents.removeAll()
        keyboardEventTraceHeader = ""
        keyboardEventTraceText = "No input-event trace recorded."
    }

    func copyKeyboardEventTrace() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(keyboardEventTraceText, forType: .string)
        statusMessage = "Input-event trace copied to the clipboard."
    }

    private func appendRecordedKeyboardEvent(_ event: RecordedKeyboardEvent) {
        guard isRecordingKeyboardEvents else { return }
        if recordedKeyboardEvents.count == 500 {
            keyboardEventRecorder.stop()
            isRecordingKeyboardEvents = false
            statusMessage = "Input-event recorder reached its 500-event safety limit."
            return
        }
        recordedKeyboardEvents.append(event)
        refreshKeyboardEventTraceText()
    }

    private func refreshKeyboardEventTraceText() {
        guard let firstTimestamp = recordedKeyboardEvents.first?.timestamp else {
            keyboardEventTraceText = keyboardEventTraceHeader.isEmpty
                ? "No input-event trace recorded."
                : keyboardEventTraceHeader + "\nNo keyboard events captured."
            return
        }
        let lines = recordedKeyboardEvents.map { $0.traceLine(relativeTo: firstTimestamp) }
        keyboardEventTraceText = keyboardEventTraceHeader + "\n" + lines.joined(separator: "\n")
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open MIDI File"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "mid") ?? .data,
            UTType(filenameExtension: "midi") ?? .data
        ]
        if panel.runModal() == .OK, let url = panel.url {
            load(url: url)
        }
    }

    func load(url: URL) {
        do {
            let loaded = try loader.load(url: url)
            document = loaded
            tracks = loaded.tracks
            progressTime = 0
            seekTime = 0
            settingsStore.rememberFile(url)
            statusMessage = "Loaded \(loaded.displayName) with \(loaded.noteEvents.count) notes."
            refreshMapping()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func refreshMapping() {
        guard let document else {
            arrangementToken?.cancel()
            mappedEvents = []
            playableChords = []
            diagnostics = MappingDiagnostics()
            sheetText = ""
            return
        }
        let events = selectedEvents(from: document.noteEvents)
        let settings = settingsStore.settings.clamped()
        arrange(events: events, settings: settings, startPlaybackWhenReady: false)
    }

    func play() {
        if playbackState == .paused {
            resume()
            return
        }

        guard let document else { return }
        arrange(
            events: selectedEvents(from: document.noteEvents),
            settings: settingsStore.settings.clamped(),
            startPlaybackWhenReady: true
        )
    }

    private func startPreparedPlayback() {
        guard !playableChords.isEmpty else {
            statusMessage = "No playable notes after arrangement. Check tracks, layout, transpose, and range settings."
            return
        }

        let settings = settingsStore.settings.clamped()
        let previewMode = isPreviewMode
        guard let injector = prepareInjector(settings: settings) else { return }
        let injectionSettings = settingsForSelectedBackend(settings)

        let startOffset = min(max(seekTime, 0), duration)
        let chordsToPlay = playableChords
            .filter { $0.startTime >= startOffset }
            .map { chord -> PlayableChord in
                var shifted = chord
                shifted.startTime -= startOffset
                return shifted
            }

        guard !chordsToPlay.isEmpty else {
            statusMessage = "Seek position is past the last playable note."
            return
        }

        previewLogText = ""
        statusMessage = previewMode ? "Preview playback started." : "Playback started. Focus NTE before the countdown ends."

        let guarder = ForegroundAppGuard(acceptedNames: settings.acceptedForegroundAppNames)
        scheduler.start(
            chords: chordsToPlay,
            settings: injectionSettings,
            injector: injector,
            frontmostGuard: { previewMode || guarder.isAcceptedFrontmostApp() },
            onStateChange: { [weak self] state in
                Task { @MainActor in
                    self?.playbackState = state
                    self?.updateCountdownDisplay(for: state, duration: injectionSettings.countdownDuration)
                }
            },
            onProgress: { [weak self] time in
                Task { @MainActor in
                    self?.progressTime = startOffset + time
                    self?.seekTime = startOffset + time
                }
            },
            onFinish: { [weak self] reason in
                Task { @MainActor in
                    self?.handleFinish(reason)
                }
            }
        )
    }

    func pause() {
        scheduler.pause()
        playbackState = .paused
        endCountdownDisplay()
        statusMessage = "Playback paused."
    }

    func resume() {
        scheduler.resume()
        playbackState = .playing
        statusMessage = "Playback resumed."
    }

    func stop() {
        scheduler.stop()
        previewPlayer.stop()
        playbackState = .stopped
        endCountdownDisplay()
        previewLogText = activeInjector?.previewLog.joined(separator: "\n") ?? ""
        virtualHIDReportTraceText = formattedVirtualHIDReportTrace()
        activeInjector = nil
        statusMessage = "Playback stopped."
    }

    func seek(to time: TimeInterval) {
        let clamped = min(max(time, 0), duration)
        seekTime = clamped
        progressTime = clamped
        if playbackState == .playing || playbackState == .countingDown || playbackState == .paused {
            stop()
            statusMessage = "Seeked to \(formatTime(clamped)). Press Play to continue."
        }
    }

    func toggleSpeakerPlayback() {
        guard let url = document?.url else { return }
        if previewPlayer.isPlaying {
            previewPlayer.stop()
            statusMessage = "Speaker playback stopped."
        } else {
            do {
                try previewPlayer.play(url: url, startTime: seekTime)
                statusMessage = "Speaker playback started."
            } catch {
                statusMessage = "Speaker playback failed: \(error.localizedDescription)"
            }
        }
    }

    func copySheetToClipboard() {
        regenerateSheet()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sheetText, forType: .string)
        statusMessage = "Piano sheet copied to clipboard."
    }

    func openAccessibilitySettings() {
        AccessibilityPermission.openAccessibilitySettings()
    }

    func refreshVirtualHIDStatus() {
        virtualHIDStatus = .checking
        let injector = virtualHIDInjector
        DispatchQueue.global(qos: .utility).async {
            let status = injector.refreshConnectionStatus()
            DispatchQueue.main.async { [weak self] in
                self?.virtualHIDStatus = status
            }
        }
    }

    /// Re-runs the full setup ladder (driver, extension, background services, or
    /// Accessibility, depending on the selected layout) on a background queue.
    func refreshReadiness() {
        let layoutMode = settingsStore.settings.layoutMode
        let injector = virtualHIDInjector
        DispatchQueue.global(qos: .utility).async {
            let virtualHIDStatus = injector.refreshConnectionStatus()
            let accessibilityTrusted = AccessibilityPermission.isTrusted(prompt: false)
            let readiness = SetupInspector.readiness(
                virtualHIDStatus: virtualHIDStatus,
                layoutMode: layoutMode,
                accessibilityTrusted: accessibilityTrusted
            )
            DispatchQueue.main.async { [weak self] in
                self?.virtualHIDStatus = virtualHIDStatus
                self?.readiness = readiness
                self?.resolveInitialOnboardingIfNeeded()
            }
        }
    }

    /// Runs once, after the first readiness probe returns. A Mac that is already set up
    /// (reinstall, second user account) should never see the wizard, but the driver check
    /// shells out to `systemextensionsctl`, so this can't be decided synchronously in `init`.
    private func resolveInitialOnboardingIfNeeded() {
        guard !hasResolvedInitialOnboarding else { return }
        hasResolvedInitialOnboarding = true
        guard settingsStore.settings.onboardingCompletedVersion < Self.currentOnboardingVersion else { return }
        if readiness.isReady {
            settingsStore.settings.onboardingCompletedVersion = Self.currentOnboardingVersion
        } else {
            showingOnboarding = true
        }
    }

    /// Call from `.onAppear` on the onboarding sheet or the Settings General tab. Harmless to
    /// call repeatedly; playback never polls.
    func startReadinessPolling() {
        stopReadinessPolling()
        refreshReadiness()
        readinessPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshReadiness() }
        }
    }

    func stopReadinessPolling() {
        readinessPollTimer?.invalidate()
        readinessPollTimer = nil
    }

    func installPrivilegedServices() {
        guard !isInstallingServices else { return }
        isInstallingServices = true
        setupActionError = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try PrivilegedServiceInstaller.install()
                DispatchQueue.main.async {
                    self?.isInstallingServices = false
                    self?.refreshReadiness()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isInstallingServices = false
                    self?.setupActionError = error.localizedDescription
                }
            }
        }
    }

    func removePrivilegedServices() {
        guard !isInstallingServices else { return }
        isInstallingServices = true
        setupActionError = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try PrivilegedServiceInstaller.uninstall()
                DispatchQueue.main.async {
                    self?.isInstallingServices = false
                    self?.refreshReadiness()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isInstallingServices = false
                    self?.setupActionError = error.localizedDescription
                }
            }
        }
    }

    func activateDriverExtension() {
        let path = "/Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Manager"
        guard FileManager.default.isExecutableFile(atPath: path) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["activate"]
        try? process.run()
    }

    func skipToTwentyOneKey() {
        setLayoutMode(.nte21Natural)
    }

    /// Switches the active key layout. The two layouts use different input backends (VirtualHID vs.
    /// Accessibility) with different setup requirements, so this always re-checks readiness.
    func setLayoutMode(_ mode: LayoutMode) {
        guard settingsStore.settings.layoutMode != mode else { return }
        settingsStore.settings.layoutMode = mode
        refreshReadiness()
    }

    func completeOnboarding() {
        settingsStore.settings.onboardingCompletedVersion = Self.currentOnboardingVersion
        settingsStore.settings.startInPreviewMode = false
        isPreviewMode = false
        showingOnboarding = false
    }

    func openVirtualHIDReleasePage() {
        guard let url = URL(string: "https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/releases/tag/v8.2.0") else { return }
        NSWorkspace.shared.open(url)
    }

    func copyVirtualHIDSetupCommands() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(virtualHIDSetupCommands, forType: .string)
        statusMessage = "VirtualHID setup commands copied to the clipboard."
    }

    var virtualHIDSetupCommands: String {
        let manager = "/Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Manager"
        let daemon = "/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Daemon"
        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/NTEVirtualHIDBridge")
            .path
        return [
            "'\(manager)' activate",
            "sudo '\(daemon)'",
            "sudo '\(helper)' --allowed-uid \(getuid())"
        ].joined(separator: "\n")
    }

    func sendCalibrationNatural() {
        sendCalibration(keys: calibrationKeys(semitones: [0], exactModifiers: false), label: "Natural calibration")
    }

    func sendCalibrationSharp() {
        sendCalibration(keys: calibrationKeys(semitones: [1], exactModifiers: true), label: "Shift sharp calibration")
    }

    func sendCalibrationFlat() {
        sendCalibration(keys: calibrationKeys(semitones: [3], exactModifiers: true), label: "Ctrl flat calibration")
    }

    func sendCalibrationLayerSequence() {
        let settings = settingsStore.settings.clamped()
        guard let injector = prepareInjector(settings: settings) else { return }
        let injectionSettings = settingsForSelectedBackend(settings)
        statusMessage = "Layer sequence calibration started. Focus NTE before the countdown ends."

        let events = calibrationLayerSequenceEvents(settings: injectionSettings)
        let groups = EventTimelineBuilder.group(events: events, threshold: injectionSettings.chordThreshold)
        let actions = LayeredPlaybackPlanner.plan(groups: groups, settings: injectionSettings)
        runCalibrationActions(actions, settings: injectionSettings, injector: injector, label: "Layer sequence calibration")
    }

    func holdCalibrationShift() {
        holdCalibration(modifier: .shift, label: "Hold Shift layer")
    }

    func holdCalibrationControl() {
        holdCalibration(modifier: .control, label: "Hold Ctrl layer")
    }

    func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite else { return "0:00" }
        let totalSeconds = max(0, Int(time.rounded()))
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }

    private func selectedEvents(from events: [MidiNoteEvent]) -> [MidiNoteEvent] {
        let soloed = tracks.filter { $0.isSoloed && !$0.isMuted }
        let activeTrackIDs: Set<Int>
        if !soloed.isEmpty {
            activeTrackIDs = Set(soloed.map(\.trackIndex))
        } else {
            activeTrackIDs = Set(tracks.filter { $0.isEnabled && !$0.isMuted }.map(\.trackIndex))
        }
        return events.filter { activeTrackIDs.contains($0.trackIndex) }
    }

    private func arrange(
        events: [MidiNoteEvent],
        settings: PlaybackSettings,
        startPlaybackWhenReady: Bool
    ) {
        arrangementToken?.cancel()
        let token = ArrangementCancellationToken()
        arrangementToken = token
        isArranging = true
        statusMessage = startPlaybackWhenReady ? "Preparing arrangement…" : "Updating arrangement…"
        let unsupportedExpressionEventCount = document?.unsupportedExpressionEventCount ?? 0

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = UniversalMidiArranger(layoutMode: settings.layoutMode).arrange(
                events: events,
                settings: settings,
                isCancelled: token.isCancelled
            )
            DispatchQueue.main.async { [weak self] in
                guard let self, self.arrangementToken === token, !token.isCancelled() else { return }
                self.isArranging = false
                self.mappedEvents = result.mappedEvents
                self.playableChords = result.playableChords
                var diagnostics = result.diagnostics
                diagnostics.unsupportedExpressionEvents = unsupportedExpressionEventCount
                if unsupportedExpressionEventCount > 0 {
                    diagnostics.warnings.append(
                        "\(unsupportedExpressionEventCount) pitch-bend or aftertouch events cannot be reproduced by NTE."
                    )
                }
                self.diagnostics = diagnostics
                self.regenerateSheet()
                let onsetCount = Set(result.playableChords.map(\.startTime)).count
                self.statusMessage = "Arranged \(result.mappedEvents.count) playable notes in \(onsetCount) chords."
                if startPlaybackWhenReady { self.startPreparedPlayback() }
            }
        }
    }

    private func regenerateSheet() {
        sheetText = PianoSheetExporter().export(events: mappedEvents, options: sheetOptions)
    }

    private func sendCalibration(keys: [PianoKey], label: String) {
        let settings = settingsStore.settings.clamped()
        guard let injector = prepareInjector(settings: settings) else { return }
        let injectionSettings = settingsForSelectedBackend(settings)
        statusMessage = "\(label) started. Focus NTE before the countdown ends."

        let actions = calibrationActions(for: keys, settings: injectionSettings)
        runCalibrationActions(actions, settings: injectionSettings, injector: injector, label: label)
    }

    private func holdCalibration(modifier: KeyModifier, label: String) {
        let settings = settingsStore.settings.clamped()
        guard let injector = prepareInjector(settings: settings) else { return }
        let injectionSettings = settingsForSelectedBackend(settings)
        let backendDescription = backendDescription(settings: settings)
        statusMessage = "\(label) started. Focus NTE before the countdown ends."

        DispatchQueue.global(qos: .userInitiated).async {
            Self.sleep(until: injectionSettings.countdownDuration, startNanos: DispatchTime.now().uptimeNanoseconds)
            injector.holdModifier(
                modifier,
                mode: injectionSettings.modifierInjectionMode,
                duration: 2.0,
                eventPostTarget: injectionSettings.eventPostTarget,
                previewDescription: "\(label) using \(backendDescription)"
            )
            injector.releaseAll()
            let logText = injector.previewLog.joined(separator: "\n")
            DispatchQueue.main.async { [weak self] in
                self?.previewLogText = logText
                self?.virtualHIDReportTraceText = self?.formattedVirtualHIDReportTrace() ?? ""
                self?.statusMessage = "\(label) completed."
            }
        }
    }

    private func calibrationActions(for keys: [PianoKey], settings: PlaybackSettings) -> [ScheduledPlaybackAction] {
        let events = keys.map { key in
            MappedNoteEvent(
                source: MidiNoteEvent(
                    midiNote: UInt8(clamping: key.midiNote),
                    velocity: 90,
                    startTime: 0,
                    duration: settings.tapDuration,
                    channel: 0,
                    trackIndex: 0
                ),
                adjustedMidiNote: key.midiNote,
                pianoKeys: [key],
                mappingKind: key.modifier == .none ? .exact : .modifierExact,
                startTime: 0,
                duration: settings.tapDuration
            )
        }
        let groups = EventTimelineBuilder.group(events: events, threshold: settings.chordThreshold)
        return LayeredPlaybackPlanner.plan(groups: groups, settings: settings)
    }

    private func calibrationLayerSequenceEvents(settings: PlaybackSettings) -> [MappedNoteEvent] {
        let specs: [(semitone: Int, exactModifiers: Bool, startTime: TimeInterval)] = [
            (0, false, 0.00),
            (3, true, 0.45),
            (2, false, 0.90),
            (1, true, 1.35),
            (4, false, 1.80)
        ]
        return specs.compactMap { spec in
            guard let key = calibrationKeys(semitones: [spec.semitone], exactModifiers: spec.exactModifiers).first else {
                return nil
            }
            return MappedNoteEvent(
                source: MidiNoteEvent(
                    midiNote: UInt8(clamping: key.midiNote),
                    velocity: 90,
                    startTime: spec.startTime,
                    duration: settings.tapDuration,
                    channel: 0,
                    trackIndex: 0
                ),
                adjustedMidiNote: key.midiNote,
                pianoKeys: [key],
                mappingKind: key.modifier == .none ? .exact : .modifierExact,
                startTime: spec.startTime,
                duration: settings.tapDuration
            )
        }
    }

    private func runCalibrationActions(
        _ actions: [ScheduledPlaybackAction],
        settings: PlaybackSettings,
        injector: KeyInjecting,
        label: String
    ) {
        let backendDescription = backendDescription(settings: settings)
        DispatchQueue.global(qos: .userInitiated).async {
            let startNanos = DispatchTime.now().uptimeNanoseconds
            for action in actions {
                Self.sleep(until: action.time, startNanos: startNanos)
                switch action.kind {
                case let .key(key, keyEventModifier, keyDown):
                    injector.setKey(
                        key,
                        keyEventModifier: keyEventModifier,
                        keyDown: keyDown,
                        eventPostTarget: settings.eventPostTarget
                    )
                case let .modifier(modifier, side, keyDown):
                    injector.setModifier(
                        modifier,
                        side: side,
                        keyDown: keyDown,
                        eventPostTarget: settings.eventPostTarget
                    )
                case let .preview(entry):
                    injector.recordPreview("\(entry) via \(backendDescription)")
                case .progress:
                    break
                }
            }
            injector.releaseAll()
            let logText = injector.previewLog.joined(separator: "\n")
            DispatchQueue.main.async { [weak self] in
                self?.previewLogText = logText
                self?.virtualHIDReportTraceText = self?.formattedVirtualHIDReportTrace() ?? ""
                self?.statusMessage = "\(label) sent using \(backendDescription)."
            }
        }
    }

    private func calibrationKeys(semitones: [Int], exactModifiers: Bool) -> [PianoKey] {
        semitones.compactMap { semitone in
            let row = PianoRow.bas
            let midiNote = settingsStore.settings.baseMidiNoteForBAS1 + semitone
            guard let rowKeys = NTELayout.rowKeys[row] else { return nil }
            if exactModifiers, let entry = NTELayout.chromaticDegreeMap[semitone] {
                return PianoKey(
                    row: row,
                    semitone: semitone,
                    degreeLabel: entry.degree,
                    noteName: NTELayout.noteNames[semitone],
                    keyboardKey: rowKeys[entry.naturalIndex],
                    modifier: entry.modifier,
                    midiNote: midiNote
                )
            }
            guard let naturalIndex = NTELayout.naturalSemitones.firstIndex(of: semitone) else {
                return nil
            }
            return PianoKey(
                row: row,
                semitone: semitone,
                degreeLabel: NTELayout.naturalDegreeLabels[naturalIndex],
                noteName: NTELayout.noteNames[semitone],
                keyboardKey: rowKeys[naturalIndex],
                modifier: .none,
                midiNote: midiNote
            )
        }
    }

    private func prepareInjector(settings: PlaybackSettings) -> KeyInjecting? {
        let injector: KeyInjecting
        if isPreviewMode {
            injector = quartzInjector
        } else {
            switch settings.layoutMode {
            case .nte21Natural:
                guard AccessibilityPermission.isTrusted(prompt: true) else {
                    statusMessage = "Accessibility permission is required for 21-key keyboard injection. Preview Mode and sheet export still work."
                    return nil
                }
                injector = quartzInjector
            case .nte36Chromatic:
                let status = virtualHIDInjector.refreshConnectionStatus()
                virtualHIDStatus = status
                guard status.isReady else {
                    statusMessage = "36-key playback requires VirtualHID: \(status.guidance)"
                    return nil
                }
                virtualHIDInjector.clearReportTrace()
                virtualHIDReportTraceText = "Waiting for VirtualHID reports…"
                injector = virtualHIDInjector
            }
        }
        injector.previewMode = isPreviewMode
        injector.clearPreviewLog()
        activeInjector = injector
        return injector
    }

    private func settingsForSelectedBackend(_ settings: PlaybackSettings) -> PlaybackSettings {
        guard !isPreviewMode, settings.layoutMode == .nte36Chromatic else { return settings }
        var copy = settings
        copy.modifierInjectionMode = .hardwareStateLeft
        return copy
    }

    private func backendDescription(settings: PlaybackSettings) -> String {
        if isPreviewMode { return "Preview Mode" }
        return settings.layoutMode == .nte36Chromatic
            ? "Karabiner VirtualHID"
            : settings.eventPostTarget.displayName
    }

    private func formattedVirtualHIDReportTrace() -> String {
        let lines = virtualHIDInjector.reportTrace
        guard !lines.isEmpty else { return "No VirtualHID reports sent." }
        return ([
            "NTE Piano MIDI Player VirtualHID report trace",
            "bridgeProtocol=\(VirtualHIDConstants.protocolVersion) driver=\(VirtualHIDConstants.expectedDriverVersion) upstreamProtocol=\(VirtualHIDConstants.expectedClientProtocolVersion)"
        ] + lines).joined(separator: "\n")
    }

    private func updateCountdownDisplay(for state: PlaybackState, duration: TimeInterval) {
        if state == .countingDown {
            beginCountdownDisplay(duration: duration)
        } else {
            endCountdownDisplay()
        }
    }

    private func beginCountdownDisplay(duration: TimeInterval) {
        guard duration > 0 else { return }
        countdownTimer?.invalidate()
        let endDate = Date().addingTimeInterval(duration)
        countdownEndDate = endDate
        countdownRemaining = duration
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, let endDate = self.countdownEndDate else {
                    timer.invalidate()
                    return
                }
                let remaining = endDate.timeIntervalSinceNow
                if remaining <= 0 {
                    self.countdownRemaining = 0
                    timer.invalidate()
                } else {
                    self.countdownRemaining = remaining
                }
            }
        }
    }

    private func endCountdownDisplay() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownEndDate = nil
        countdownRemaining = nil
    }

    private func handleFinish(_ reason: PlaybackFinishReason) {
        previewLogText = activeInjector?.previewLog.joined(separator: "\n") ?? ""
        virtualHIDReportTraceText = formattedVirtualHIDReportTrace()
        activeInjector = nil
        switch reason {
        case .completed:
            playbackState = .completed
            progressTime = duration
            seekTime = min(seekTime, duration)
            statusMessage = "Playback completed."
        case .stopped:
            playbackState = .stopped
            statusMessage = "Playback stopped."
        case .lostFocus:
            playbackState = .lostFocus
            statusMessage = "Playback stopped because NTE is no longer frontmost."
        }
    }

    nonisolated private static func sleep(until targetSeconds: TimeInterval, startNanos: UInt64) {
        let targetOffset = UInt64(max(0, targetSeconds) * 1_000_000_000)
        while true {
            let target = startNanos + targetOffset
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= target { return }
            let remaining = TimeInterval(target - now) / 1_000_000_000
            Thread.sleep(forTimeInterval: min(max(remaining, 0.001), 0.005))
        }
    }
}

final class MidiPreviewPlayer {
    private var player: AVMIDIPlayer?
    private(set) var isPlaying = false

    func play(url: URL, startTime: TimeInterval) throws {
        stop()
        let player = try AVMIDIPlayer(contentsOf: url, soundBankURL: nil)
        player.prepareToPlay()
        player.currentPosition = startTime
        player.play { [weak self] in
            self?.isPlaying = false
        }
        self.player = player
        isPlaying = true
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
    }
}

private final class ArrangementCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

import AppKit
import AVFoundation
import Combine
import Foundation
import NTEPianoMidiPlayerCore
import UniformTypeIdentifiers

@MainActor
final class AppViewModel: ObservableObject {
    @Published var document: MidiDocument?
    @Published var tracks: [MidiTrackInfo] = []
    @Published var mappedEvents: [MappedNoteEvent] = []
    @Published var diagnostics = MappingDiagnostics()
    @Published var playbackState: PlaybackState = .idle
    @Published var statusMessage = "Open a MIDI file to begin."
    @Published var searchText = ""
    @Published var progressTime: TimeInterval = 0
    @Published var seekTime: TimeInterval = 0
    @Published var dryRunLogText = ""
    @Published var sheetText = ""
    @Published var sheetOptions = PianoSheetOptions() {
        didSet { regenerateSheet() }
    }
    @Published var showingSettings = false
    @Published var showingSheetExporter = false

    let settingsStore = SettingsStore()

    private let loader = MidiFileLoader()
    private let scheduler = EventScheduler()
    private let injector = CGEventKeyInjector(dryRun: true)
    private let previewPlayer = MidiPreviewPlayer()
    private var settingsCancellable: AnyCancellable?

    init() {
        settingsCancellable = settingsStore.settingsPublisher.sink { [weak self] _ in
            Task { @MainActor in
                self?.refreshMapping()
            }
        }
    }

    var duration: TimeInterval {
        document?.duration ?? 0
    }

    var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(max(progressTime / duration, 0), 1)
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
            mappedEvents = []
            diagnostics = MappingDiagnostics()
            sheetText = ""
            return
        }
        let events = selectedEvents(from: document.noteEvents)
        let settings = settingsStore.settings.clamped()
        let mapper = NoteMapperFactory.mapper(for: settings.layoutMode)
        let result = mapper.map(events: events, settings: settings)
        mappedEvents = result.mappedEvents
        diagnostics = result.diagnostics
        regenerateSheet()
    }

    func play() {
        if playbackState == .paused {
            resume()
            return
        }

        refreshMapping()
        guard !mappedEvents.isEmpty else {
            statusMessage = "No playable notes after mapping. Check tracks, layout, transpose, and range settings."
            return
        }

        let settings = settingsStore.settings.clamped()
        if !settings.dryRun, !AccessibilityPermission.isTrusted(prompt: true) {
            statusMessage = "Accessibility permission is required for keyboard injection. Dry-run and sheet export still work."
            return
        }

        let startOffset = min(max(seekTime, 0), duration)
        let eventsToPlay = mappedEvents
            .filter { $0.startTime >= startOffset }
            .map { event -> MappedNoteEvent in
                var shifted = event
                shifted.startTime -= startOffset
                return shifted
            }

        guard !eventsToPlay.isEmpty else {
            statusMessage = "Seek position is past the last playable note."
            return
        }

        injector.dryRun = settings.dryRun
        injector.clearDryRunLog()
        dryRunLogText = ""
        statusMessage = settings.dryRun ? "Dry-run playback started." : "Playback started. Focus NTE before the countdown ends."

        let guarder = ForegroundAppGuard(acceptedNames: settings.acceptedForegroundAppNames)
        scheduler.start(
            events: eventsToPlay,
            settings: settings,
            injector: injector,
            frontmostGuard: { settings.dryRun || guarder.isAcceptedFrontmostApp() },
            onStateChange: { [weak self] state in
                Task { @MainActor in
                    self?.playbackState = state
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
        dryRunLogText = injector.dryRunLog.joined(separator: "\n")
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

    func togglePreviewPlayback() {
        guard let url = document?.url else { return }
        if previewPlayer.isPlaying {
            previewPlayer.stop()
            statusMessage = "Speaker preview stopped."
        } else {
            do {
                try previewPlayer.play(url: url, startTime: seekTime)
                statusMessage = "Speaker preview started."
            } catch {
                statusMessage = "Preview failed: \(error.localizedDescription)"
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

    private func regenerateSheet() {
        sheetText = PianoSheetExporter().export(events: mappedEvents, options: sheetOptions)
    }

    private func handleFinish(_ reason: PlaybackFinishReason) {
        dryRunLogText = injector.dryRunLog.joined(separator: "\n")
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

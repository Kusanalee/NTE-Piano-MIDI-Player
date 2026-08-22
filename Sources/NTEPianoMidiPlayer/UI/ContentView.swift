import NTEPianoMidiPlayerCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var isDropTarget = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ZStack {
            NavigationStack {
                simpleBody
                    .navigationTitle(viewModel.document?.displayName ?? "NTE Piano MIDI Player")
                    .toolbar { toolbarContent }
            }

            if let remaining = viewModel.countdownRemaining {
                CountdownOverlayView(
                    remaining: remaining,
                    acceptedAppName: acceptedAppName,
                    onCancel: viewModel.stop
                )
                .zIndex(1)
            }
        }
        .animation(.default, value: viewModel.countdownRemaining != nil)
        .sheet(isPresented: $viewModel.showingOnboarding) {
            OnboardingView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showingSheetExporter) {
            SheetExporterView(viewModel: viewModel)
                .frame(width: 760, height: 620)
        }
        .preferredColorScheme(viewModel.settingsStore.settings.themePreference.colorScheme)
    }

    private var acceptedAppName: String {
        viewModel.settingsStore.settings.acceptedForegroundAppNames.first ?? "NTE"
    }

    private var simpleBody: some View {
        ScrollView {
            VStack(spacing: 16) {
                FileSummaryView(viewModel: viewModel, isDropTarget: $isDropTarget)
                PlaybackModeView(viewModel: viewModel)
                ScrubberView(viewModel: viewModel)
                TrackListView(viewModel: viewModel)
                    .frame(minHeight: 260)

                if viewModel.settingsStore.settings.advancedSettingsEnabled {
                    KeyboardPreviewView(settings: viewModel.settingsStore.settings)
                    DiagnosticsView(viewModel: viewModel)
                    PreviewLogView(logText: viewModel.previewLogText)
                }
            }
            .padding(20)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button(action: viewModel.openPanel) {
                Label("Open", systemImage: "folder")
            }
            .help("Open a .mid or .midi file")
        }

        ToolbarItemGroup(placement: .principal) {
            Button(action: viewModel.play) {
                Label(viewModel.playbackState == .paused ? "Resume" : "Play", systemImage: "play.fill")
            }
            .buttonStyle(.glassProminent)
            .disabled(viewModel.document == nil || viewModel.isArranging)
            .help("Start playback after the countdown")

            Button(action: viewModel.pause) {
                Label("Pause", systemImage: "pause.fill")
            }
            .disabled(viewModel.playbackState != .playing && viewModel.playbackState != .countingDown)

            Button(action: viewModel.stop) {
                Label("Stop", systemImage: "stop.fill")
            }
            .disabled(viewModel.playbackState == .idle || viewModel.playbackState == .stopped)

            Button(action: viewModel.toggleSpeakerPlayback) {
                Label("Listen", systemImage: "speaker.wave.2")
            }
            .disabled(viewModel.document == nil)
            .help("Listen to the original MIDI through your speakers")
        }

        ToolbarItem(placement: .status) {
            statusPill
        }

        ToolbarItem(placement: .primaryAction) {
            Button(action: { openSettings() }) {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings")
        }
    }

    private var statusPill: some View {
        Group {
            if showsSetupPrompt {
                Button(action: { viewModel.showingOnboarding = true }) {
                    Label("Set up NTE playback", systemImage: "exclamationmark.triangle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
            } else {
                Label(statusPillText, systemImage: statusPillIcon)
                    .foregroundStyle(statusPillColor)
            }
        }
        .font(.callout)
        .lineLimit(1)
    }

    private var showsSetupPrompt: Bool {
        !viewModel.readiness.isReady
            && (viewModel.playbackState == .idle || viewModel.playbackState == .stopped)
    }

    private var statusPillText: String {
        switch viewModel.playbackState {
        case .idle: viewModel.document == nil ? "Open a MIDI file" : "Ready"
        case .countingDown: "Get ready\u{2026}"
        case .playing:
            if let silence = viewModel.upcomingSilence {
                "Silent until \(viewModel.formatTime(silence.nextOnset)) \u{00b7} \(Int(silence.remaining))s"
            } else {
                "Playing"
            }
        case .paused: "Paused"
        case .stopped: "Stopped"
        case .completed: "Finished"
        case .lostFocus: "Lost focus on \(acceptedAppName)"
        }
    }

    private var statusPillIcon: String {
        switch viewModel.playbackState {
        case .idle: viewModel.document == nil ? "tray" : "checkmark.circle"
        case .countingDown: "timer"
        case .playing: viewModel.upcomingSilence != nil ? "hourglass" : "play.circle.fill"
        case .paused: "pause.circle"
        case .stopped: "stop.circle"
        case .completed: "checkmark.circle.fill"
        case .lostFocus: "exclamationmark.triangle.fill"
        }
    }

    private var statusPillColor: Color {
        switch viewModel.playbackState {
        case .playing, .completed: .green
        case .lostFocus: .orange
        default: .secondary
        }
    }
}

extension ThemePreference {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

private struct FileSummaryView: View {
    @ObservedObject var viewModel: AppViewModel
    @Binding var isDropTarget: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "music.note.list")
                    .font(.title2)
                VStack(alignment: .leading) {
                    Text(viewModel.document?.displayName ?? "No MIDI loaded")
                        .font(.headline)
                        .lineLimit(1)
                    Text(viewModel.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if viewModel.isArranging {
                    ProgressView().controlSize(.small)
                }
            }

            HStack {
                Text("\(viewModel.mappedEvents.count) playable")
                Spacer()
                Text(viewModel.document.map { viewModel.formatTime($0.duration) } ?? "0:00")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .glassPanel(cornerRadius: 12, opacity: viewModel.settingsStore.settings.glassOpacity)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isDropTarget ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: isDropTarget ? 2 : 1)
        )
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTarget) { providers in
            handleDrop(providers)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = item as? URL
            }
            guard let url else { return }
            Task { @MainActor in
                viewModel.load(url: url)
            }
        }
        return true
    }
}

private struct PlaybackModeView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(
                "Key layout",
                selection: Binding(
                    get: { viewModel.settingsStore.settings.layoutMode },
                    set: { viewModel.setLayoutMode($0) }
                )
            ) {
                ForEach(LayoutMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(isPlaybackActive)

            Text(modeDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !viewModel.readiness.isReady {
                HStack {
                    Label(
                        viewModel.readiness.blockingStep?.title ?? "Setup needed",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    Spacer()
                    Button("Set Up\u{2026}") { viewModel.showingOnboarding = true }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .padding(12)
        .glassPanel(cornerRadius: 10, opacity: viewModel.settingsStore.settings.glassOpacity)
    }

    private var isPlaybackActive: Bool {
        viewModel.playbackState == .playing || viewModel.playbackState == .countingDown
    }

    private var modeDescription: String {
        switch viewModel.settingsStore.settings.layoutMode {
        case .nte36Chromatic:
            "Plays sharps and flats. Needs the Karabiner VirtualHID driver."
        case .nte21Natural:
            "Plays natural notes only. Needs Accessibility permission."
        }
    }
}

private struct ScrubberView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(viewModel.formatTime(viewModel.progressTime))
                Slider(
                    value: Binding(
                        get: { viewModel.seekTime },
                        set: { viewModel.seek(to: $0) }
                    ),
                    in: 0...max(viewModel.duration, 0.01)
                )
                Text(viewModel.formatTime(viewModel.duration))
            }
            .font(.caption)

            ProgressView(value: viewModel.progressFraction)
                .progressViewStyle(.linear)
        }
        .padding(12)
        .glassPanel(cornerRadius: 10, opacity: viewModel.settingsStore.settings.glassOpacity)
    }
}

private struct PreviewLogView: View {
    let logText: String

    var body: some View {
        GroupBox {
            ScrollView {
                Text(logText.isEmpty ? "Preview events will appear here after playback." : logText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(logText.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        } label: {
            Label("Preview Log", systemImage: "terminal")
        }
        .frame(minHeight: 110)
    }
}

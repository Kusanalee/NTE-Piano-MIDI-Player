import NTEPianoMidiPlayerCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var viewModel = AppViewModel()
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            PlaybackToolbarView(viewModel: viewModel)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(minHeight: 44, alignment: .center)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(2)

            Divider()

            WorkspaceView(viewModel: viewModel, isDropTarget: $isDropTarget)
        }
        .sheet(isPresented: $viewModel.showingSettings) {
            SettingsView(settingsStore: viewModel.settingsStore, viewModel: viewModel)
                .frame(width: 520, height: 640)
        }
        .sheet(isPresented: $viewModel.showingSheetExporter) {
            SheetExporterView(viewModel: viewModel)
                .frame(width: 760, height: 620)
        }
        .preferredColorScheme(viewModel.settingsStore.settings.themePreference.colorScheme)
    }
}

private extension ThemePreference {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

private struct PlaybackToolbarView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            regularToolbar
            compactToolbar
        }
    }

    private var regularToolbar: some View {
        HStack(spacing: 10) {
            Button(action: viewModel.openPanel) {
                Label("Open", systemImage: "folder")
            }
            .help("Open a .mid or .midi file")
            .fixedSize(horizontal: true, vertical: false)

            Button(action: viewModel.play) {
                Label(viewModel.playbackState == .paused ? "Resume" : "Play", systemImage: "play.fill")
            }
            .disabled(viewModel.document == nil)
            .help("Start playback after the configured countdown")
            .fixedSize(horizontal: true, vertical: false)

            Button(action: viewModel.pause) {
                Label("Pause", systemImage: "pause.fill")
            }
            .disabled(viewModel.playbackState != .playing && viewModel.playbackState != .countingDown)
            .fixedSize(horizontal: true, vertical: false)

            Button(action: viewModel.stop) {
                Label("Stop", systemImage: "stop.fill")
            }
            .keyboardShortcut(.cancelAction)
            .disabled(viewModel.playbackState == .idle || viewModel.playbackState == .stopped)
            .fixedSize(horizontal: true, vertical: false)

            toolbarDivider

            regularLayoutPicker

            Toggle("Dry-run", isOn: settingsBinding(\.dryRun))
                .toggleStyle(.checkbox)
                .help("Log intended key events without sending CGEvents")
                .fixedSize(horizontal: true, vertical: false)

            Button(action: viewModel.togglePreviewPlayback) {
                Label("Preview", systemImage: "speaker.wave.2")
            }
            .disabled(viewModel.document == nil)
            .help("Preview the MIDI through AVMIDIPlayer")
            .fixedSize(horizontal: true, vertical: false)

            Button(action: { viewModel.showingSheetExporter = true }) {
                Label("Sheet", systemImage: "doc.text")
            }
            .disabled(viewModel.mappedEvents.isEmpty)
            .fixedSize(horizontal: true, vertical: false)

            Spacer()

            statusText

            Button(action: { viewModel.showingSettings = true }) {
                Image(systemName: "gearshape")
            }
            .help("Settings")
        }
    }

    private var compactToolbar: some View {
        HStack(spacing: 8) {
            Button(action: viewModel.openPanel) {
                Label("Open", systemImage: "folder")
                    .labelStyle(.iconOnly)
            }
            .help("Open a .mid or .midi file")

            Button(action: viewModel.play) {
                Label(viewModel.playbackState == .paused ? "Resume" : "Play", systemImage: "play.fill")
                    .labelStyle(.iconOnly)
            }
            .disabled(viewModel.document == nil)
            .help("Start playback after the configured countdown")

            Button(action: viewModel.pause) {
                Label("Pause", systemImage: "pause.fill")
                    .labelStyle(.iconOnly)
            }
            .disabled(viewModel.playbackState != .playing && viewModel.playbackState != .countingDown)

            Button(action: viewModel.stop) {
                Label("Stop", systemImage: "stop.fill")
                    .labelStyle(.iconOnly)
            }
            .keyboardShortcut(.cancelAction)
            .disabled(viewModel.playbackState == .idle || viewModel.playbackState == .stopped)

            toolbarDivider

            statusText

            Spacer(minLength: 6)

            Menu {
                layoutPicker

                Toggle("Dry-run", isOn: settingsBinding(\.dryRun))

                Divider()

                Button(action: viewModel.togglePreviewPlayback) {
                    Label("Preview", systemImage: "speaker.wave.2")
                }
                .disabled(viewModel.document == nil)

                Button(action: { viewModel.showingSheetExporter = true }) {
                    Label("Sheet", systemImage: "doc.text")
                }
                .disabled(viewModel.mappedEvents.isEmpty)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .help("More playback options")

            Button(action: { viewModel.showingSettings = true }) {
                Image(systemName: "gearshape")
            }
            .help("Settings")
        }
        .controlSize(.small)
    }

    private var regularLayoutPicker: some View {
        layoutPicker
            .frame(width: 190)
    }

    private var layoutPicker: some View {
        Picker("Layout", selection: settingsBinding(\.layoutMode)) {
            ForEach(LayoutMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
    }

    private var statusText: some View {
        Text(viewModel.playbackState.rawValue.capitalized)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var toolbarDivider: some View {
        Divider()
            .frame(height: 24)
    }

    private func settingsBinding<Value>(_ keyPath: WritableKeyPath<PlaybackSettings, Value>) -> Binding<Value> {
        Binding(
            get: { viewModel.settingsStore.settings[keyPath: keyPath] },
            set: { viewModel.settingsStore.settings[keyPath: keyPath] = $0 }
        )
    }
}

private struct WorkspaceView: View {
    @ObservedObject var viewModel: AppViewModel
    @Binding var isDropTarget: Bool

    private let compactWidth: CGFloat = 1040

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                Group {
                    if geometry.size.width < compactWidth {
                        compactLayout
                    } else {
                        regularLayout(availableHeight: geometry.size.height)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(minHeight: geometry.size.height, alignment: .topLeading)
            }
        }
    }

    private func regularLayout(availableHeight: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            sidePanel(trackListHeight: max(260, availableHeight - 128))
                .frame(width: 340)
                .padding(14)

            Divider()
                .frame(minHeight: availableHeight)

            mainPanel
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var compactLayout: some View {
        VStack(spacing: 14) {
            sidePanel(trackListHeight: 300)
            mainPanel
        }
        .padding(14)
    }

    private func sidePanel(trackListHeight: CGFloat) -> some View {
        VStack(spacing: 12) {
            FileDropView(viewModel: viewModel, isDropTarget: $isDropTarget)
            TrackListView(viewModel: viewModel)
                .frame(height: trackListHeight)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var mainPanel: some View {
        VStack(spacing: 12) {
            ProgressStripView(viewModel: viewModel)
            KeyboardPreviewView(settings: viewModel.settingsStore.settings)
            DiagnosticsView(diagnostics: viewModel.diagnostics)
            DryRunLogView(logText: viewModel.dryRunLogText)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct FileDropView: View {
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
            }

            HStack {
                Text("\(viewModel.mappedEvents.count) playable")
                Spacer()
                Text(viewModel.document.map { viewModel.formatTime($0.duration) } ?? "0:00")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(isDropTarget ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isDropTarget ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: 1)
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

private struct ProgressStripView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
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

                HStack {
                    Stepper(
                        "Transpose \(viewModel.settingsStore.settings.globalTranspose)",
                        value: settingsBinding(\.globalTranspose),
                        in: -24...24
                    )
                    Stepper(
                        "Octave \(viewModel.settingsStore.settings.octaveShift)",
                        value: settingsBinding(\.octaveShift),
                        in: -3...3
                    )
                    Spacer()
                    Text("Tempo \(String(format: "%.2fx", viewModel.settingsStore.settings.tempoMultiplier))")
                    Slider(value: settingsBinding(\.tempoMultiplier), in: 0.25...2.0)
                        .frame(width: 140)
                }
                .font(.caption)
            }
        } label: {
            Label("Timeline", systemImage: "timeline.selection")
        }
    }

    private func settingsBinding<Value>(_ keyPath: WritableKeyPath<PlaybackSettings, Value>) -> Binding<Value> {
        Binding(
            get: { viewModel.settingsStore.settings[keyPath: keyPath] },
            set: { viewModel.settingsStore.settings[keyPath: keyPath] = $0 }
        )
    }
}

private struct DryRunLogView: View {
    let logText: String

    var body: some View {
        GroupBox {
            ScrollView {
                Text(logText.isEmpty ? "Dry-run events will appear here after playback." : logText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(logText.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        } label: {
            Label("Dry-run Log", systemImage: "terminal")
        }
        .frame(minHeight: 110)
    }
}

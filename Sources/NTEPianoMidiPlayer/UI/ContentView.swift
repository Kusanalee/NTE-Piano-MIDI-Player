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

            Divider()

            HStack(spacing: 0) {
                VStack(spacing: 12) {
                    FileDropView(viewModel: viewModel, isDropTarget: $isDropTarget)
                    TrackListView(viewModel: viewModel)
                }
                .frame(width: 340)
                .padding(14)

                Divider()

                VStack(spacing: 12) {
                    ProgressStripView(viewModel: viewModel)
                    KeyboardPreviewView(settings: viewModel.settingsStore.settings)
                    DiagnosticsView(diagnostics: viewModel.diagnostics)
                    DryRunLogView(logText: viewModel.dryRunLogText)
                }
                .padding(14)
            }
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
        HStack(spacing: 10) {
            Button(action: viewModel.openPanel) {
                Label("Open", systemImage: "folder")
            }
            .help("Open a .mid or .midi file")

            Button(action: viewModel.play) {
                Label(viewModel.playbackState == .paused ? "Resume" : "Play", systemImage: "play.fill")
            }
            .disabled(viewModel.document == nil)
            .help("Start playback after the configured countdown")

            Button(action: viewModel.pause) {
                Label("Pause", systemImage: "pause.fill")
            }
            .disabled(viewModel.playbackState != .playing && viewModel.playbackState != .countingDown)

            Button(action: viewModel.stop) {
                Label("Stop", systemImage: "stop.fill")
            }
            .keyboardShortcut(.cancelAction)
            .disabled(viewModel.playbackState == .idle || viewModel.playbackState == .stopped)

            Divider()
                .frame(height: 24)

            Picker("Layout", selection: settingsBinding(\.layoutMode)) {
                ForEach(LayoutMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .frame(width: 190)

            Toggle("Dry-run", isOn: settingsBinding(\.dryRun))
                .toggleStyle(.checkbox)
                .help("Log intended key events without sending CGEvents")

            Button(action: viewModel.togglePreviewPlayback) {
                Label("Preview", systemImage: "speaker.wave.2")
            }
            .disabled(viewModel.document == nil)
            .help("Preview the MIDI through AVMIDIPlayer")

            Button(action: { viewModel.showingSheetExporter = true }) {
                Label("Sheet", systemImage: "doc.text")
            }
            .disabled(viewModel.mappedEvents.isEmpty)

            Spacer()

            Text(viewModel.playbackState.rawValue.capitalized)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(action: { viewModel.showingSettings = true }) {
                Image(systemName: "gearshape")
            }
            .help("Settings")
        }
    }

    private func settingsBinding<Value>(_ keyPath: WritableKeyPath<PlaybackSettings, Value>) -> Binding<Value> {
        Binding(
            get: { viewModel.settingsStore.settings[keyPath: keyPath] },
            set: { viewModel.settingsStore.settings[keyPath: keyPath] = $0 }
        )
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

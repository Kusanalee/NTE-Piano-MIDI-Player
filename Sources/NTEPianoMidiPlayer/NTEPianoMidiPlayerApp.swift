import NTEPianoMidiPlayerCore
import SwiftUI

@main
struct NTEPianoMidiPlayerApp: App {
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 820, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open\u{2026}", action: viewModel.openPanel)
                    .keyboardShortcut("o", modifiers: .command)

                Menu("Open Recent") {
                    if viewModel.settingsStore.recentFiles.isEmpty {
                        Text("No Recent Files")
                    } else {
                        ForEach(viewModel.settingsStore.recentFiles, id: \.self) { url in
                            Button(url.lastPathComponent) { viewModel.load(url: url) }
                        }
                    }
                }
            }

            if viewModel.settingsStore.settings.advancedSettingsEnabled {
                CommandGroup(after: .saveItem) {
                    Button("Export Piano Sheet\u{2026}") { viewModel.showingSheetExporter = true }
                        .disabled(viewModel.mappedEvents.isEmpty)
                }
            }

            CommandMenu("Playback") {
                Button(playPauseTitle, action: playPauseAction)
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(playPauseDisabled)

                Button("Stop", action: viewModel.stop)
                    .keyboardShortcut(stopShortcut)
                    .disabled(viewModel.playbackState == .idle || viewModel.playbackState == .stopped)
            }

            CommandGroup(after: .help) {
                Button("Setup Assistant") { viewModel.showingOnboarding = true }
            }
        }

        Settings {
            SettingsView(settingsStore: viewModel.settingsStore, viewModel: viewModel)
        }
    }

    private var playPauseTitle: String {
        switch viewModel.playbackState {
        case .playing, .countingDown: "Pause"
        case .paused: "Resume"
        default: "Play"
        }
    }

    private var playPauseDisabled: Bool {
        switch viewModel.playbackState {
        case .playing, .countingDown, .paused: false
        default: viewModel.document == nil || viewModel.isArranging
        }
    }

    private func playPauseAction() {
        switch viewModel.playbackState {
        case .playing, .countingDown: viewModel.pause()
        case .paused: viewModel.resume()
        default: viewModel.play()
        }
    }

    private var stopShortcut: KeyboardShortcut {
        switch viewModel.settingsStore.settings.emergencyStopHotkey {
        case .escape: KeyboardShortcut(.escape, modifiers: [])
        case .commandPeriod: KeyboardShortcut(".", modifiers: [.command])
        }
    }
}

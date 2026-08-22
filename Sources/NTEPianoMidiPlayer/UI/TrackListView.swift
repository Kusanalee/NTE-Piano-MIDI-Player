import NTEPianoMidiPlayerCore
import SwiftUI

struct TrackListView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Filter tracks", text: $viewModel.searchText)
                    .textFieldStyle(.roundedBorder)

                Text("Mute silences a track. Solo plays only soloed tracks, even if unchecked. Mute overrides Solo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if viewModel.tracks.isEmpty {
                    Text("Open a MIDI file to inspect tracks.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    List {
                        ForEach(viewModel.filteredTrackIndices, id: \.self) { index in
                            trackRow(index)
                        }
                    }
                    .listStyle(.inset)
                }
            }
        } label: {
            Label("Tracks", systemImage: "slider.horizontal.3")
        }
    }

    private func trackRow(_ index: Int) -> some View {
        let track = viewModel.tracks[index]
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("", isOn: trackBinding(index, \.isEnabled))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(detailText(for: track))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Toggle("Mute", isOn: trackBinding(index, \.isMuted))
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Silence this track. A muted track does not play, even when soloed.")
                Toggle("Solo", isOn: trackBinding(index, \.isSoloed))
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Play only soloed tracks, even if they are unchecked. If no track is soloed, all enabled, unmuted tracks play.")
            }
        }
        .padding(.vertical, 4)
    }

    private func trackBinding(_ index: Int, _ keyPath: WritableKeyPath<MidiTrackInfo, Bool>) -> Binding<Bool> {
        Binding(
            get: { viewModel.tracks[index][keyPath: keyPath] },
            set: {
                viewModel.tracks[index][keyPath: keyPath] = $0
                viewModel.refreshMapping()
            }
        )
    }

    private func detailText(for track: MidiTrackInfo) -> String {
        let channel = track.channel.map { "Ch \($0 + 1)" } ?? "Ch -"
        let program = track.instrumentProgram.map { "Program \($0)" } ?? "Program -"
        let instrument = track.instrumentName.map { " · \($0)" } ?? ""
        return "\(channel) · \(program) · \(track.noteCount) notes\(instrument)"
    }
}

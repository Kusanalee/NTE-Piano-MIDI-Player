import NTEPianoMidiPlayerCore
import SwiftUI

struct TrackListView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Filter tracks", text: $viewModel.searchText)
                    .textFieldStyle(.roundedBorder)

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
                Toggle("M", isOn: trackBinding(index, \.isMuted))
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Mute")
                Toggle("S", isOn: trackBinding(index, \.isSoloed))
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Solo")
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

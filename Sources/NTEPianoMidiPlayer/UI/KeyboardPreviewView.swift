import NTEPianoMidiPlayerCore
import SwiftUI

struct KeyboardPreviewView: View {
    let settings: PlaybackSettings

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                ForEach([PianoRow.tre, .mid, .bas]) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.rawValue)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(keys(for: row)) { key in
                                KeyPreviewCell(key: key)
                            }
                        }
                    }
                }
            }
        } label: {
            Label("NTE Keyboard", systemImage: "pianokeys")
        }
    }

    private var columns: [GridItem] {
        let count = settings.layoutMode == .nte21Natural ? 7 : 12
        return Array(repeating: GridItem(.flexible(minimum: 42), spacing: 6), count: count)
    }

    private func keys(for row: PianoRow) -> [PianoKey] {
        NTELayout.keys(for: settings.layoutMode, baseMidiNote: settings.baseMidiNoteForBAS1)[row] ?? []
    }
}

private struct KeyPreviewCell: View {
    let key: PianoKey

    var body: some View {
        VStack(spacing: 2) {
            Text(key.degreeLabel)
                .font(.caption2.weight(.semibold))
            Text(key.keyboardLabel)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            Text(key.noteName)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 48)
        .padding(.vertical, 5)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }

    private var background: Color {
        switch key.modifier {
        case .none: Color(nsColor: .controlBackgroundColor)
        case .shift: Color.blue.opacity(0.12)
        case .control: Color.green.opacity(0.12)
        }
    }
}

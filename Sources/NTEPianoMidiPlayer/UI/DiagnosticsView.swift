import NTEPianoMidiPlayerCore
import SwiftUI

struct DiagnosticsView: View {
    let diagnostics: MappingDiagnostics

    var body: some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    stat("Input", diagnostics.totalInputNotes)
                    stat("Mapped", diagnostics.mappedNotes)
                    stat("Skipped", diagnostics.notesSkipped)
                    stat("Snapped", diagnostics.notesSnapped)
                }
                GridRow {
                    stat("Below", diagnostics.notesBelowRange)
                    stat("Above", diagnostics.notesAboveRange)
                    stat("Merged", diagnostics.duplicateNotesMerged)
                    stat("Big chords", diagnostics.chordsExceedingLimit)
                }
            }

            if diagnostics.hasWarnings {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(diagnostics.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        } label: {
            Label("Range Diagnostics", systemImage: "waveform.path.ecg")
        }
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.headline.monospacedDigit())
        }
    }
}

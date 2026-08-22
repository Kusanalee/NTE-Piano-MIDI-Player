import NTEPianoMidiPlayerCore
import SwiftUI

struct DiagnosticsView: View {
    @ObservedObject var viewModel: AppViewModel

    private var diagnostics: MappingDiagnostics { viewModel.diagnostics }

    var body: some View {
        VStack(spacing: 12) {
            rangeDiagnostics
            keyboardEventRecorder
            virtualHIDReportTrace
        }
    }

    private var rangeDiagnostics: some View {
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
                GridRow {
                    stat("Folded", diagnostics.notesRangeFolded)
                    stat("Collisions", diagnostics.collisionNotesMerged)
                    stat("Density", diagnostics.densityNotesMerged)
                    stat("Omitted", diagnostics.chordTonesOmitted)
                }
                GridRow {
                    stat("Percussion", diagnostics.percussionNotesOmitted)
                    stat("Layer exact", diagnostics.modifierExactNotes)
                    stat("Auto shift", diagnostics.automaticTranspose)
                    stat("Expression", diagnostics.unsupportedExpressionEvents)
                }
                GridRow {
                    stat("Rolled", diagnostics.crossLayerChordsRolled)
                    stat("Timing drops", diagnostics.timingConstrainedTonesOmitted)
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

    private var keyboardEventRecorder: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Records events seen at the HID event tap using Accessibility permission. PLAYER marks Quartz events tagged by this app. VirtualHID uses the hardware path and can appear as EXTERNAL with pid=0, like a physical keyboard; correlate it with the report trace below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    if viewModel.isRecordingKeyboardEvents {
                        Button("Stop Recording", action: viewModel.stopKeyboardEventRecording)
                    } else {
                        Button("Start Recording", action: viewModel.startKeyboardEventRecording)
                    }
                    Button("Clear", action: viewModel.clearKeyboardEventRecording)
                    Button("Copy Trace", action: viewModel.copyKeyboardEventTrace)
                    Spacer()
                    if viewModel.isRecordingKeyboardEvents {
                        Label("Recording", systemImage: "record.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                ScrollView([.horizontal, .vertical]) {
                    Text(viewModel.keyboardEventTraceText)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                .frame(minHeight: 110, maxHeight: 180)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        } label: {
            Label("Input Event Recorder", systemImage: "waveform.badge.magnifyingglass")
        }
    }

    private var virtualHIDReportTrace: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(viewModel.virtualHIDStatus.guidance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh Status", action: viewModel.refreshVirtualHIDStatus)
                }
                ScrollView([.horizontal, .vertical]) {
                    Text(viewModel.virtualHIDReportTraceText)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                .frame(minHeight: 90, maxHeight: 150)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        } label: {
            Label("VirtualHID Report Trace", systemImage: "keyboard.badge.ellipsis")
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

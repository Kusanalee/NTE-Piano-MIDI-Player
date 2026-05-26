import NTEPianoMidiPlayerCore
import SwiftUI

struct SheetExporterView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Piano Sheet")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Copy", action: viewModel.copySheetToClipboard)
                Button("Done") { dismiss() }
            }
            .padding()

            Divider()

            HStack(spacing: 16) {
                Form {
                    Toggle("Show note names", isOn: optionBinding(\.showNoteNames))
                    Toggle("Show scale degrees", isOn: optionBinding(\.showScaleDegrees))
                    Toggle("Show keyboard keys", isOn: optionBinding(\.showKeyboardKeys))
                    Toggle("Chord brackets", isOn: optionBinding(\.useChordBrackets))
                    TextField("Delimiter", text: optionBinding(\.delimiter))
                    Stepper("Line length: \(viewModel.sheetOptions.lineLength)", value: optionBinding(\.lineLength), in: 1...64)
                }
                .frame(width: 260)

                TextEditor(text: $viewModel.sheetText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            .padding()
        }
    }

    private func optionBinding<Value>(_ keyPath: WritableKeyPath<PianoSheetOptions, Value>) -> Binding<Value> {
        Binding(
            get: { viewModel.sheetOptions[keyPath: keyPath] },
            set: { viewModel.sheetOptions[keyPath: keyPath] = $0 }
        )
    }
}

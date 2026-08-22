import NTEPianoMidiPlayerCore
import SwiftUI

/// A full-window Liquid Glass overlay shown while `playbackState == .countingDown`. This is
/// the app's one job: tell the player which app to switch to, count down loudly enough that
/// they don't miss it, and offer a way out.
struct CountdownOverlayView: View {
    let remaining: TimeInterval
    let onCancel: () -> Void

    private var wholeSeconds: Int {
        max(0, Int(remaining.rounded(.up)))
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)

                Text("Switch to Neverness to Everness")
                    .font(.title)
                    .fontWeight(.semibold)

                Text("Open the in-game piano before the countdown ends.")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                Text("\(wholeSeconds)")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy, value: wholeSeconds)
                    .foregroundStyle(.tint)
                    .accessibilityLabel("\(wholeSeconds) seconds remaining")

                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(48)
            .glassPanel(cornerRadius: 28, opacity: 1)
            .frame(maxWidth: 420)
        }
        .transition(.opacity)
    }
}

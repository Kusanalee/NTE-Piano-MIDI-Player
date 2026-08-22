import AppKit
import NTEPianoMidiPlayerCore
import SwiftUI

/// First-run setup wizard. Walks a new user from "just downloaded the app" to "ready to
/// play": install the virtual keyboard driver, approve it, install the background services
/// that run it, and (for 21-key mode) grant Accessibility. Each step's status row updates
/// live as its condition is detected, but the user always confirms with Continue.
struct OnboardingView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var pageIndex = 0
    @State private var showingInstallConfirmation = false
    @State private var showingManualCommands = false

    private enum Page: Equatable {
        case welcome
        case installDriver
        case activateExtension
        case installServices
        case accessibility
        case done

        var setupStep: SetupStep? {
            switch self {
            case .installDriver: .installDriver
            case .activateExtension: .activateExtension
            case .installServices: .installServices
            case .accessibility: .grantAccessibility
            case .welcome, .done: nil
            }
        }
    }

    private var pages: [Page] {
        switch viewModel.settingsStore.settings.layoutMode {
        case .nte36Chromatic:
            [.welcome, .installDriver, .activateExtension, .installServices, .done]
        case .nte21Natural:
            [.welcome, .accessibility, .done]
        }
    }

    private var currentPage: Page {
        let all = pages
        return all.indices.contains(pageIndex) ? all[pageIndex] : (all.last ?? .welcome)
    }

    /// Only the pages that represent an actual setup step (excludes welcome/done), so the
    /// footer's "Step N of M" counts real work instead of the wizard's own bookend pages.
    private var stepPages: [Page] {
        pages.filter { $0.setupStep != nil }
    }

    private var currentStepNumber: Int? {
        stepPages.firstIndex(of: currentPage).map { $0 + 1 }
    }

    private var canContinue: Bool {
        currentPage.setupStep.map(isStepSatisfied) ?? true
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(32)

            if pageIndex > 0, currentPage != .done {
                Divider()
                HStack {
                    Button("Back") { pageIndex = max(0, pageIndex - 1) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if stepPages.count > 1, let stepNumber = currentStepNumber {
                        Text("Step \(stepNumber) of \(stepPages.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    Button("Continue") { pageIndex = min(pageIndex + 1, pages.count - 1) }
                        .buttonStyle(.glassProminent)
                        .disabled(!canContinue)
                }
                .padding(16)
            }
        }
        .frame(width: 560, height: 560)
        .background {
            RoundedRectangle(cornerRadius: 0).fill(.clear)
        }
        .onAppear { viewModel.startReadinessPolling() }
        .onDisappear { viewModel.stopReadinessPolling() }
    }

    @ViewBuilder
    private var content: some View {
        switch currentPage {
        case .welcome:
            welcomePage
        case .installDriver:
            installDriverPage
        case .activateExtension:
            activateExtensionPage
        case .installServices:
            installServicesPage
        case .accessibility:
            accessibilityPage
        case .done:
            donePage
        }
    }

    private var welcomePage: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "pianokeys")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Welcome to NTE Piano MIDI Player")
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text("Open a MIDI file, press Play, and this app plays it on NTE's in-game piano for you. Let's get your Mac ready.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button("Get Started") { pageIndex = firstIncompletePageIndex() }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
        }
    }

    private var installDriverPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Install the virtual keyboard driver")
                .font(.title2.bold())
            Text("NTE's piano supports 36 keys, but it ignores the synthetic Shift and Control presses macOS apps normally send. To play sharps and flats, this app sends key presses through a real virtual keyboard driver instead \u{2014} Karabiner DriverKit VirtualHIDDevice.")
                .foregroundStyle(.secondary)

            statusRow(for: .installDriver, doneLabel: "Driver installed", pendingLabel: "Not installed yet")

            Button("Open Download Page") { viewModel.openVirtualHIDReleasePage() }
                .buttonStyle(.glass)

            Spacer()

            Divider()
            Button("Skip \u{2014} use 21-key natural instead") {
                viewModel.skipToTwentyOneKey()
                pageIndex = 1
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            Text("Without the driver, 36-key chromatic playback (sharps and flats) won't work, but 21-key natural mode plays every natural note without it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var activateExtensionPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Approve the system extension")
                .font(.title2.bold())
            Text("macOS requires your approval before any app can use a virtual keyboard driver. Click Activate, then approve it in System Settings if you're prompted.")
                .foregroundStyle(.secondary)

            statusRow(for: .activateExtension, doneLabel: "Extension approved", pendingLabel: "Not approved yet")

            HStack {
                Button("Activate") { viewModel.activateDriverExtension() }
                    .buttonStyle(.glassProminent)
                Button("Open System Settings") { openLoginItemsSettings() }
                    .buttonStyle(.glass)
            }

            Spacer()
        }
    }

    private var installServicesPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up background services")
                .font(.title2.bold())
            Text("This installs two small background services so Karabiner's driver and this app's bridge start automatically at login. You'll be asked for your administrator password once.")
                .foregroundStyle(.secondary)

            statusRow(for: .installServices, doneLabel: "Services running", pendingLabel: viewModel.readiness.detail ?? "Not set up yet")

            HStack {
                Button("Install") { showingInstallConfirmation = true }
                    .buttonStyle(.glassProminent)
                    .disabled(viewModel.isInstallingServices)
                if viewModel.isInstallingServices {
                    ProgressView().controlSize(.small)
                }
            }

            if let error = viewModel.setupActionError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            DisclosureGroup("Can't grant administrator access?", isExpanded: $showingManualCommands) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Run these commands in Terminal instead:")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(viewModel.virtualHIDSetupCommands)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Button("Copy Commands", action: viewModel.copyVirtualHIDSetupCommands)
                        .buttonStyle(.glass)
                }
                .padding(.top, 8)
            }

            Spacer()
        }
        .alert("Install background services?", isPresented: $showingInstallConfirmation) {
            Button("Install", action: viewModel.installPrivilegedServices)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(PrivilegedServiceInstaller.installSummary.joined(separator: "\n"))
        }
    }

    private var accessibilityPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Grant Accessibility permission")
                .font(.title2.bold())
            Text("21-key natural mode sends key presses through macOS's standard Accessibility APIs. Grant permission so this app can send them to NTE.")
                .foregroundStyle(.secondary)

            statusRow(for: .grantAccessibility, doneLabel: "Permission granted", pendingLabel: "Not granted yet")

            Button("Open Accessibility Settings", action: viewModel.openAccessibilitySettings)
                .buttonStyle(.glassProminent)

            Spacer()
        }
    }

    private var donePage: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("You're all set")
                .font(.title.bold())
            Text("Open a MIDI file and press Play. When it's time, this app will tell you to switch to NTE and count down before it starts playing.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button("Start Using the App") {
                viewModel.completeOnboarding()
                dismiss()
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
    }

    @ViewBuilder
    private func statusRow(for step: SetupStep, doneLabel: String, pendingLabel: String) -> some View {
        let satisfied = isStepSatisfied(step)
        Label(satisfied ? doneLabel : pendingLabel, systemImage: satisfied ? "checkmark.circle.fill" : "circle.dashed")
            .foregroundStyle(satisfied ? .green : .secondary)
            .font(.callout)
    }

    private func isStepSatisfied(_ step: SetupStep) -> Bool {
        guard let blocking = viewModel.readiness.blockingStep else { return true }
        return blocking.rawValue > step.rawValue
    }

    /// Where "Get Started" and a manually-reopened assistant should land: the first page whose
    /// step isn't satisfied yet, or the done page when everything already is.
    private func firstIncompletePageIndex() -> Int {
        for index in pages.indices where index > 0 {
            if let step = pages[index].setupStep, !isStepSatisfied(step) { return index }
        }
        return pages.count - 1
    }

    private func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

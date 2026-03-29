import SwiftUI

struct SetupView: View {
    @ObservedObject var viewModel: SetupViewModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
                .frame(height: 40)

            headerSection

            if !viewModel.helperFailed {
                optionsSection
            }

            Spacer()

            errorSection

            buttonSection

            Spacer()
                .frame(height: 24)
        }
        .frame(width: 380, height: 420)
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(spacing: 8) {
            if viewModel.helperFailed {
                Text("Muninn could not start its background service.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                Text("Try quitting and reopening the app.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Text(viewModel.helperManager.status == .running
                     ? "Muninn is running."
                     : "Starting up\u{2026}")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)

                Text("Your clipboard history is stored locally on this Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 32)
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Start Muninn at login", isOn: $viewModel.launchAtLogin)
                .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 2) {
                Toggle("Install command-line tool", isOn: $viewModel.installCLI)
                    .toggleStyle(.checkbox)

                Text("Adds the muninn command to your terminal.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 20)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 48)
        .padding(.top, 28)
    }

    private var errorSection: some View {
        VStack(spacing: 4) {
            if let error = viewModel.loginError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
            if let error = viewModel.cliError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 8)
    }

    private var buttonSection: some View {
        Group {
            if viewModel.helperFailed {
                Button("Quit") {
                    viewModel.quit()
                }
            } else {
                Button("Done") {
                    viewModel.done()
                }
                .disabled(!viewModel.canDismiss)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
    }
}

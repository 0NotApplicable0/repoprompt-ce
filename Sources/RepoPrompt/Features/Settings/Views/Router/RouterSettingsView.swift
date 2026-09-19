import SwiftUI

struct RouterSettingsView: View {
    @ObservedObject var viewModel: RouterSettingsViewModel
    @State private var candidateKey = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Model Router")
                    .font(.title2.bold())
                Text("Optionally ask a configured routing backend to choose among existing Agent Mode role targets. RepoPrompt remains responsible for provider execution, credentials, permissions, sessions, and cancellation.")
                    .foregroundStyle(.secondary)

                GroupBox("Routing backend") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Backend", selection: selectedBackendBinding) {
                            Text("Choose…").tag(AgentTaskRouterBackendID?.none)
                            ForEach(viewModel.backendOptions) { option in
                                Text(option.displayName).tag(Optional(option.id))
                            }
                        }
                        .pickerStyle(.menu)

                        if viewModel.selectedBackendID == .jev {
                            JevRouterSettingsSection(
                                candidateKey: $candidateKey,
                                isBusy: viewModel.isPerformingCredentialOperation,
                                operationMessage: viewModel.operationMessage,
                                validate: {
                                    let key = candidateKey
                                    Task {
                                        await viewModel.validateAndSaveJevKey(key)
                                        candidateKey = ""
                                    }
                                },
                                revalidate: { Task { await viewModel.revalidateStoredJevKey() } },
                                remove: { Task { await viewModel.removeJevKey() } }
                            )
                        }
                    }
                    .padding(8)
                }

                GroupBox("Status") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(readinessTitle, systemImage: readinessIcon)
                        if let detail = readinessDetail {
                            Text(detail).font(.callout).foregroundStyle(.secondary)
                        }
                        Toggle("Enable Model Router", isOn: Binding(
                            get: { viewModel.configuration.enabled },
                            set: viewModel.setEnabled
                        ))
                        .disabled(!viewModel.canEnable && !viewModel.configuration.enabled)
                        if !viewModel.readiness.isReady {
                            Text("The composer control stays hidden until the selected backend has validated configuration and a reviewed accepting policy.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                }

                GroupBox("Privacy") {
                    Text("For an eligible one-shot route, the selected backend receives the exact task text and opaque role rubrics only. RepoPrompt does not send workspace names, paths, selected files, file contents, diffs, provider/model identifiers, transcripts, system prompts, tools, or credentials.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }

                HStack {
                    Link("TypeSafe API documentation", destination: URL(string: "https://docs.typesafe.ai/api")!)
                    Link("TypeSafe privacy policy", destination: URL(string: "https://typesafe.ai/legal/privacy-policy")!)
                }
                .font(.caption)
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .task { await viewModel.refresh() }
    }

    private var selectedBackendBinding: Binding<AgentTaskRouterBackendID?> {
        Binding(get: { viewModel.selectedBackendID }, set: { id in
            if let id { viewModel.selectBackend(id) }
        })
    }

    private var readinessTitle: String {
        switch viewModel.readiness {
        case .ready: "Ready"
        case .validating: "Validating backend configuration…"
        case .needsConfiguration: "Configuration required"
        case .policyUnavailable: "Routing policy unavailable"
        case .temporarilyUnavailable: "Backend unavailable"
        }
    }

    private var readinessDetail: String? {
        switch viewModel.readiness {
        case let .ready(_, policy): "Policy \(policy)"
        case .validating: nil
        case let .needsConfiguration(_, reason),
             let .policyUnavailable(_, reason),
             let .temporarilyUnavailable(_, reason): reason
        }
    }

    private var readinessIcon: String {
        viewModel.readiness.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle"
    }
}

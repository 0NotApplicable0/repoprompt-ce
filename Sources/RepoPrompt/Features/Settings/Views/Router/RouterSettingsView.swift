import SwiftUI

struct RouterSettingsView: View {
    @ObservedObject var viewModel: RouterSettingsViewModel
    @State private var candidateSecret = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Model Router").font(.title2.bold())
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
                        if let presentation = viewModel.backendSettingsPresentation {
                            backendSettings(presentation)
                        }
                    }
                    .padding(8)
                }

                GroupBox("Candidate policy") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Eligible roles").font(.headline)
                        ForEach(AgentModelCatalog.TaskLabelKind.allCases, id: \.rawValue) { role in
                            Toggle(role.rawValue.capitalized, isOn: Binding(
                                get: { viewModel.eligibleRoles.contains(role) },
                                set: { viewModel.setRole(role, enabled: $0) }
                            ))
                        }
                        Divider()
                        Text("Allowed providers").font(.headline)
                        ForEach(Array(viewModel.availableProviders).sorted(by: { $0.rawValue < $1.rawValue }), id: \.rawValue) { provider in
                            Toggle(provider.rawValue, isOn: Binding(
                                get: { viewModel.isProviderAllowed(provider) },
                                set: { viewModel.setProvider(provider, enabled: $0) }
                            ))
                        }
                        Text("On first enable, empty role/provider policy is materialized as all currently available choices. Later providers remain opt-in.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                            Text("The composer control stays unavailable until the selected backend has validated configuration and RepoPrompt ships a reviewed accepting policy.")
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
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .task { await viewModel.refresh() }
    }

    @ViewBuilder
    private func backendSettings(_ presentation: AgentTaskRouterBackendSettingsPresentation) -> some View {
        Divider()
        Text(presentation.title).font(.headline)
        Text(presentation.configurationDetail).font(.caption).foregroundStyle(.secondary)
        if let label = presentation.secretFieldLabel {
            SecureField(label, text: $candidateSecret)
            HStack {
                Button("Validate & Save") {
                    let secret = candidateSecret
                    Task {
                        await viewModel.performBackendAction(.validateAndSaveSecret(secret))
                        candidateSecret = ""
                    }
                }
                .disabled(candidateSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isPerformingBackendOperation)
                Button("Revalidate Stored Secret") {
                    Task { await viewModel.performBackendAction(.revalidateStoredSecret) }
                }
                .disabled(viewModel.isPerformingBackendOperation)
                Button("Remove Secret", role: .destructive) {
                    Task { await viewModel.performBackendAction(.removeStoredSecret) }
                }
                .disabled(viewModel.isPerformingBackendOperation)
                if viewModel.isPerformingBackendOperation { ProgressView().controlSize(.small) }
            }
        }
        if let operationMessage = viewModel.operationMessage {
            Text(operationMessage).font(.caption).foregroundStyle(.secondary)
        }
        HStack {
            ForEach(presentation.links) { link in Link(link.title, destination: link.url) }
        }
        .font(.caption)
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

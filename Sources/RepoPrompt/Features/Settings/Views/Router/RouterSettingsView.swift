import SwiftUI

struct RouterSettingsView: View {
    @ObservedObject var viewModel: RouterSettingsViewModel
    var onNavigate: ((SettingsTab) -> Void)?
    @Environment(\.repoPromptFontScalePreset) private var fontPreset
    @State private var candidateSecret = ""
    @State private var customInstructionsDraft = ""
    @State private var customInstructionsFeedback: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                statusCard
                backendCard
                routingPolicyCard
                candidatesCard
                privacyNotice
            }
            .font(fontPreset.swiftUIFont(sizeAtNormal: 13))
            .frame(maxWidth: 740, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task {
            await viewModel.refresh()
            customInstructionsDraft = viewModel.configuration.customInstructions
        }
        .onChange(of: viewModel.selectedBackendID) { _, _ in candidateSecret = "" }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Model Router", systemImage: "arrow.triangle.branch")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 22, weight: .bold))
            Text("Let Jev choose the best configured model, provider, and reasoning effort for each new task.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusCard: some View {
        card {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: readinessIcon)
                    .font(.title3)
                    .foregroundStyle(viewModel.canEnable ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    Text(readinessTitle).font(.headline)
                    Text(readinessDetail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Toggle("Enable Model Router", isOn: Binding(
                    get: { viewModel.configuration.enabled },
                    set: viewModel.setEnabled
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!viewModel.canEnable && !viewModel.configuration.enabled)
                .accessibilityLabel("Enable Model Router")
            }
            if viewModel.canEnable || viewModel.configuration.enabled {
                Text("When enabled, Router chooses the target for every new primary session and RepoPrompt-managed subagent. Existing sessions keep their established target.")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var routingPolicyCard: some View {
        card {
            Label("Routing behavior", systemImage: "slider.horizontal.3").font(.headline)
            Text("Optionally limit each session type to one provider. Leave a limit unset to let Jev choose among all allowed providers.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            providerLimitPicker("Primary sessions", scope: .primarySession)
            providerLimitPicker("Subagents", scope: .subagent)
            Divider()
            Text("Custom guidance").font(.headline)
            Text("Use this for soft preferences such as “Prefer Claude Opus for execution, use GPT Astra sparingly, consult Fable for hard decisions.” Jev receives this text with every routing request.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $customInstructionsDraft)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                .frame(minHeight: 70, maxHeight: 110)
                .padding(6)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            HStack {
                Text("\(customInstructionsDraft.count)/1000")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .foregroundStyle(customInstructionsDraft.count > 1000 ? Color.red : Color.secondary)
                Spacer()
                if let customInstructionsFeedback {
                    Text(customInstructionsFeedback)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                        .foregroundStyle(.secondary)
                }
                Button("Save Guidance") {
                    if viewModel.setCustomInstructions(customInstructionsDraft) {
                        customInstructionsDraft = viewModel.configuration.customInstructions
                        customInstructionsFeedback = "Saved"
                    } else {
                        customInstructionsFeedback = "Guidance is too long"
                    }
                }
                .disabled(
                    customInstructionsDraft == viewModel.configuration.customInstructions
                        || customInstructionsDraft.count > 1000
                )
            }
        }
    }

    private func providerLimitPicker(
        _ title: String,
        scope: AgentTaskRoutingScope
    ) -> some View {
        Picker(title, selection: Binding(
            get: { viewModel.providerLimit(for: scope) },
            set: { viewModel.setProviderLimit($0, scope: scope) }
        )) {
            Text("Any allowed provider").tag(AgentProviderKind?.none)
            ForEach(viewModel.visibleProviders.filter {
                viewModel.isProviderAllowed($0) || viewModel.providerLimit(for: scope) == $0
            }, id: \.rawValue) { provider in
                Text(provider.displayName).tag(Optional(provider))
            }
        }
        .pickerStyle(.menu)
    }

    private var backendCard: some View {
        card {
            Label("Routing service", systemImage: "network").font(.headline)
            if viewModel.backendOptions.count == 1, let service = viewModel.backendOptions.first {
                LabeledContent("Service") {
                    Text(service.displayName).fontWeight(.medium)
                }
            } else {
                Picker("Service", selection: selectedBackendBinding) {
                    if viewModel.selectedBackendID == nil {
                        Text("Choose a service…").tag(AgentTaskRouterBackendID?.none)
                    }
                    if let selected = viewModel.selectedBackendID,
                       !viewModel.backendOptions.contains(where: { $0.id == selected })
                    {
                        Text("\(selected.rawValue) (unavailable)").tag(Optional(selected))
                    }
                    ForEach(viewModel.backendOptions) { option in
                        Text(option.displayName).tag(Optional(option.id))
                    }
                }
                .pickerStyle(.menu)
                .disabled(viewModel.isPerformingBackendOperation)
            }
            if let presentation = viewModel.backendSettingsPresentation {
                backendSettings(presentation)
            }
        }
    }

    private var candidatesCard: some View {
        card {
            HStack {
                Label("Routing targets", systemImage: "square.stack.3d.up").font(.headline)
                Spacer()
                Text("\(viewModel.distinctTargetCount) distinct targets")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .foregroundStyle(.secondary)
            }
            Text("Jev chooses one complete target below, including its model and reasoning effort. Edit Agent Models to change those target definitions.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(AgentModelCatalog.TaskLabelKind.allCases, id: \.rawValue) { role in
                    roleRow(role)
                    if role != AgentModelCatalog.TaskLabelKind.allCases.last { Divider() }
                }
            }
            Divider()
            Text("Provider access").font(.headline)
            if viewModel.visibleProviders.isEmpty {
                Text("Connect an agent provider and assign models in Agent Models to make targets available.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)], alignment: .leading, spacing: 10) {
                    ForEach(viewModel.visibleProviders, id: \.rawValue) { provider in
                        Toggle(isOn: Binding(
                            get: { viewModel.isProviderAllowed(provider) },
                            set: { viewModel.setProvider(provider, enabled: $0) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.displayName)
                                if !viewModel.availableProviders.contains(provider) {
                                    Text("No available role target")
                                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            Text("With two or more distinct targets, Jev chooses one. A scope with one available target applies it directly. Roles using the same provider, model, effort, and options count as one. Provider access limits where routed tasks may run.")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let onNavigate {
                Button("Edit Agent Models…") { onNavigate(.agentModels) }
                    .buttonStyle(.link)
            }
        }
    }

    private func roleRow(_ role: AgentModelCatalog.TaskLabelKind) -> some View {
        let preview = viewModel.targetPreviews.first { $0.role == role }
        return Toggle(isOn: Binding(
            get: { viewModel.eligibleRoles.contains(role) },
            set: { viewModel.setRole(role, enabled: $0) }
        )) {
            VStack(alignment: .leading, spacing: 3) {
                Text(role.rawValue.capitalized).fontWeight(.medium)
                if let preview {
                    Text("\(preview.displayName) · \(preview.provider.displayName)")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !viewModel.isProviderAllowed(preview.provider) {
                        Text("Provider excluded")
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No available model")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 9)
    }

    private var privacyNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text("What gets shared").fontWeight(.medium)
                Text("For each new routed session, the service receives your task text, custom guidance, and candidate provider/model/effort descriptions. Attached files, workspace context, chat history, and provider credentials are excluded. Anything you type in the task or guidance is shared.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func backendSettings(_ presentation: AgentTaskRouterBackendSettingsPresentation) -> some View {
        Divider()
        Text(presentation.title).fontWeight(.medium)
        Text(presentation.configurationDetail)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if let label = presentation.secretFieldLabel {
            SecureField(label, text: $candidateSecret)
                .textFieldStyle(.roundedBorder)
                .disabled(viewModel.isPerformingBackendOperation)
                .accessibilityLabel(label)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { credentialActions }
                VStack(alignment: .leading, spacing: 10) { credentialActions }
            }
        }
        if let message = viewModel.backendOperationFeedback.message {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                backendOperationFeedbackIcon
                Text(message).fixedSize(horizontal: false, vertical: true)
            }
            .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
            .foregroundStyle(backendOperationFeedbackColor)
        }
        ForEach(presentation.links) { link in
            Link(link.title, destination: link.url)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
        }
    }

    @ViewBuilder
    private var credentialActions: some View {
        Button("Validate & Save") {
            let secret = candidateSecret
            candidateSecret = ""
            Task { await viewModel.performBackendAction(.validateAndSaveSecret(secret)) }
        }
        .disabled(candidateSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isPerformingBackendOperation)
        Button("Verify Saved Key") {
            Task { await viewModel.performBackendAction(.revalidateStoredSecret) }
        }
        .disabled(viewModel.isPerformingBackendOperation)
        Button("Remove Key", role: .destructive) {
            Task { await viewModel.performBackendAction(.removeStoredSecret) }
        }
        .disabled(viewModel.isPerformingBackendOperation)
        if viewModel.isPerformingBackendOperation { ProgressView().controlSize(.small) }
    }

    @ViewBuilder
    private var backendOperationFeedbackIcon: some View {
        switch viewModel.backendOperationFeedback {
        case .idle:
            EmptyView()
        case .running:
            ProgressView().controlSize(.mini)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
        }
    }

    private var backendOperationFeedbackColor: Color {
        switch viewModel.backendOperationFeedback {
        case .idle, .running: .secondary
        case .succeeded: .green
        case .failed: .red
        }
    }

    private func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary, lineWidth: 1))
    }

    private var selectedBackendBinding: Binding<AgentTaskRouterBackendID?> {
        Binding(get: { viewModel.selectedBackendID }, set: { id in
            if let id { viewModel.selectBackend(id) }
        })
    }

    private var readinessTitle: String {
        switch viewModel.readiness {
        case .ready:
            if !viewModel.policyCanBuildCandidates { return "Choose routing targets" }
            return viewModel.configuration.enabled ? "Model Router is on" : "Ready to enable"
        case .validating: return "Checking your API key…"
        case .needsConfiguration: return "Set up a routing service"
        case .policyUnavailable: return "Task routing is not available yet"
        case .temporarilyUnavailable: return "Routing service unavailable"
        }
    }

    private var readinessDetail: String {
        switch viewModel.readiness {
        case .ready:
            viewModel.policyCanBuildCandidates
                ? "Enable Router here or from the Agent Mode toolbar. It stays enabled across sessions until you turn it off."
                : "Select at least one role and provider with an available target."
        case .validating: "The routing service is validating your configuration."
        case let .needsConfiguration(_, reason),
             let .policyUnavailable(_, reason),
             let .temporarilyUnavailable(_, reason): reason
        }
    }

    private var readinessIcon: String {
        switch viewModel.readiness {
        case .ready: viewModel.policyCanBuildCandidates ? "checkmark.circle.fill" : "info.circle"
        case .validating: "hourglass"
        case .needsConfiguration: "slider.horizontal.3"
        case .policyUnavailable: "info.circle"
        case .temporarilyUnavailable: "exclamationmark.triangle"
        }
    }
}

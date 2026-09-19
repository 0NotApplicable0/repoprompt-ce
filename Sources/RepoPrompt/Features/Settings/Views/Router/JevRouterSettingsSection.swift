import SwiftUI

struct JevRouterSettingsSection: View {
    @Binding var candidateKey: String
    let isBusy: Bool
    let operationMessage: String?
    let validate: () -> Void
    let revalidate: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Jev by TypeSafe").font(.headline)
            Text("Validation contacts GET /v1/models. Routing, once a reviewed policy exists, uses one POST /v1/systemone request with a five-second deadline and no RepoPrompt retries.")
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField("TypeSafe API key", text: $candidateKey)
            HStack {
                Button("Validate & Save", action: validate)
                    .disabled(candidateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)
                Button("Revalidate Stored Key", action: revalidate).disabled(isBusy)
                Button("Remove Key", role: .destructive, action: remove).disabled(isBusy)
                if isBusy { ProgressView().controlSize(.small) }
            }
            if let operationMessage {
                Text(operationMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

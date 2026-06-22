import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey: String = KeychainStore.load() ?? ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text("Anthropic API Key")
                    .font(.headline)
                Text("Used to generate meeting minutes with Claude. Stored securely in your macOS Keychain — never written to disk in plaintext.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SecureField("sk-ant-…", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Link("Get an API key at console.anthropic.com",
                     destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    .font(.caption)
            }

            HStack {
                Button("Remove") {
                    KeychainStore.delete()
                    apiKey = ""
                    dismiss()
                }
                .disabled(apiKey.isEmpty)

                Spacer()

                Button("Cancel") { dismiss() }
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedKey.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private var trimmedKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !trimmedKey.isEmpty else { return }
        KeychainStore.save(trimmedKey)
        dismiss()
    }
}

#Preview {
    SettingsView()
}

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey: String = KeychainStore.load() ?? ""
    @State private var saved = false

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
                    .onChange(of: apiKey) { saved = false }
                Link("Get an API key at console.anthropic.com",
                     destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    .font(.caption)
            }

            HStack {
                Button("Remove") {
                    KeychainStore.delete()
                    apiKey = ""
                    saved = false
                }
                .disabled(apiKey.isEmpty)

                if saved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                Spacer()

                Button("Done") { dismiss() }
                Button("Save") {
                    KeychainStore.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
                    saved = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

#Preview {
    SettingsView()
}

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var provider: LLMProvider = MinutesSettings.provider
    @State private var apiKey: String = ""
    @State private var model: String = ""

    @State private var txProvider: TranscriptionProvider = TranscriptionSettings.provider
    @State private var deepgramKey: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text("Transcription")
                    .font(.headline)
                Picker("Transcription", selection: $txProvider) {
                    ForEach(TranscriptionProvider.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()

                Text(txProvider.helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if txProvider.needsKey {
                    Text(txProvider.keyLabel).font(.subheadline.bold()).padding(.top, 2)
                    SecureField("API key", text: $deepgramKey)
                        .textFieldStyle(.roundedBorder)
                    if let url = txProvider.signupURL {
                        Link("Get a Deepgram API key", destination: url).font(.caption)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Minutes Provider")
                    .font(.headline)
                Picker("Provider", selection: $provider) {
                    ForEach(LLMProvider.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .onChange(of: provider) { _, newValue in loadFields(for: newValue) }

                Text(provider.helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if provider.needsKey {
                VStack(alignment: .leading, spacing: 6) {
                    Text(provider.keyLabel).font(.subheadline.bold())
                    SecureField("API key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                    if let url = provider.signupURL {
                        Link("Get an API key", destination: url).font(.caption)
                    }
                }
            } else if let url = provider.signupURL {
                Link("Install Ollama", destination: url).font(.caption)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Model").font(.subheadline.bold())
                TextField(provider.defaultModel, text: $model)
                    .textFieldStyle(.roundedBorder)
                Text("Leave blank to use the default (\(provider.defaultModel)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if provider.needsKey {
                    Button("Remove Key") {
                        KeychainStore.delete(account: provider.keychainAccount)
                        apiKey = ""
                    }
                    .disabled(apiKey.isEmpty)
                }

                Spacer()

                Button("Cancel") { dismiss() }
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            loadFields(for: provider)
            deepgramKey = KeychainStore.load(account: txProvider.keychainAccount) ?? ""
        }
    }

    private func loadFields(for provider: LLMProvider) {
        apiKey = provider.needsKey ? (KeychainStore.load(account: provider.keychainAccount) ?? "") : ""
        let stored = MinutesSettings.model(for: provider)
        model = (stored == provider.defaultModel) ? "" : stored
    }

    private func save() {
        if provider.needsKey {
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                KeychainStore.delete(account: provider.keychainAccount)
            } else {
                KeychainStore.save(trimmed, account: provider.keychainAccount)
            }
        }
        MinutesSettings.setModel(model, for: provider)
        MinutesSettings.provider = provider

        let trimmedDeepgram = deepgramKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedDeepgram.isEmpty {
            KeychainStore.delete(account: TranscriptionProvider.deepgram.keychainAccount)
        } else {
            KeychainStore.save(trimmedDeepgram, account: TranscriptionProvider.deepgram.keychainAccount)
        }
        TranscriptionSettings.provider = txProvider

        dismiss()
    }
}

#Preview {
    SettingsView()
}

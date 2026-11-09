//
//  CustomEndpointSheet.swift
//  ShareCore
//

import SwiftUI

struct CustomEndpointSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var preferences = AppPreferences.shared

    @State private var endpoint = CustomEndpointService.shared.configuration?.baseURL.absoluteString ?? ""
    @State private var token = CustomEndpointService.shared.token ?? ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let isConfigured = CustomEndpointService.shared.configuration != nil

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("URL", text: $endpoint, prompt: Text(verbatim: "http://127.0.0.1:3425"))
                        .autocorrectionDisabled()
                    #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                    #endif
                    SecureField("Token (Optional)", text: $token)
                } footer: {
                    Text("Works with OpenAI-compatible servers. Models are discovered from /v1/models.")
                }

                if isConfigured {
                    Section {
                        Button("Remove Endpoint", role: .destructive, action: remove)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Custom Endpoint")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if isSaving {
                            ProgressView()
                        } else {
                            Button("Save") {
                                Task { await save() }
                            }
                            .disabled(endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
        }
        .alert(
            "Could Not Load Models",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            ),
            presenting: errorMessage
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 260)
        #endif
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let service = CustomEndpointService.shared
            let configuration = try await service.discover(endpoint: endpoint, token: token)
            try service.save(configuration, token: token)
            let availableIDs = Set(service.modelConfigs.map(\.id))
            pruneEnabledModels { availableIDs.contains($0) }
            dismiss()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove() {
        CustomEndpointService.shared.remove()
        pruneEnabledModels { _ in false }
        dismiss()
    }

    private func pruneEnabledModels(keepingCustomIDs shouldKeep: (String) -> Bool) {
        preferences.setEnabledModelIDs(preferences.enabledModelIDs.filter {
            !ModelConfig.isCustomEndpointID($0) || shouldKeep($0)
        })
    }
}

import SwiftUI

/// Settings, opened from the gear on every tab. Skip intervals and Sign out join it later.
struct SettingsView: View {
    let model: SettingsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(
                        "Allow downloads over cellular",
                        isOn: Binding(
                            get: { model.allowsCellular },
                            set: { allowed in Task { await model.setAllowsCellular(allowed) } }
                        ))
                } header: {
                    Text("Downloads")
                } footer: {
                    Text("When this is off, Downloads wait for Wi-Fi. Low Data Mode networks are never used.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

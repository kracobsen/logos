import SwiftUI

/// Settings, opened from the gear on every tab: Skip back and Skip forward, and Downloads. Sign out joins it later.
struct SettingsView: View {
    let model: SettingsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(
                        "Skip back",
                        selection: Binding(get: { model.skipBack }, set: { model.setSkipBack($0) })
                    ) {
                        ForEach(SettingsModel.skipChoices, id: \.self) { Text("\($0.rawValue) s").tag($0) }
                    }
                    Picker(
                        "Skip forward",
                        selection: Binding(get: { model.skipForward }, set: { model.setSkipForward($0) })
                    ) {
                        ForEach(SettingsModel.skipChoices, id: \.self) { Text("\($0.rawValue) s").tag($0) }
                    }
                } header: {
                    Text("Playback")
                }
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

import SwiftUI

struct DiagnosticsSettingsView: View {
    @AppStorage("appColorScheme") private var appColorScheme = "system"
    @State private var loggingEnabled = AppEventLog.diagnosticsEnabled

    private var loggingBinding: Binding<Bool> {
        Binding(
            get: { loggingEnabled },
            set: { value in
                loggingEnabled = value
                AppEventLog.setDiagnosticsEnabled(value)
            }
        )
    }

    var body: some View {
        SettingsPage {
            SettingsCard(title: "Diagnostic Logging", symbol: "doc.text.magnifyingglass") {
                SettingsToggleRow(
                    title: "Save Diagnostic Logs",
                    subtitle: "Saves detailed camera and app events to Files. Logs remain until you delete them manually.",
                    isOn: loggingBinding
                )
                SettingsDivider()
                VStack(alignment: .leading, spacing: 5) {
                    Text("Location")
                        .font(.subheadline.weight(.semibold))
                    Text("Files > On My iPhone > LowPolyCam > LowPolyCam Logs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(loggingEnabled ? "A new numbered log is created for each enabled app session." : "Off by default. No diagnostic file is created while this is off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .preferredColorScheme(resolvedColorScheme(appColorScheme))
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loggingEnabled = AppEventLog.diagnosticsEnabled }
    }
}

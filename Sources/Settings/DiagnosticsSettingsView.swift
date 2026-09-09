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
        List {
            Section {
                Toggle(isOn: loggingBinding) {
                    SettingsToggleLabel(
                        symbol: "doc.text.fill",
                        color: .red,
                        title: "Save Diagnostic Logs",
                        subtitle: "Record detailed camera, settings, storage, save and session events for bug reports."
                    )
                }
            } header: {
                Text("DIAGNOSTIC LOGGING")
            } footer: {
                Text("Logging is off by default. When enabled, every app session creates a new numbered log. Older logs are never deleted automatically.")
            }

            Section("LOG FILES") {
                SettingsInfoRow(
                    symbol: "folder.fill",
                    color: .blue,
                    title: "Location",
                    detail: "Files > On My iPhone > LowPolyCam > LowPolyCam Logs"
                )

                SettingsInfoRow(
                    symbol: "number",
                    color: .gray,
                    title: "Numbered Sessions",
                    detail: loggingEnabled
                        ? "Each enabled launch keeps its own log so reopening the app never destroys the previous bug report."
                        : "No diagnostic file is created while logging is turned off."
                )
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.large)
        .tint(.blue)
        .preferredColorScheme(resolvedColorScheme(appColorScheme))
        .onAppear { loggingEnabled = AppEventLog.diagnosticsEnabled }
    }
}

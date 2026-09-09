import SwiftUI

struct DiagnosticsSettingsView: View {
    @State private var loggingEnabled = AppEventLog.diagnosticsEnabled
    @State private var extremeEnabled = AppEventLog.extremeDiagnosticsEnabled

    private var loggingBinding: Binding<Bool> {
        Binding(
            get: { loggingEnabled },
            set: { value in
                loggingEnabled = value
                AppEventLog.setDiagnosticsEnabled(value)
            }
        )
    }

    private var extremeBinding: Binding<Bool> {
        Binding(
            get: { extremeEnabled },
            set: { value in
                extremeEnabled = value
                AppEventLog.setExtremeDiagnosticsEnabled(value)
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


                Toggle(isOn: extremeBinding) {
                    SettingsToggleLabel(
                        symbol: "waveform.path.ecg.rectangle.fill",
                        color: .orange,
                        title: "Extreme Bug Trace",
                        subtitle: "Near-frame zoom/lens tracing, request tokens, queue timing, state diffs, guard failures and hardware readback."
                    )
                }
                .disabled(!loggingEnabled)
            } header: {
                Text("DIAGNOSTIC LOGGING")
            } footer: {
                Text("Extreme Bug Trace is enabled by default with diagnostics in this build. It records far more detail while keeping disk I/O off the camera queues and rate-limiting frame-level probes.")
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
        .onAppear {
            loggingEnabled = AppEventLog.diagnosticsEnabled
            extremeEnabled = AppEventLog.extremeDiagnosticsEnabled
        }
    }
}

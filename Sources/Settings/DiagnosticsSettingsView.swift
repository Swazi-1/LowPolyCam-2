import SwiftUI

struct DiagnosticsSettingsView: View {
    @State private var loggingEnabled = AppEventLog.diagnosticsEnabled
    @State private var extremeEnabled = AppEventLog.extremeDiagnosticsEnabled
    @State private var latestLogURL: URL?
    @State private var logCount = 0
    @State private var showingDeleteConfirmation = false

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

                if let latestLogURL {
                    ShareLink(item: latestLogURL) {
                        Label("Share Latest Log", systemImage: "square.and.arrow.up")
                    }
                }

                Text("\(logCount) diagnostic log\(logCount == 1 ? "" : "s") currently stored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Logs can include device and iOS details, locale/time zone, storage, permissions, settings, and media filenames. Review the file before sharing it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Delete Archived Logs", role: .destructive) {
                    showingDeleteConfirmation = true
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.large)
        .tint(.blue)
        .confirmationDialog(
            "Delete archived diagnostic logs?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Archived Logs", role: .destructive) {
                AppEventLog.deleteArchivedLogs()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    refreshLogFiles()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current active log is kept. Older logs are permanently removed.")
        }
        .onAppear {
            loggingEnabled = AppEventLog.diagnosticsEnabled
            extremeEnabled = AppEventLog.extremeDiagnosticsEnabled
            refreshLogFiles()
        }
        .onChange(of: loggingEnabled) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                refreshLogFiles()
            }
        }
    }

    private func refreshLogFiles() {
        let files = AppEventLog.logURLs()
        logCount = files.count
        latestLogURL = files.last
    }
}

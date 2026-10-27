import SwiftUI
import AppKit
import AirStatKit

struct AIPane: View {
    let settings: SettingsStore

    @State private var editingEndpoint: AIEndpoint?

    var body: some View {
        Form {
            Section {
                Toggle("Enable instance monitoring", isOn: settings.binding(\.ai.isEnabled))
                    .help("Configured, enabled instances appear in the menu bar, panel and desktop widget.")
            } header: {
                Text("Local AI")
            } footer: {
                SettingsFootnote("AirStats combines each server's API with its local logs. The API confirms loaded models and live state; logs add generation, prefill and allocation measurements.")
            }

            Section {
                if settings.settings.ai.endpoints.isEmpty {
                    SettingsFootnote("No instances configured.")
                } else {
                    SettingsListBox {
                        ForEach(Array(settings.settings.ai.endpoints.enumerated()), id: \.element.id) { index, endpoint in
                            endpointRow(endpoint, isFirst: index == 0)
                        }
                    }
                }
                Menu("Add instance…") {
                    ForEach(AIRuntime.allCases, id: \.self) { runtime in
                        Button(runtime.label) {
                            editingEndpoint = AIEndpoint(name: runtime.label, runtime: runtime)
                        }
                    }
                }
            } header: {
                Text("Instances")
            } footer: {
                SettingsFootnote("Choose a log directory and filename pattern for each instance. Patterns support * and ?, for example server*.log or std*.log. Use server* or std* if rotated files have suffixes after .log; rotations are followed automatically.")
            }

            Section {
                SettingsFootnote("Enable detailed server logging for generation and prefill speeds. Measurements appear only when the API or logs report them; missing values show a dash. A loaded model is distinct from a model currently generating.")
            }
        }
        .settingsFormStyle()
        .sheet(item: $editingEndpoint) { endpoint in
            AIInstanceEditor(endpoint: endpoint) { updated in
                settings.update { s in
                    if let index = s.ai.endpoints.firstIndex(where: { $0.id == updated.id }) {
                        s.ai.endpoints[index] = updated
                    } else {
                        s.ai.endpoints.append(updated)
                        s.ai.isEnabled = true
                    }
                }
                editingEndpoint = nil
            }
        }
    }

    private func endpointRow(_ endpoint: AIEndpoint, isFirst: Bool) -> some View {
        SettingsListRow(isFirst: isFirst) {
            HStack(spacing: Design.Space.m) {
                Toggle("Monitor \(endpoint.name)", isOn: Binding(
                    get: { endpoint.isEnabled },
                    set: { enabled in
                        settings.update { s in
                            guard let index = s.ai.endpoints.firstIndex(where: { $0.id == endpoint.id }) else { return }
                            s.ai.endpoints[index].isEnabled = enabled
                        }
                    }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                VStack(alignment: .leading, spacing: Design.Space.xxs) {
                    Text(endpoint.name)
                        .font(Design.Text.body)
                        .foregroundStyle(Design.Palette.primaryText)
                    Text("\(endpoint.runtime.label) · \(endpoint.logDirectory)/\(endpoint.logFilePattern)")
                        .font(Design.Text.caption)
                        .foregroundStyle(Design.Palette.secondaryText)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Text(endpoint.usesAPI ? "API · \(endpoint.url)" : "API disabled · logs only")
                        .font(Design.Text.caption)
                        .foregroundStyle(Design.Palette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !endpoint.isConfigured {
                        Text("Set a name, absolute log directory and filename pattern.")
                            .font(Design.Text.caption)
                            .foregroundStyle(Design.Palette.secondaryText)
                    }
                }
                Spacer(minLength: Design.Space.m)
                RowIconButton(systemName: "pencil", help: "Edit instance", label: "Edit \(endpoint.name)") {
                    editingEndpoint = endpoint
                }
                RowIconButton(systemName: "trash", help: "Remove instance", label: "Remove \(endpoint.name)") {
                    settings.update { $0.ai.endpoints.removeAll { $0.id == endpoint.id } }
                }
            }
        }
    }
}

private struct AIInstanceEditor: View {
    @State var endpoint: AIEndpoint
    let save: (AIEndpoint) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xl) {
            Text("Inference Instance").font(.headline)
            Form {
                TextField("Name", text: $endpoint.name)
                Picker("Server", selection: $endpoint.runtime) {
                    ForEach(AIRuntime.allCases, id: \.self) { runtime in
                        Text(runtime.label).tag(runtime)
                    }
                }
                Section("API") {
                    Toggle("Read live state from API", isOn: $endpoint.usesAPI)
                    TextField("Base URL", text: $endpoint.url)
                        .help("The server base URL, for example http://localhost:11434. Its local port also identifies the model processes for memory measurements, even when API requests are disabled.")
                    SecureField("API key (optional)", text: Binding(
                        get: { endpoint.apiKey ?? "" },
                        set: { endpoint.apiKey = $0.isEmpty ? nil : $0 }))
                        .disabled(!endpoint.usesAPI)
                    if endpoint.usesAPI && endpoint.apiBaseURL == nil {
                        SettingsFootnote("Enter an HTTP or HTTPS base URL without credentials, query parameters or a fragment.")
                    }
                }
                Section("Local logs") {
                    HStack(spacing: Design.Space.m) {
                        TextField("Log directory", text: $endpoint.logDirectory)
                        Button("Choose…", action: chooseDirectory)
                    }
                    TextField("Filename pattern", text: $endpoint.logFilePattern)
                }
                Toggle("Monitor this instance", isOn: $endpoint.isEnabled)
            }
            SettingsFootnote("Use an absolute directory or a path starting with ~/. The directory may be created when the server next starts. Include rotated filenames in the pattern, such as server* or std*.")
            HStack(spacing: Design.Space.m) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    var updated = endpoint
                    updated.name = updated.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.url = updated.url.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.logDirectory = updated.logDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.logFilePattern = updated.logFilePattern.trimmingCharacters(in: .whitespacesAndNewlines)
                    save(updated)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!endpoint.isConfigured || (endpoint.usesAPI && endpoint.apiBaseURL == nil))
            }
        }
        .padding(Design.Space.xl)
        .frame(width: Design.Settings.instanceEditorWidth)
        .onChange(of: endpoint.runtime) { old, new in
            if endpoint.name == old.label { endpoint.name = new.label }
            if endpoint.logDirectory == old.defaultLogDirectory { endpoint.logDirectory = new.defaultLogDirectory }
            if endpoint.logFilePattern == old.defaultLogFilePattern { endpoint.logFilePattern = new.defaultLogFilePattern }
            if endpoint.url == old.defaultURL { endpoint.url = new.defaultURL }
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: (endpoint.logDirectory as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let directory = panel.url {
            endpoint.logDirectory = directory.path
        }
    }
}

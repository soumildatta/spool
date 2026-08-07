import AppKit
import SwiftUI

struct SettingsView: View {
    @State private var model: String
    @State private var serverURL: String
    @State private var watchedFolder: String
    @State private var writeInPlace: Bool
    let onSave: (Config) -> Void

    init(config: Config, onSave: @escaping (Config) -> Void) {
        _model = State(initialValue: config.model)
        _serverURL = State(initialValue: config.serverURL)
        _watchedFolder = State(initialValue: config.watchedFolder)
        _writeInPlace = State(initialValue: config.writeInPlace)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("🧵")
                Text("Spool")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Model")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("qwen3.5:9b", text: $model)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Server URL")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("http://localhost:11434/v1", text: $serverURL)
                    .textFieldStyle(.roundedBorder)
                Text("Any OpenAI-compatible endpoint. Ollama uses localhost:11434/v1, LM Studio uses localhost:1234/v1.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Watched Folder")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField("e.g. your Obsidian vault", text: $watchedFolder)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { chooseFolder() }
                }
                Text("The menu will offer one-click structuring of the newest note in this folder.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Output")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("", selection: $writeInPlace) {
                    Text("Create a new file next to the original (name.structured.md)").tag(false)
                    Text("Rewrite the original file").tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text("Rewriting always keeps a copy of the original in ~/Library/Application Support/Spool/backups.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Save") {
                    var config = Config()
                    config.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
                    config.serverURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    config.watchedFolder = watchedFolder.trimmingCharacters(in: .whitespacesAndNewlines)
                    config.writeInPlace = writeInPlace
                    onSave(config)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.level = .floating
        if panel.runModal() == .OK, let url = panel.url {
            watchedFolder = url.path
        }
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    init(config: Config, onSave: @escaping (Config) -> Void) {
        let hosting = NSHostingController(rootView: SettingsView(config: config, onSave: onSave))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Spool Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

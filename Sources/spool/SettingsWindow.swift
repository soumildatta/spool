import AppKit
import SwiftUI

/// installed-model list behind the settings picker, kept in sync with whatever server url is typed in the field above it
@MainActor
final class ModelListModel: ObservableObject {
    @Published var items: [InstalledModel] = []
    @Published var isLoading = false
    @Published var loadError: String?

    private var refreshTask: Task<Void, Never>?

    var names: [String] { items.map { $0.name } }

    func contains(_ model: String) -> Bool {
        let wanted = ModelLibrary.canonical(model)
        return items.contains { ModelLibrary.canonical($0.name) == wanted }
    }

    /// reloads after a short pause, so typing in the server field doesn't fire a request per keystroke
    func refresh(serverURL: String, debounce: Bool = false) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(nanoseconds: 600_000_000)
                if Task.isCancelled { return }
            }
            guard let self else { return }

            guard ModelLibrary.isManaged(serverURL) else {
                self.items = []
                self.loadError = nil
                self.isLoading = false
                return
            }

            self.isLoading = true
            self.loadError = nil
            do {
                let found = try await ModelLibrary.installed(serverURL: serverURL)
                if Task.isCancelled { return }
                self.items = found
                self.loadError = nil
            } catch {
                if Task.isCancelled { return }
                self.items = []
                self.loadError = error.localizedDescription
            }
            self.isLoading = false
        }
    }

    func delete(_ model: String, serverURL: String) async -> String? {
        do {
            try await ModelLibrary.delete(model: model, serverURL: serverURL)
            refresh(serverURL: serverURL)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// lets the hosted swiftui view reach the window it lives in, so alerts can be attached to it as sheets
final class WindowRef {
    weak var window: NSWindow?
}

struct SettingsView: View {
    @State private var model: String
    @State private var serverURL: String
    @State private var watchedFolder: String
    @State private var writeInPlace: Bool

    @StateObject private var library = ModelListModel()
    @State private var isAddingModel = false
    /// list selection lives in its own state — List keeps internal selection bookkeeping and won't drive a computed binding reliably
    @State private var selection: String?

    let windowRef: WindowRef
    let onSave: (Config) -> Void

    init(config: Config, windowRef: WindowRef, onSave: @escaping (Config) -> Void) {
        self.windowRef = windowRef
        _model = State(initialValue: config.model)
        _serverURL = State(initialValue: config.serverURL)
        _watchedFolder = State(initialValue: config.watchedFolder)
        _writeInPlace = State(initialValue: config.writeInPlace)
        self.onSave = onSave
    }

    private var isManagedServer: Bool { ModelLibrary.isManaged(serverURL) }

    /// the configured model isn't on disk so say that
    private var selectedIsMissing: Bool {
        isManagedServer && !library.isLoading && library.loadError == nil
            && !model.isEmpty && !library.contains(model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("🧵")
                Text("Spool")
                    .font(.headline)
            }

            modelSection

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
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            selection = model
            library.refresh(serverURL: serverURL)
        }
        .onChange(of: serverURL) { library.refresh(serverURL: serverURL, debounce: true) }
        // picking a row is what chooses the model
        .onChange(of: selection) { if let selection { model = selection } }
        .onChange(of: model) { if selection != model { selection = model } }
        .sheet(isPresented: $isAddingModel) {
            PullModelSheet(serverURL: serverURL,
                           suggestion: selectedIsMissing ? model : "",
                           isPresented: $isAddingModel) { pulled in
                model = pulled
                library.refresh(serverURL: serverURL)
            }
        }
    }

    // MARK: - Model section

    @ViewBuilder
    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Model")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if isManagedServer {
                modelList
                listToolbar
                if selectedIsMissing {
                    missingBanner
                } else if let error = library.loadError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Models installed through Ollama. Hit + to download another one.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else {
                // someone else's server (LM Studio, a remote box): we can't list or download anything there, so it stays a plain name field
                TextField("qwen3:8b", text: $model)
                    .textFieldStyle(.roundedBorder)
                Text("Spool only manages models for a local Ollama. For this server, type the name of a model it already serves.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modelList: some View {
        List(selection: $selection) {
            ForEach(library.items) { item in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name)
                        Text(item.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if ModelLibrary.canonical(item.name) == ModelLibrary.canonical(model) {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { model = item.name }
                .tag(item.name)
            }
        }
        .frame(height: 132)
        .overlay {
            if library.isLoading && library.items.isEmpty {
                ProgressView().controlSize(.small)
            } else if library.items.isEmpty && library.loadError == nil {
                Text("No models installed yet.\nHit + to download one.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
        .border(Color(nsColor: .separatorColor))
    }

    private var listToolbar: some View {
        HStack(spacing: 6) {
            Button { isAddingModel = true } label: {
                Image(systemName: "plus").frame(width: 18, height: 14)
            }
            .help("Download a model from the Ollama library")

            Button { askToRemoveSelectedModel() } label: {
                Image(systemName: "minus").frame(width: 18, height: 14)
            }
            .disabled(!library.contains(model))
            .help("Remove the selected model from disk")

            Spacer()

            Button { library.refresh(serverURL: serverURL) } label: {
                Image(systemName: "arrow.clockwise").frame(width: 18, height: 14)
            }
            .help("Refresh the list")
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
    }

    private var missingBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("\"\(model)\" isn't downloaded — runs will fail until it is.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Download") { isAddingModel = true }
                .controlSize(.small)
        }
    }

    // MARK: - Actions

    /// appkit alerts rather than swiftui ones: inside an NSHostingController a swiftui .alert fires the window's default button (Save) instead of showing
    private func askToRemoveSelectedModel() {
        let target = model
        guard library.contains(target) else { return }

        let alert = NSAlert()
        alert.messageText = "Remove \(target)?"
        alert.informativeText = "It will be deleted from disk. You can download it again later."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        present(alert) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task {
                if let message = await library.delete(target, serverURL: serverURL) {
                    showMessage(message)
                }
            }
        }
    }

    private func showMessage(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "Spool"
        alert.informativeText = text
        alert.alertStyle = .warning
        present(alert) { _ in }
    }

    private func present(_ alert: NSAlert, then: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = windowRef.window, window.isVisible {
            alert.beginSheetModal(for: window) { then($0) }
        } else {
            then(alert.runModal())
        }
    }

    private func save() {
        var config = Config()
        config.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        config.serverURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        config.watchedFolder = watchedFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        config.writeInPlace = writeInPlace
        onSave(config)
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

/// the + sheet: type a name, it downloads
struct PullModelSheet: View {
    let serverURL: String
    let suggestion: String
    /// the sheet closes itself through the parent's flag
    @Binding var isPresented: Bool
    let onFinished: (String) -> Void

    @State private var name: String
    @State private var progress: PullProgress?
    @State private var errorText: String?
    @State private var pullTask: Task<Void, Never>?

    private var isPulling: Bool { pullTask != nil }

    private static let popular = ["qwen3:8b", "qwen3:4b", "llama3.2:3b", "gemma3:4b", "mistral:7b"]

    init(serverURL: String, suggestion: String, isPresented: Binding<Bool>,
         onFinished: @escaping (String) -> Void) {
        self.serverURL = serverURL
        self.suggestion = suggestion
        _isPresented = isPresented
        self.onFinished = onFinished
        _name = State(initialValue: suggestion)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Download a model")
                .font(.headline)

            TextField("qwen3:8b", text: $name)
                .textFieldStyle(.roundedBorder)
                .disabled(isPulling)
                .onSubmit { start() }

            Text("Any name from ollama.com/library, tag included. Smaller models (3B–4B) run comfortably on lighter machines.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if !isPulling {
                HStack(spacing: 6) {
                    ForEach(Self.popular, id: \.self) { candidate in
                        Button(candidate) { name = candidate }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }

            if let progress {
                VStack(alignment: .leading, spacing: 4) {
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    HStack {
                        Text(progress.status)
                        Spacer()
                        if let detail = progress.detail { Text(detail) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button(isPulling ? "Downloading…" : "Download") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isPulling || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func start() {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !isPulling else { return }
        errorText = nil
        progress = PullProgress(status: "starting…")

        pullTask = Task {
            do {
                try await ModelLibrary.pull(model: target, serverURL: serverURL) { update in
                    Task { @MainActor in progress = update }
                }
                pullTask = nil
                onFinished(target)
                isPresented = false
            } catch is CancellationError {
                pullTask = nil
                progress = nil
            } catch {
                pullTask = nil
                progress = nil
                errorText = error.localizedDescription
            }
        }
    }

    private func cancel() {
        pullTask?.cancel()
        pullTask = nil
        isPresented = false
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void

    init(config: Config, onSave: @escaping (Config) -> Void, onClose: @escaping () -> Void = {}) {
        self.onClose = onClose
        let windowRef = WindowRef()
        let hosting = NSHostingController(
            rootView: SettingsView(config: config, windowRef: windowRef, onSave: onSave))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Spool Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        windowRef.window = window
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

import AppKit
import UniformTypeIdentifiers

/// transparent overlay on the status item button, catches file/folder drops
final class DropView: NSView {
    var onDrop: (URL) -> Void = { _ in }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedURL(sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = droppedURL(sender) else { return false }
        onDrop(url)
        return true
    }

    private func droppedURL(_ sender: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL])?.first
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var stateRow: NSMenuItem!
    private var modelRow: NSMenuItem!
    private var structureItem: NSMenuItem!
    private var newestItem: NSMenuItem!
    private var openLastItem: NSMenuItem!

    private var config = Config.load()
    private var isBusy = false
    private var pulseTimer: Timer?
    private var pulseOn = false
    private var lastResultURL: URL?
    private var settingsController: SettingsWindowController?

    private static let idleText = "idle · point me at a rough draft"

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(wound: false)
        installDropView()

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        stateRow = infoRow(Self.idleText)
        menu.addItem(stateRow)
        modelRow = infoRow("model: \(config.model)")
        menu.addItem(modelRow)

        menu.addItem(.separator())

        structureItem = NSMenuItem(title: "Structure a Document…",
                                   action: #selector(pickDocument), keyEquivalent: "o")
        structureItem.target = self
        menu.addItem(structureItem)

        newestItem = NSMenuItem(title: "", action: #selector(structureNewest), keyEquivalent: "n")
        newestItem.target = self
        newestItem.isHidden = true
        menu.addItem(newestItem)

        openLastItem = NSMenuItem(title: "Open Last Result",
                                  action: #selector(openLastResult), keyEquivalent: "")
        openLastItem.target = self
        openLastItem.isHidden = true
        menu.addItem(openLastItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit Spool",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    func applicationWillTerminate(_ notification: Notification) {
        OllamaManager.shutdownIfSpawned()
        try? FileManager.default.removeItem(at: Paths.pidFile)
    }

    private func infoRow(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func installDropView() {
        guard let button = statusItem.button else { return }
        let drop = DropView(frame: button.bounds)
        drop.autoresizingMask = [.width, .height]
        drop.onDrop = { [weak self] url in
            DispatchQueue.main.async { self?.handleDropped(url) }
        }
        button.addSubview(drop)
    }

    // MARK: - Menu refresh

    func menuWillOpen(_ menu: NSMenu) {
        modelRow.title = "model: \(config.model)"
        if !isBusy { stateRow.title = Self.idleText }

        if !isBusy, let folder = config.watchedFolderURL, let newest = Drafts.newest(in: folder) {
            newestItem.isHidden = false
            newestItem.title = "Structure Newest: \(newest.lastPathComponent)"
            newestItem.representedObject = newest
        } else if config.watchedFolderURL == nil {
            newestItem.isHidden = true
        }
    }

    private func setState(_ text: String) {
        DispatchQueue.main.async { self.stateRow.title = text }
    }

    // MARK: - Actions

    @objc private func pickDocument() {
        guard !isBusy else { return }
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.title = "Choose a rough draft to structure"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var types: [UTType] = [.plainText, .text]
        if let markdown = UTType(filenameExtension: "md") { types.append(markdown) }
        panel.allowedContentTypes = types
        panel.level = .floating

        guard panel.runModal() == .OK, let url = panel.url else { return }
        structure(url)
    }

    @objc private func structureNewest() {
        guard !isBusy, let url = newestItem.representedObject as? URL else { return }
        structure(url)
    }

    @objc private func openLastResult() {
        if let url = lastResultURL { NSWorkspace.shared.open(url) }
    }

    @objc private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        let controller = SettingsWindowController(config: config) { [weak self] newConfig in
            guard let self else { return }
            self.config = newConfig
            newConfig.save()
            self.settingsController?.close()
        }
        settingsController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func handleDropped(_ url: URL) {
        guard !isBusy else { return }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            if let newest = Drafts.newest(in: url) {
                structure(newest)
            } else {
                showError("No drafts (.md or .txt files) found in \(url.lastPathComponent).")
            }
        } else if Drafts.draftExtensions.contains(url.pathExtension.lowercased()) {
            structure(url)
        } else {
            showError("Spool works with .md and .txt files, and \(url.lastPathComponent) is neither.")
        }
    }

    // MARK: - Processing

    private func structure(_ url: URL) {
        let raw: String
        do {
            raw = try String(contentsOf: url, encoding: .utf8)
        } catch {
            showError("Couldn't read \(url.lastPathComponent): \(error.localizedDescription)")
            return
        }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showError("\(url.lastPathComponent) is empty, nothing to structure.")
            return
        }

        setBusy(true)
        setState("waking up the model…")
        let name = url.lastPathComponent
        let jobConfig = config

        Task.detached { [weak self] in
            do {
                let outputURL = try await Drafts.structureAndWrite(raw: raw, from: url, config: jobConfig) { progress in
                    switch progress {
                    case .loadingModel:
                        self?.setState("loading \(jobConfig.model) into memory…")
                    case .thinking:
                        self?.setState("thinking about \(name)…")
                    case .writing(let count):
                        self?.setState("writing \(name) · \(Self.pretty(count)) chars")
                    }
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.setBusy(false)
                    self.lastResultURL = outputURL
                    self.openLastItem.isHidden = false
                    self.openLastItem.title = "Open Last Result (\(outputURL.lastPathComponent))"
                }
            } catch {
                DispatchQueue.main.async {
                    self?.setBusy(false)
                    self?.showError(error.localizedDescription)
                }
            }
            // job's done, unload the model and kill the server if we started it
            await OllamaManager.finishJob(model: jobConfig.model, serverURL: jobConfig.serverURL)
        }
    }

    private static func pretty(_ count: Int) -> String {
        count < 1000 ? "\(count)" : String(format: "%.1fk", Double(count) / 1000)
    }

    // MARK: - UI state

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        structureItem.isEnabled = !busy
        newestItem.isEnabled = !busy
        if busy {
            pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.pulseOn.toggle()
                self.setIcon(wound: self.pulseOn)
            }
        } else {
            pulseTimer?.invalidate()
            pulseTimer = nil
            pulseOn = false
            setIcon(wound: false)
            stateRow.title = Self.idleText
        }
    }

    private func setIcon(wound: Bool) {
        statusItem.button?.image = Self.spoolIcon(wound: wound)
    }

    /// hand-drawn thread spool, since SF Symbols doesn't have one. two flanges,
    /// thread across the barrel (a solid block while wound, loose strands while
    /// idle — the pulse alternates them, "winding" while the model thinks), and
    /// a tail trailing off. template image, so the menu bar tints it correctly.
    private static func spoolIcon(wound: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()

            // flanges
            NSBezierPath(roundedRect: NSRect(x: 3.3, y: 14.2, width: 11.4, height: 2.4),
                         xRadius: 1.2, yRadius: 1.2).fill()
            NSBezierPath(roundedRect: NSRect(x: 3.3, y: 2.4, width: 11.4, height: 2.4),
                         xRadius: 1.2, yRadius: 1.2).fill()

            if wound {
                NSBezierPath(roundedRect: NSRect(x: 5, y: 5.6, width: 8, height: 7.8),
                             xRadius: 1.6, yRadius: 1.6).fill()
            } else {
                let strands = NSBezierPath()
                strands.lineWidth = 1.3
                strands.lineCapStyle = .round
                for y: CGFloat in [6.9, 9.5, 12.1] {
                    strands.move(to: NSPoint(x: 5.6, y: y))
                    strands.line(to: NSPoint(x: 12.4, y: y))
                }
                strands.stroke()
            }

            let tail = NSBezierPath()
            tail.lineWidth = 1.3
            tail.lineCapStyle = .round
            tail.move(to: NSPoint(x: 12.4, y: 6.9))
            tail.curve(to: NSPoint(x: 16.8, y: 4.2),
                       controlPoint1: NSPoint(x: 14.4, y: 6.9),
                       controlPoint2: NSPoint(x: 16.6, y: 6.5))
            tail.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Spool"
        return image
    }

    private func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Spool"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

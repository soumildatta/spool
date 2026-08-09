import AppKit
import UniformTypeIdentifiers

/// transparent overlay on the status item button, catches file/folder drops
final class DropView: NSView {
    var onDrop: ([URL]) -> Void = { _ in }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedURLs(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedURLs(sender)
        guard !urls.isEmpty else { return false }
        onDrop(urls)
        return true
    }

    private func droppedURLs(_ sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options)
        return (objects as? [URL]) ?? []
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var stateRow: NSMenuItem!
    private var queueRow: NSMenuItem!
    private var modelRow: NSMenuItem!
    private var structureItem: NSMenuItem!
    private var newestItem: NSMenuItem!
    private var clearQueueItem: NSMenuItem!
    private var resultsItem: NSMenuItem!

    private var config = Config.load()
    private var pulseTimer: Timer?
    private var pulseOn = false
    private var settingsController: SettingsWindowController?

    // queue state, only ever touched on the main thread
    private var pending: [URL] = []
    private var currentURL: URL?
    private var results: [URL] = []
    private var failures: [String] = []

    private var isBusy: Bool { currentURL != nil }

    /// how many drafts this run covers, counting whatever got added mid-run
    private var runTotal: Int {
        results.count + failures.count + pending.count + (currentURL == nil ? 0 : 1)
    }

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
        queueRow = infoRow("")
        queueRow.isHidden = true
        menu.addItem(queueRow)
        modelRow = infoRow("model: \(config.model)")
        menu.addItem(modelRow)

        menu.addItem(.separator())

        structureItem = NSMenuItem(title: "Structure Documents…",
                                   action: #selector(pickDocuments), keyEquivalent: "o")
        structureItem.target = self
        menu.addItem(structureItem)

        newestItem = NSMenuItem(title: "", action: #selector(structureNewest), keyEquivalent: "n")
        newestItem.target = self
        newestItem.isHidden = true
        menu.addItem(newestItem)

        clearQueueItem = NSMenuItem(title: "", action: #selector(clearQueue), keyEquivalent: "")
        clearQueueItem.target = self
        clearQueueItem.isHidden = true
        menu.addItem(clearQueueItem)

        resultsItem = NSMenuItem(title: "Open Last Result",
                                 action: #selector(openLastResult), keyEquivalent: "")
        resultsItem.target = self
        resultsItem.isHidden = true
        menu.addItem(resultsItem)

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
        drop.onDrop = { [weak self] urls in
            DispatchQueue.main.async { self?.enqueue(urls, reportRejects: true) }
        }
        button.addSubview(drop)
    }

    // MARK: - Menu refresh

    func menuWillOpen(_ menu: NSMenu) {
        modelRow.title = "model: \(config.model)"
        if !isBusy { stateRow.title = Self.idleText }

        if pending.isEmpty {
            queueRow.isHidden = true
            clearQueueItem.isHidden = true
        } else {
            queueRow.isHidden = false
            queueRow.title = "queued: \(pending.count) waiting"
            clearQueueItem.isHidden = false
            clearQueueItem.title = "Clear Queue (\(pending.count) waiting)"
        }

        structureItem.title = isBusy ? "Add Documents to Queue…" : "Structure Documents…"

        if let folder = config.watchedFolderURL, let newest = Drafts.newest(in: folder) {
            newestItem.isHidden = false
            newestItem.title = "\(isBusy ? "Queue" : "Structure") Newest: \(newest.lastPathComponent)"
            newestItem.representedObject = newest
        } else {
            newestItem.isHidden = true
            newestItem.representedObject = nil
        }
    }

    /// job progress text, with the position in the run when there's more than one
    private func setState(_ text: String) {
        DispatchQueue.main.async {
            let total = self.runTotal
            guard total > 1 else {
                self.stateRow.title = text
                return
            }
            let position = self.results.count + self.failures.count + 1
            self.stateRow.title = "\(text) · \(position) of \(total)"
        }
    }

    // MARK: - Actions

    @objc private func pickDocuments() {
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.title = "Choose rough drafts to structure"
        panel.message = "Pick as many as you like, Spool works through them one at a time."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        var types: [UTType] = [.plainText, .text]
        if let markdown = UTType(filenameExtension: "md") { types.append(markdown) }
        panel.allowedContentTypes = types
        panel.level = .floating

        guard panel.runModal() == .OK else { return }
        enqueue(panel.urls, reportRejects: true)
    }

    @objc private func structureNewest() {
        guard let url = newestItem.representedObject as? URL else { return }
        enqueue([url], reportRejects: true)
    }

    @objc private func clearQueue() {
        pending.removeAll()
    }

    @objc private func openLastResult() {
        if let url = results.last { NSWorkspace.shared.open(url) }
    }

    @objc private func openResult(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.open(url) }
    }

    @objc private func openAllResults() {
        results.forEach { NSWorkspace.shared.open($0) }
    }

    @objc private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        let controller = SettingsWindowController(config: config) { [weak self] newConfig in
            guard let self else { return }
            self.config = newConfig
            newConfig.save()
            self.settingsController?.close()
        } onClose: { [weak self] in
            // listing and downloading models needs a server, so settings may have started one. let it go again unless a job is still using it.
            guard let self, !self.isBusy else { return }
            OllamaManager.shutdownIfSpawned()
        }
        settingsController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Queue

    /// adds drafts to the back of the queue, starting the run if nothing is going.
    /// folders stand in for their newest draft, same as a single drop always did.
    private func enqueue(_ urls: [URL], reportRejects: Bool) {
        var rejects: [String] = []
        var added = 0

        for url in urls {
            switch Drafts.resolve(url) {
            case .draft(let draft):
                guard !isQueued(draft) else { continue }
                pending.append(draft)
                added += 1
            case .emptyFolder:
                rejects.append("No drafts (.md or .txt files) found in \(url.lastPathComponent).")
            case .unsupported:
                rejects.append("Spool works with .md and .txt files, and \(url.lastPathComponent) is neither.")
            case .missing:
                rejects.append("\(url.lastPathComponent) isn't there anymore.")
            }
        }

        if added > 0 && !isBusy { beginRun() }
        if reportRejects && !rejects.isEmpty { showError(rejects.joined(separator: "\n")) }
    }

    private func isQueued(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if currentURL?.standardizedFileURL.path == path { return true }
        return pending.contains { $0.standardizedFileURL.path == path }
    }

    /// fresh run, so the results and failures from the last one stop being shown
    private func beginRun() {
        results.removeAll()
        failures.removeAll()
        resultsItem.isHidden = true
        resultsItem.submenu = nil
        startPulse()
        advanceQueue()
    }

    /// takes the next draft off the queue and starts it, skipping ones that
    /// can't be read. ends the run when nothing is left.
    private func advanceQueue() {
        while !pending.isEmpty {
            let url = pending.removeFirst()
            let raw: String
            do {
                raw = try String(contentsOf: url, encoding: .utf8)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                continue
            }
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                failures.append("\(url.lastPathComponent) is empty, nothing to structure.")
                continue
            }
            run(raw: raw, from: url)
            return
        }
        finishRun()
    }

    private func run(raw: String, from url: URL) {
        currentURL = url
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
                    self.currentURL = nil
                    self.results.append(outputURL)
                    self.refreshResults()
                    self.advanceQueue()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.currentURL = nil
                    self.failures.append("\(name): \(error.localizedDescription)")
                    self.advanceQueue()
                }
            }
        }
    }

    /// queue is drained, so let go of the model and report anything that failed
    private func finishRun() {
        stopPulse()
        let jobConfig = config
        Task.detached {
            await OllamaManager.finishJob(model: jobConfig.model, serverURL: jobConfig.serverURL)
        }

        guard !failures.isEmpty else { return }
        let heading = failures.count == 1 ? "" : "\(failures.count) drafts didn't make it:\n\n"
        showError(heading + failures.joined(separator: "\n"))
        failures.removeAll()
    }

    /// one result opens directly, several get a submenu listing them
    private func refreshResults() {
        guard !results.isEmpty else {
            resultsItem.isHidden = true
            return
        }
        resultsItem.isHidden = false

        guard results.count > 1 else {
            resultsItem.submenu = nil
            resultsItem.action = #selector(openLastResult)
            resultsItem.target = self
            resultsItem.title = "Open Last Result (\(results[0].lastPathComponent))"
            return
        }

        resultsItem.action = nil
        resultsItem.title = "Open Results (\(results.count))"
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for url in results {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openResult(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let all = NSMenuItem(title: "Open All", action: #selector(openAllResults), keyEquivalent: "")
        all.target = self
        submenu.addItem(all)
        resultsItem.submenu = submenu
    }

    private static func pretty(_ count: Int) -> String {
        count < 1000 ? "\(count)" : String(format: "%.1fk", Double(count) / 1000)
    }

    // MARK: - UI state

    private func startPulse() {
        guard pulseTimer == nil else { return }
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.pulseOn.toggle()
            self.setIcon(wound: self.pulseOn)
        }
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        pulseOn = false
        setIcon(wound: false)
        stateRow.title = Self.idleText
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

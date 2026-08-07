import AppKit
import Darwin

// MARK: - Daemon plumbing

func runningPID() -> pid_t? {
    guard let contents = try? String(contentsOf: Paths.pidFile, encoding: .utf8),
          let pid = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return nil }
    // kill(pid, 0) just checks the pid exists, no signal actually sent
    if kill(pid, 0) == 0 || errno == EPERM { return pid }
    return nil
}

func executablePath() -> String {
    if let path = Bundle.main.executablePath { return path }
    let arg0 = CommandLine.arguments[0]
    if arg0.hasPrefix("/") { return arg0 }
    return FileManager.default.currentDirectoryPath + "/" + arg0
}

/// spawns this executable again with --foreground in a new session (setsid),
/// stdio goes to the log file, so it survives the terminal closing
func spawnDetached() -> Bool {
    OllamaManager.spawnDetached(binary: executablePath(),
                                arguments: ["--foreground"],
                                logPath: Paths.logFile.path) != nil
}

func runForeground() -> Never {
    Paths.ensureAppSupport()
    try? String(ProcessInfo.processInfo.processIdentifier)
        .write(to: Paths.pidFile, atomically: true, encoding: .utf8)

    // graceful shutdown on sigterm, which is what `spool stop` sends
    signal(SIGTERM, SIG_IGN)
    let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigterm.setEventHandler { NSApp.terminate(nil) }
    sigterm.resume()

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
    exit(0)
}

// MARK: - CLI

let helpText = """
spool, turns rough idea dumps into structured documents from your menu bar 🧵

usage:
  spool              start the menu bar app (keeps running after you close the terminal)
  spool run <file…>  structure one or more documents right here in the terminal
  spool stop         quit the menu bar app
  spool status       check whether it's running
  spool --foreground run attached to the terminal (mostly for debugging)

config:  ~/Library/Application Support/Spool/config.json
log:     ~/Library/Logs/spool.log
"""

let arguments = CommandLine.arguments.dropFirst()

switch arguments.first {
case nil:
    if let pid = runningPID() {
        print("Spool is already spinning in your menu bar (pid \(pid)).")
    } else if spawnDetached() {
        print("🧵 Spool is now in your menu bar. You can close this terminal.")
    } else {
        print("Failed to start Spool. Try `spool --foreground` to see what's wrong.")
        exit(1)
    }

case "--foreground", "-f":
    if let pid = runningPID(), pid != ProcessInfo.processInfo.processIdentifier {
        print("Spool is already running (pid \(pid)). Run `spool stop` first.")
        exit(1)
    }
    runForeground()

case "run":
    guard arguments.count >= 2 else {
        print("usage: spool run <file-or-folder> [more files…]")
        exit(1)
    }

    // resolve every path up front, folders standing in for their newest draft,
    // so a bad argument is reported before the model gets loaded
    var targets: [URL] = []
    var skipped = 0
    for argument in arguments.dropFirst() {
        let inputURL = URL(fileURLWithPath: (argument as NSString).expandingTildeInPath)
        switch Drafts.resolve(inputURL) {
        case .draft(let url):
            let path = url.standardizedFileURL.path
            if targets.contains(where: { $0.standardizedFileURL.path == path }) { continue }
            targets.append(url)
        case .emptyFolder:
            print("No drafts (.md or .txt files) found in \(inputURL.path).")
            skipped += 1
        case .unsupported:
            print("Spool works with .md and .txt files, and \(inputURL.lastPathComponent) is neither.")
            skipped += 1
        case .missing:
            print("\(inputURL.path) doesn't exist.")
            skipped += 1
        }
    }
    guard !targets.isEmpty else { exit(1) }

    let config = Config.load()
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        func show(_ text: String) {
            print("\r\u{1B}[K  \(text)", terminator: "")
            fflush(stdout)
        }

        var failed = skipped
        for (index, url) in targets.enumerated() {
            let position = targets.count > 1 ? " [\(index + 1)/\(targets.count)]" : ""
            guard let raw = try? String(contentsOf: url, encoding: .utf8),
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                print("Couldn't read \(url.path) (or it's empty).")
                failed += 1
                continue
            }
            print("🧵\(position) Structuring \(url.lastPathComponent) with \(config.model)…")
            do {
                let outputURL = try await Drafts.structureAndWrite(raw: raw, from: url, config: config) { progress in
                    switch progress {
                    case .loadingModel: show("loading model into memory…")
                    case .thinking: show("thinking…")
                    case .writing(let count): show("writing · \(count) chars")
                    }
                }
                print("\nDone → \(outputURL.path)")
            } catch {
                print("\nError: \(error.localizedDescription)")
                failed += 1
            }
        }

        // the model stays loaded across the whole batch, this drops it at the end
        await OllamaManager.finishJob(model: config.model, serverURL: config.serverURL)
        exit(failed == 0 ? 0 : 1)
    }
    semaphore.wait()

case "stop":
    if let pid = runningPID() {
        kill(pid, SIGTERM)
        try? FileManager.default.removeItem(at: Paths.pidFile)
        print("Spool stopped.")
    } else {
        print("Spool isn't running.")
    }

case "status":
    if let pid = runningPID() {
        print("Spool is running (pid \(pid)).")
    } else {
        print("Spool isn't running.")
    }

case "help", "--help", "-h":
    print(helpText)

default:
    print("Unknown command: \(arguments.first!)\n")
    print(helpText)
    exit(1)
}

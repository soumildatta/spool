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
  spool run <file>   structure a document right here in the terminal
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
        print("usage: spool run <file-or-folder>")
        exit(1)
    }
    var inputURL = URL(fileURLWithPath: (arguments.dropFirst().first! as NSString).expandingTildeInPath)
    var isDirectory: ObjCBool = false
    FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isDirectory)
    if isDirectory.boolValue {
        guard let newest = Drafts.newest(in: inputURL) else {
            print("No drafts (.md or .txt files) found in \(inputURL.path).")
            exit(1)
        }
        inputURL = newest
    }
    guard let raw = try? String(contentsOf: inputURL, encoding: .utf8),
          !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
        print("Couldn't read \(inputURL.path) (or it's empty).")
        exit(1)
    }
    let config = Config.load()
    print("🧵 Structuring \(inputURL.lastPathComponent) with \(config.model)…")
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        func show(_ text: String) {
            print("\r\u{1B}[K  \(text)", terminator: "")
            fflush(stdout)
        }
        do {
            let outputURL = try await Drafts.structureAndWrite(raw: raw, from: inputURL, config: config) { progress in
                switch progress {
                case .loadingModel: show("loading model into memory…")
                case .thinking: show("thinking…")
                case .writing(let count): show("writing · \(count) chars")
                }
            }
            print("\nDone → \(outputURL.path)")
            await OllamaManager.finishJob(model: config.model, serverURL: config.serverURL)
            exit(0)
        } catch {
            print("\nError: \(error.localizedDescription)")
            await OllamaManager.finishJob(model: config.model, serverURL: config.serverURL)
            exit(1)
        }
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

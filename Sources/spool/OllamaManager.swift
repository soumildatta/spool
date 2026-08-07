import Foundation
import Darwin

enum OllamaError: LocalizedError {
    case notInstalled
    case failedToStart

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Ollama isn't installed. Run install.sh from the Spool folder, or `brew install ollama`."
        case .failedToStart:
            return "Ollama was started but never became reachable on localhost:11434. Check ~/Library/Logs/ollama.log."
        }
    }
}

/// starts and stops a local ollama server on demand, unloads the model from
/// memory once a job finishes so nothing sits in ram or at login doing nothing
enum OllamaManager {
    /// pid of an `ollama serve` process we spawned ourselves, nil if the
    /// server was already running or belongs to someone else (we leave those alone)
    private static var spawnedPID: pid_t?

    private static let ollamaLog = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ollama.log").path

    /// only touches servers that look like a local ollama on the default port,
    /// anything else (LM Studio, a remote box) gets left alone
    static func managedBase(for serverURL: String) -> URL? {
        guard let components = URLComponents(string: serverURL),
              let host = components.host,
              ["localhost", "127.0.0.1", "::1"].contains(host),
              (components.port ?? 80) == 11434
        else { return nil }
        return URL(string: "http://\(host):11434")
    }

    static func isUp(_ base: URL) async -> Bool {
        var request = URLRequest(url: base.appendingPathComponent("api/version"))
        request.timeoutInterval = 2
        return (try? await URLSession.shared.data(for: request)) != nil
    }

    /// makes sure a server is reachable before a job, spawns `ollama serve`
    /// detached and waits for it if a managed local ollama is down
    static func ensureRunning(serverURL: String) async throws {
        guard let base = managedBase(for: serverURL) else { return }
        if await isUp(base) { return }

        guard let binary = findBinary() else { throw OllamaError.notInstalled }
        spawnedPID = spawnDetached(binary: binary, arguments: ["serve"], logPath: ollamaLog)

        for _ in 0..<30 {
            if await isUp(base) { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw OllamaError.failedToStart
    }

    /// called once a job is done, win or lose. evicts the model from memory
    /// right away and shuts down the server too if we're the ones who started it
    static func finishJob(model: String, serverURL: String) async {
        guard let base = managedBase(for: serverURL) else { return }

        // keep_alive 0 tells ollama to unload the model immediately
        var request = URLRequest(url: base.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "keep_alive": 0])
        request.timeoutInterval = 30
        _ = try? await URLSession.shared.data(for: request)

        shutdownIfSpawned()
    }

    /// kills the `ollama serve` we spawned, if any, safe to call anytime
    static func shutdownIfSpawned() {
        if let pid = spawnedPID {
            kill(pid, SIGTERM)
            spawnedPID = nil
        }
    }

    // MARK: - Process plumbing

    private static func findBinary() -> String? {
        var candidates = [
            "/opt/homebrew/bin/ollama",
            "/usr/local/bin/ollama",
            "/opt/homebrew/opt/ollama/bin/ollama",
            "/Applications/Ollama.app/Contents/Resources/ollama",
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/ollama" }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func spawnDetached(binary: String, arguments: [String], logPath: String) -> pid_t? {
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }

        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 1, logPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_addopen(&fileActions, 2, logPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)

        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes)
        let POSIX_SPAWN_SETSID: Int16 = 0x0400
        posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSID)

        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = ([binary] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        let result = posix_spawn(&pid, binary, &fileActions, &attributes, &argv, environ)
        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&attributes)
        return result == 0 ? pid : nil
    }
}

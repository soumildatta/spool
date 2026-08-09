import Foundation

/// one entry of `ollama list`
struct InstalledModel: Identifiable, Hashable {
    let name: String
    let sizeBytes: Int64
    let parameterSize: String
    let quantization: String

    var id: String { name }

    /// "8.2B · Q4_K_M · 4.7 GB", skipping whatever the server didn't report
    var subtitle: String {
        var parts: [String] = []
        if !parameterSize.isEmpty { parts.append(parameterSize) }
        if !quantization.isEmpty { parts.append(quantization) }
        if sizeBytes > 0 { parts.append(ModelLibrary.prettyBytes(sizeBytes)) }
        return parts.joined(separator: " · ")
    }
}

/// progress of a single `api/pull`
struct PullProgress {
    var status: String
    var completed: Int64 = 0
    var total: Int64 = 0

    var fraction: Double? {
        guard total > 0, completed >= 0 else { return nil }
        return min(1, Double(completed) / Double(total))
    }

    var detail: String? {
        guard total > 0 else { return nil }
        return "\(ModelLibrary.prettyBytes(completed)) of \(ModelLibrary.prettyBytes(total))"
    }
}

enum ModelLibraryError: LocalizedError {
    case unmanagedServer(String)
    case unreachable(String)
    case modelMissing(String)
    case pullFailed(String, String)
    case deleteFailed(String, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .unmanagedServer(let url):
            return "\(url) isn't a local Ollama server, so Spool can't manage models for it. Load the model in that server yourself and type its name here."
        case .unreachable(let url):
            return "Couldn't reach Ollama at \(url)."
        case .modelMissing(let model):
            return "The model \"\(model)\" isn't downloaded.\n\nOpen Spool Settings, pick one of the installed models, or hit + to download \"\(model)\"."
        case .pullFailed(let model, let reason):
            return "Couldn't download \(model).\n\(reason)"
        case .deleteFailed(let model, let reason):
            return "Couldn't remove \(model).\n\(reason)"
        case .badResponse:
            return "Ollama sent back something Spool didn't understand."
        }
    }
}

/// talks to ollama's native api (not the openai-compatible /v1 one) to list, download and remove models. only works against a local ollama
enum ModelLibrary {

    /// native api root for a configured server url, nil for anything we don't manage
    static func nativeBase(for serverURL: String) -> URL? {
        OllamaManager.managedBase(for: serverURL)
    }

    static func isManaged(_ serverURL: String) -> Bool {
        nativeBase(for: serverURL) != nil
    }

    /// ollama treats a bare name as ":latest", so compare canonical forms
    static func canonical(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        // a digest ("model@sha256:…") or an explicit tag is already canonical
        if trimmed.contains("@") { return trimmed }
        let lastComponent = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        return lastComponent.contains(":") ? trimmed : trimmed + ":latest"
    }

    // MARK: - Listing

    /// everything `ollama list` would show, newest-looking name order
    static func installed(serverURL: String) async throws -> [InstalledModel] {
        guard let base = nativeBase(for: serverURL) else {
            throw ModelLibraryError.unmanagedServer(serverURL)
        }
        try await OllamaManager.ensureRunning(serverURL: serverURL)

        var request = URLRequest(url: base.appendingPathComponent("api/tags"))
        request.timeoutInterval = 15
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw ModelLibraryError.unreachable(base.absoluteString)
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["models"] as? [[String: Any]]
        else { throw ModelLibraryError.badResponse }

        return rows.compactMap { row in
            guard let name = (row["name"] as? String) ?? (row["model"] as? String) else { return nil }
            let details = row["details"] as? [String: Any] ?? [:]
            return InstalledModel(
                name: name,
                sizeBytes: (row["size"] as? NSNumber)?.int64Value ?? 0,
                parameterSize: details["parameter_size"] as? String ?? "",
                quantization: details["quantization_level"] as? String ?? ""
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// preflight for a job: makes sure the configured model is actually on disk, so the failure reads like advice instead of an http 404 from the server
    static func verifyAvailable(model: String, serverURL: String) async throws {
        guard isManaged(serverURL) else { return }   // someone else's server, someone else's problem
        let wanted = canonical(model)
        let names = try await installed(serverURL: serverURL).map { canonical($0.name) }
        guard names.contains(wanted) else {
            throw ModelLibraryError.modelMissing(model)
        }
    }

    // MARK: - Pulling

    /// streams `api/pull`, reporting progress until the download finishes
    static func pull(model: String, serverURL: String,
                     onProgress: @escaping (PullProgress) -> Void) async throws {
        guard let base = nativeBase(for: serverURL) else {
            throw ModelLibraryError.unmanagedServer(serverURL)
        }
        try await OllamaManager.ensureRunning(serverURL: serverURL)

        var request = URLRequest(url: base.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 120        // idle gap between chunks
        sessionConfig.timeoutIntervalForResource = 24 * 3600 // a 40gb model on hotel wifi
        let session = URLSession(configuration: sessionConfig)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw ModelLibraryError.unreachable(base.absoluteString)
        }

        guard let http = response as? HTTPURLResponse else { throw ModelLibraryError.badResponse }
        guard http.statusCode == 200 else {
            let reason = await firstError(in: bytes.lines) ?? "HTTP \(http.statusCode)"
            throw ModelLibraryError.pullFailed(model, humanize(reason, model: model))
        }

        onProgress(PullProgress(status: "contacting the registry…"))
        var sawSuccess = false

        for try await line in bytes.lines {
            try Task.checkCancellation()
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            // a bad model name comes back mid-stream, http 200 and all
            if let message = object["error"] as? String {
                throw ModelLibraryError.pullFailed(model, humanize(message, model: model))
            }

            let status = object["status"] as? String ?? ""
            if status.lowercased() == "success" { sawSuccess = true }
            onProgress(PullProgress(
                status: prettyStatus(status),
                completed: (object["completed"] as? NSNumber)?.int64Value ?? 0,
                total: (object["total"] as? NSNumber)?.int64Value ?? 0
            ))
        }

        guard sawSuccess else {
            throw ModelLibraryError.pullFailed(model, "The download stopped before it finished.")
        }
    }

    // MARK: - Deleting

    static func delete(model: String, serverURL: String) async throws {
        guard let base = nativeBase(for: serverURL) else {
            throw ModelLibraryError.unmanagedServer(serverURL)
        }
        try await OllamaManager.ensureRunning(serverURL: serverURL)

        var request = URLRequest(url: base.appendingPathComponent("api/delete"))
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model])
        request.timeoutInterval = 30

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ModelLibraryError.unreachable(base.absoluteString)
        }
        guard let http = response as? HTTPURLResponse else { throw ModelLibraryError.badResponse }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ModelLibraryError.deleteFailed(model, body.isEmpty ? "HTTP \(http.statusCode)" : body)
        }
    }

    // MARK: - Helpers
    private static func prettyStatus(_ status: String) -> String {
        let lower = status.lowercased()
        if status.isEmpty { return "downloading…" }
        if lower.hasPrefix("pulling manifest") { return "reading the manifest…" }
        if lower.hasPrefix("pulling") { return "downloading…" }
        if lower.hasPrefix("verifying") { return "verifying…" }
        if lower.hasPrefix("writing") { return "writing to disk…" }
        if lower == "success" { return "done" }
        return status
    }

    /// ollama's registry errors are blunt, this makes the common one readable
    private static func humanize(_ message: String, model: String) -> String {
        let lower = message.lowercased()
        if lower.contains("file does not exist") || lower.contains("not found") || lower.contains("no such") {
            return "There's no model called \"\(model)\" in the Ollama library. Check the name at ollama.com/library — tags matter too, e.g. qwen3:8b."
        }
        return message
    }

    private static func firstError(in lines: AsyncLineSequence<URLSession.AsyncBytes>) async -> String? {
        var body = ""
        do {
            for try await line in lines {
                body += line
                if body.count > 500 { break }
            }
        } catch { return nil }

        guard !body.isEmpty else { return nil }
        if let data = body.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = object["error"] as? String {
            return message
        }
        return body
    }

    static func prettyBytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: count)
    }
}

import Foundation

/// file logic shared between the menu bar app and the CLI
enum Drafts {
    static let draftExtensions: Set<String> = ["md", "markdown", "txt", "text"]

    static func isDraft(_ url: URL) -> Bool {
        guard draftExtensions.contains(url.pathExtension.lowercased()) else { return false }
        let base = url.deletingPathExtension().lastPathComponent
        // don't treat our own output as a draft, or watched folders would
        // keep offering to re-structure the file we just wrote
        if base.hasSuffix(".structured") { return false }
        if base.range(of: #"\.structured \d+$"#, options: .regularExpression) != nil { return false }
        return true
    }

    /// most recently modified draft anywhere under `folder`
    /// (hidden files and folders like .obsidian are skipped)
    static func newest(in folder: URL) -> URL? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return nil }

        var best: (url: URL, date: Date)?
        for case let url as URL in enumerator {
            guard isDraft(url),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let date = values.contentModificationDate
            else { continue }
            if best == nil || date > best!.date { best = (url, date) }
        }
        return best?.url
    }

    /// what a dropped, picked or typed path turned out to be
    enum Resolution {
        case draft(URL)
        case emptyFolder
        case unsupported
        case missing
    }

    /// resolves a path to a single draft, a folder standing in for its newest one
    static func resolve(_ url: URL) -> Resolution {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .missing
        }
        if isDirectory.boolValue {
            guard let newest = newest(in: url) else { return .emptyFolder }
            return .draft(newest)
        }
        guard draftExtensions.contains(url.pathExtension.lowercased()) else { return .unsupported }
        return .draft(url)
    }

    /// a fresh `name.structured.md` next to the original, never overwriting
    static func newFileURL(for url: URL) -> URL {
        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        var candidate = directory.appendingPathComponent("\(base).structured.md")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base).structured \(counter).md")
            counter += 1
        }
        return candidate
    }

    /// copies the original into the backups folder before an in-place rewrite
    @discardableResult
    static func backup(_ url: URL) throws -> URL {
        let dir = Paths.appSupport.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "md" : url.pathExtension
        let dest = dir.appendingPathComponent("\(base) \(formatter.string(from: Date())).\(ext)")
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    /// generates the structured document and writes it out per config,
    /// returns the url the result landed at
    static func structureAndWrite(raw: String, from url: URL, config: Config,
                                  onProgress: @escaping (LLMProgress) -> Void) async throws -> URL {
        try await OllamaManager.ensureRunning(serverURL: config.serverURL)
        onProgress(.loadingModel)
        let document = try await LLMClient(config: config).structure(raw, onProgress: onProgress)
        let outputURL: URL
        if config.writeInPlace {
            try backup(url)
            outputURL = url
        } else {
            outputURL = newFileURL(for: url)
        }
        try document.write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL
    }
}

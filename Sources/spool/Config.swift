import Foundation

struct Config {
    var serverURL = "http://localhost:11434/v1"
    var model = "qwen3.5:9b"
    var watchedFolder = ""     // empty = no folder being watched
    var writeInPlace = false   // false = new .structured.md file, true = rewrite original (backup kept)

    var watchedFolderURL: URL? {
        guard !watchedFolder.isEmpty else { return nil }
        return URL(fileURLWithPath: (watchedFolder as NSString).expandingTildeInPath, isDirectory: true)
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: Paths.configFile),
              let config = try? JSONDecoder().decode(Config.self, from: data)
        else { return Config() }
        return config
    }

    func save() {
        Paths.ensureAppSupport()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: Paths.configFile)
        }
    }
}

// custom decoding so old config files missing newer keys still load fine
extension Config: Codable {
    enum CodingKeys: String, CodingKey { case serverURL, model, watchedFolder, writeInPlace }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Config()
        serverURL = try container.decodeIfPresent(String.self, forKey: .serverURL) ?? defaults.serverURL
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? defaults.model
        watchedFolder = try container.decodeIfPresent(String.self, forKey: .watchedFolder) ?? defaults.watchedFolder
        writeInPlace = try container.decodeIfPresent(Bool.self, forKey: .writeInPlace) ?? defaults.writeInPlace
    }
}

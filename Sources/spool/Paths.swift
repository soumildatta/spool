import Foundation

enum Paths {
    static let appSupport = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Spool", isDirectory: true)
    static let pidFile = appSupport.appendingPathComponent("spool.pid")
    static let configFile = appSupport.appendingPathComponent("config.json")
    static let logFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/spool.log")

    static func ensureAppSupport() {
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
    }
}

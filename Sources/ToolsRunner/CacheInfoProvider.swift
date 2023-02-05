import Foundation

struct CacheInfo: Codable {
    var directory: String
    var lastUsageDate: Date
    var checksum: String?
}

struct ToolsRunnerConfig: Codable {
    var cacheInfo: [String: CacheInfo] = [:]
}

struct CacheInfoProvider {
    private let rootDirectory: URL

    private var runnerConfigURL: URL {
        rootDirectory.appendingPathComponent("config.json")
    }

    private var cacheDirectory: URL {
        rootDirectory.appendingPathComponent("cache", isDirectory: true)
    }

    init() {
        rootDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".toolsRunner")
    }

    func removeOldCache() throws {
        var isDirectory: ObjCBool = false

        guard FileManager.default.fileExists(atPath: cacheDirectory.path, isDirectory: &isDirectory) else {
            return
        }

        guard isDirectory.boolValue else {
            try FileManager.default.removeItem(at: cacheDirectory)
            return
        }

        let runnerConfig = try runnerConfig()

        let allSubdirectories = FileManager.default.subpaths(atPath: cacheDirectory.path) ?? []

        let now = Date()

        let actualDirectories: Set<String> = runnerConfig.cacheInfo.values.reduce(into: []) { `set`, info in
            if info.lastUsageDate < now.addingTimeInterval(30 * 24 * 60 * 60) {
                `set`.insert(info.directory)
            }
        }

        for directoryName in allSubdirectories {
            guard !actualDirectories.contains(directoryName) else {
                continue
            }

            try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(directoryName))
        }
    }

    func cacheInfo(for url: URL) throws -> CacheInfo? {
        try runnerConfig().cacheInfo[url.absoluteString]
    }

    func cacheDirectoryIfExists(_ name: String) -> URL? {
        let url = cacheDirectory.appendingPathComponent(name)

        var isDirectory: ObjCBool = false

        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }

        return url
    }

    func newCacheDirectory() throws -> (name: String, url: URL) {
        let name = UUID().uuidString
        let url = cacheDirectory.appendingPathComponent(name, isDirectory: true)

        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (name, url)
    }

    func saveCacheInfo(_ cacheInfo: CacheInfo, for url: URL) throws {
        var cacheInfo = cacheInfo
        cacheInfo.lastUsageDate = Date()
        var config = try runnerConfig()

        let key = url.absoluteString

        if let prevValue = config.cacheInfo.updateValue(cacheInfo, forKey: key),
            prevValue.directory != cacheInfo.directory
        {
            try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(prevValue.directory))
        }

        try createCacheDirectoryIfNeeded()

        config.cacheInfo[key] = cacheInfo

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted

        let data = try encoder.encode(config)
        try data.write(to: runnerConfigURL)
    }

    private func runnerConfig() throws -> ToolsRunnerConfig {
        guard FileManager.default.fileExists(atPath: runnerConfigURL.path) else {
            return ToolsRunnerConfig()
        }

        let data = try Data(contentsOf: runnerConfigURL)
        let decoder = JSONDecoder()
        return try decoder.decode(ToolsRunnerConfig.self, from: data)
    }

    private func createCacheDirectoryIfNeeded() throws {
        if !FileManager.default.fileExists(atPath: cacheDirectory.path) {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
    }
}

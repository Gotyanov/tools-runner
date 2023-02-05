import Foundation

struct EnvironmentConfig {
    let executable: String
    let url: URL
    let checksum: String?
}

@main
struct ToolsRunner {
    static func main() async throws {
        var configSearchDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        while true {
            let configURL = configSearchDirectory.appendingPathComponent(".toolsEnv")

            var isDirectory: ObjCBool = false

            if FileManager.default.fileExists(atPath: configURL.path, isDirectory: &isDirectory),
               !isDirectory.boolValue
            {
                let config = try readEnvironmentConfig(configURL)

                try await run(with: config, environmentConfigDirectory: configSearchDirectory)
                return
            }

            configSearchDirectory = configSearchDirectory.deletingLastPathComponent()

            if configSearchDirectory.path == "/" {
                throw EnvConfigNotFoundError()
            }
        }
    }

    /**
     .toolsEnv config example:

     ```
     EXECUTABLE = BuildTools
     URL[arm64] = https://path/to/archive.zip
     CHECKSUM[arm64] = 12345
     URL[x86_64] = https://path/to/archive.zip
     CHECKSUM[x86_64] = 12345
     ```
     */
    static func readEnvironmentConfig(_ configURL: URL) throws -> EnvironmentConfig {
        let data = try Data(contentsOf: configURL)
        let lines = String(data: data, encoding: .utf8)?.split(separator: "\n") ?? []

        let rawConfig: [String: String] = lines.reduce(into: [:]) { dict, line in
            guard let index = line.firstIndex(of: "=") else {
                return
            }

            let key = line[..<index].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: index)...].trimmingCharacters(in: .whitespaces)

            dict[key] = value
        }

        let executable = rawConfig["EXECUTABLE"] ?? ""
        let urlString = rawConfig["URL[\(architecture)]"] ?? rawConfig["URL"] ?? ""
        let checksum = rawConfig["CHECKSUM[\(architecture)]"] ?? rawConfig["CHECKSUM"]

        let isLocalFile = urlString.hasPrefix("file://")

        guard !executable.isEmpty,
              !urlString.isEmpty,
              !(checksum ?? "").isEmpty || isLocalFile
        else {
            var unspecifiedKeys: [String] = []

            if executable.isEmpty {
                unspecifiedKeys.append("EXECUTABLE")
            }

            if urlString.isEmpty {
                unspecifiedKeys.append("URL")
            }

            if (checksum ?? "").isEmpty {
                unspecifiedKeys.append("CHECKSUM")
            }

            throw RequiredValuesAreNotSpecifiedError(keys: unspecifiedKeys)
        }

        guard let url = URL(string: urlString) else {
            throw InvalidUrlError(urlString: urlString)
        }

        return EnvironmentConfig(executable: executable, url: url, checksum: checksum)
    }

    static func run(with config: EnvironmentConfig, environmentConfigDirectory: URL) async throws {
        let cacheInfoProvider = CacheInfoProvider()

        if let cacheInfo = try cacheInfoProvider.cacheInfo(for: environmentConfigDirectory),
           cacheInfo.checksum == config.checksum,
           let cacheDirectory = cacheInfoProvider.cacheDirectoryIfExists(cacheInfo.directory)
        {
            try cacheInfoProvider.saveCacheInfo(cacheInfo, for: environmentConfigDirectory)
            try runExecutable(config.executable, in: cacheDirectory, envConfigDirectory: environmentConfigDirectory)
        } else {
            let (cacheDirectoryName, cacheDirectoryURL) = try cacheInfoProvider.newCacheDirectory()
            try await fetchAndUnzip(config.url, checksum: config.checksum, destination: cacheDirectoryURL)

            try cacheInfoProvider.saveCacheInfo(
                CacheInfo(directory: cacheDirectoryName, lastUsageDate: Date()),
                for: environmentConfigDirectory
            )

            try runExecutable(config.executable, in: cacheDirectoryURL, envConfigDirectory: environmentConfigDirectory)
        }
    }

    static func runExecutable(_ executable: String, in directory: URL, envConfigDirectory: URL) throws -> Never {
        let executableURL = directory.appendingPathComponent(executable)

        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw FileDoesNotExistError(name: executable)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())

        var environment = ProcessInfo.processInfo.environment
        environment["TOOLS_EVN_DIR"] = envConfigDirectory.path
        process.environment = environment

        let pipe = Pipe()
        process.standardInput = pipe

        let fileHandle = FileHandle(fileDescriptor: STDIN_FILENO)
        fileHandle.readabilityHandler = { handle in
            pipe.fileHandleForWriting.write(handle.availableData)
        }

        try process.run()
        process.waitUntilExit()
        exit(process.terminationStatus)
    }

    static func fetchAndUnzip(_ url: URL, checksum: String?, destination: URL) async throws {
        if checksum == nil, url.scheme != "file" {
            throw MissingChecksumError()
        }

        if url.scheme == "file" {
            try unzip(url, destination: destination)
        } else {
            let (data, _) = try await URLSession.shared.data(from: url)
            let tempFileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try data.write(to: tempFileURL)

            defer {
                try? FileManager.default.removeItem(at: tempFileURL)
            }

            try unzip(tempFileURL, destination: destination)
        }
    }

    private static func unzip(_ archive: URL, destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = [archive.path, "-d", destination.path]

        let errorOutput = Pipe()
        process.standardError = errorOutput
        process.standardInput = nil
        process.standardOutput = nil

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let outputData = errorOutput.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: outputData, encoding: .utf8)
            throw UnzipError(message: text ?? "")
        }
    }

    static var architecture: String {
#if arch(arm64)
        return "arm64"
#elseif arch(x86_64)
        return "x86_64"
#else
        fatalError("not supported architecture.")
#endif
    }
}

struct RequiredValuesAreNotSpecifiedError: Error, CustomStringConvertible {
    var keys: [String]

    var description: String {
        "Please specify values \(keys.joined(separator: ", ")) in .toolsEnv file."
    }
}

struct InvalidUrlError: Error, CustomStringConvertible {
    let urlString: String

    var description: String {
        "URL \"\(urlString)\" is invalid."
    }
}

struct EnvConfigNotFoundError: Error, CustomStringConvertible {
    var description: String {
        ".toolsEnv file not found."
    }
}

struct MissingChecksumError: Error, CustomStringConvertible {
    var description: String {
        "CHECKSUM should be set for remote archives."
    }
}

struct UnzipError: Error, CustomStringConvertible {
    let message: String

    var description: String {
        "Unzip error: \(message)"
    }
}

struct FileDoesNotExistError: Error, CustomStringConvertible {
    let name: String

    var description: String {
        "File \(name) doesn't exist."
    }
}

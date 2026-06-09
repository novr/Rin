import Foundation

struct DiffedSwiftFile: Equatable {
    let path: String
    let source: String
}

enum GitDiffProviderError: Error, LocalizedError {
    case gitFailed(String)

    var errorDescription: String? {
        switch self {
        case .gitFailed(let message):
            return "Failed to read git diff context: \(message)"
        }
    }
}

struct GitDiffProvider {
    init() {}

    func changedSwiftFiles(projectRootURL: URL) throws -> [DiffedSwiftFile] {
        let filePaths = try changedSwiftPaths(projectRootURL: projectRootURL)
        return filePaths.compactMap { path in
            let fileURL = projectRootURL.appendingPathComponent(path)
            guard let source = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
            return DiffedSwiftFile(path: path, source: source)
        }
    }

    private func changedSwiftPaths(projectRootURL: URL) throws -> [String] {
        let unstaged = try runGit(
            arguments: ["diff", "--name-only", "--diff-filter=ACMR"],
            projectRootURL: projectRootURL
        )
        let staged = try runGit(
            arguments: ["diff", "--cached", "--name-only", "--diff-filter=ACMR"],
            projectRootURL: projectRootURL
        )
        let untracked = try runGit(
            arguments: ["ls-files", "--others", "--exclude-standard"],
            projectRootURL: projectRootURL
        )

        var seen = Set<String>()
        var merged: [String] = []
        for path in (unstaged + staged + untracked) where path.hasSuffix(".swift") {
            if seen.insert(path).inserted {
                merged.append(path)
            }
        }
        return merged
    }

    private func runGit(arguments: [String], projectRootURL: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", projectRootURL.path] + arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw GitDiffProviderError.gitFailed(stderr.isEmpty ? "git returned \(process.terminationStatus)" : stderr)
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8) ?? ""
        return raw.split(separator: "\n").map(String.init)
    }
}

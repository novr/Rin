import ArgumentParser
import Foundation
import RinCore

@main
struct RinterCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rinter",
        abstract: "Run semantic policy checks from Rinfile.swift.",
        version: RinterCLIVersion.value
    )

    @Option(name: [.short, .long], help: "Path to Rinfile.swift")
    var config: String = "Rinfile.swift"

    @Option(name: [.short, .long], help: "Run a specific rule ID only")
    var rule: String?

    @Flag(name: [.short, .long], help: "Enable verbose output")
    var verbose = false

    @Flag(name: [.short, .long], help: "Evaluate all Swift files under project root")
    var allFiles = false

    mutating func run() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let engine = RinterEngine(
            projectRootURL: root,
            rinfileURL: root.appendingPathComponent(config),
            ruleFilter: rule,
            verbose: verbose,
            checkAllFiles: allFiles
        )

        do {
            try await engine.run()
        } catch let error as RinterEngineError {
            switch error {
            case .violation(let message):
                fputs("❌ \(message)\n", stderr)
                throw ExitCode(rawValue: 1)
            case .runtime(let message):
                fputs("❌ \(message)\n", stderr)
                throw ExitCode(rawValue: 2)
            }
        } catch {
            fputs("❌ \(error.localizedDescription)\n", stderr)
            throw ExitCode(rawValue: 2)
        }
    }
}

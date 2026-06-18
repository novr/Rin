import Foundation
import PackagePlugin

@main
struct RinterPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let tool = try context.tool(named: "RinterCLI")

        let process = Process()
        process.executableURL = tool.url
        process.arguments = arguments
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw NSError(
                domain: "RinterPlugin",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "RinterCLI failed with code \(process.terminationStatus)"]
            )
        }
    }
}

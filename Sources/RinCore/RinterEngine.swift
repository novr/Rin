import Foundation

public enum RinterEngineError: Error, LocalizedError {
    case violation(String)
    case runtime(String)

    public var errorDescription: String? {
        switch self {
        case .violation(let message):
            return message
        case .runtime(let message):
            return message
        }
    }
}

public struct RinterEngine {
    private let semanticEngine: RinterSemanticEngine
    private let ruleFilter: String?
    private let logger: RinLogger
    private let failOnEmpty: Bool
    private let outputFormat: RinOutputFormat
    private let writeStandardOutput: (String) throws -> Void
    private let checkConfig: Bool
    private let validateConfig: () throws -> Void

    public init(
        projectRootURL: URL,
        rinfileURL: URL,
        ruleFilter: String? = nil,
        verbose: Bool = false,
        checkAllFiles: Bool = false,
        failOnEmpty: Bool = false,
        outputFormat: RinOutputFormat = .text,
        checkConfig: Bool = false
    ) {
        let logger = ConsoleLogger(verbose: verbose)
        let rinfileValidator = RinConfigValidator()
        self.semanticEngine = RinterSemanticEngine(
            projectRootURL: projectRootURL,
            rinfileURL: rinfileURL,
            checkAllFiles: checkAllFiles,
            logger: logger
        )
        self.ruleFilter = ruleFilter
        self.logger = logger
        self.failOnEmpty = failOnEmpty
        self.outputFormat = outputFormat
        self.writeStandardOutput = Self.defaultWriteStandardOutput
        self.checkConfig = checkConfig
        self.validateConfig = {
            try rinfileValidator.validate(at: rinfileURL)
        }
    }

    init(
        semanticEngine: RinterSemanticEngine,
        ruleFilter: String? = nil,
        verbose: Bool = false,
        failOnEmpty: Bool = false,
        outputFormat: RinOutputFormat = .text,
        writeStandardOutput: @escaping (String) throws -> Void = RinterEngine.defaultWriteStandardOutput,
        checkConfig: Bool = false,
        validateConfig: @escaping () throws -> Void = {}
    ) {
        self.semanticEngine = semanticEngine
        self.ruleFilter = ruleFilter
        self.logger = ConsoleLogger(verbose: verbose)
        self.failOnEmpty = failOnEmpty
        self.outputFormat = outputFormat
        self.writeStandardOutput = writeStandardOutput
        self.checkConfig = checkConfig
        self.validateConfig = validateConfig
    }

    public func run() async throws {
        if checkConfig {
            try runConfigCheck()
            return
        }
        try await runCheck()
    }

    private func runConfigCheck() throws {
        do {
            try validateConfig()
            logger.success("Rinfile configuration is valid.")
        } catch {
            throw RinterEngineError.runtime(error.localizedDescription)
        }
    }

    private func runCheck() async throws {
        do {
            try await semanticEngine.check(ruleID: ruleFilter)
            if outputFormat == .json {
                try writeViolationsJSON([])
            } else {
                logger.success("Semantic policy check passed.")
            }
        } catch let semanticError as RinterSemanticEngineError {
            switch semanticError {
            case .noSwiftFilesToCheck:
                if failOnEmpty {
                    throw RinterEngineError.violation("No Swift files to evaluate.")
                }
                if outputFormat == .json {
                    try writeViolationsJSON([])
                } else {
                    logger.info("No Swift files to evaluate.")
                }
            case .violations(let violations):
                if outputFormat == .json {
                    try writeViolationsJSON(violations)
                } else {
                    logger.error("Semantic policy violation(s) found.")
                    for violation in violations {
                        let location = [
                            violation.file ?? "unknown",
                            violation.line.map(String.init) ?? "?",
                            violation.column.map(String.init) ?? "?"
                        ].joined(separator: ":")
                        logger.error("\(location): [\(violation.ruleId)] \(violation.reason)")
                    }
                }
                throw RinterEngineError.violation("Semantic policy violations detected.")
            case .runtime(let reason):
                throw RinterEngineError.runtime(reason)
            }
        } catch {
            throw RinterEngineError.runtime(error.localizedDescription)
        }
    }

    private func writeViolationsJSON(_ violations: [RinSemanticViolation]) throws {
        try writeStandardOutput(try RinViolationJSON.encodedLine(violations))
    }

    private static func defaultWriteStandardOutput(_ line: String) throws {
        guard let data = line.data(using: .utf8) else {
            throw RinterEngineError.runtime("Failed to encode JSON output.")
        }
        FileHandle.standardOutput.write(data)
    }
}

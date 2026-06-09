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

    public init(
        projectRootURL: URL,
        rinfileURL: URL,
        ruleFilter: String? = nil,
        verbose: Bool = false
    ) {
        let logger = ConsoleLogger(verbose: verbose)
        self.semanticEngine = RinterSemanticEngine(
            projectRootURL: projectRootURL,
            rinfileURL: rinfileURL,
            logger: logger
        )
        self.ruleFilter = ruleFilter
        self.logger = logger
    }

    init(
        semanticEngine: RinterSemanticEngine,
        ruleFilter: String? = nil,
        verbose: Bool = false
    ) {
        self.semanticEngine = semanticEngine
        self.ruleFilter = ruleFilter
        self.logger = ConsoleLogger(verbose: verbose)
    }

    public func run() async throws {
        try await runCheck()
    }

    private func runCheck() async throws {
        do {
            try await semanticEngine.check(ruleID: ruleFilter)
            logger.success("Semantic policy check passed.")
        } catch let semanticError as RinterSemanticEngineError {
            switch semanticError {
            case .noSwiftFilesToCheck:
                logger.info("No changed Swift files to evaluate.")
            case .violations(let violations):
                logger.error("Semantic policy violation(s) found.")
                for violation in violations {
                    let location = [
                        violation.file ?? "unknown",
                        violation.line.map(String.init) ?? "?",
                        violation.column.map(String.init) ?? "?"
                    ].joined(separator: ":")
                    logger.error("\(location): [\(violation.ruleId)] \(violation.reason)")
                }
                throw RinterEngineError.violation("Semantic policy violations detected.")
            case .runtime(let reason):
                throw RinterEngineError.runtime(reason)
            }
        } catch {
            throw RinterEngineError.runtime(error.localizedDescription)
        }
    }
}

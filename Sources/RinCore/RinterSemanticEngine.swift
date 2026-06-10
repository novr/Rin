import Foundation

enum RinterSemanticEngineError: Error, LocalizedError {
    case noSwiftFilesToCheck
    case violations([RinSemanticViolation])
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .noSwiftFilesToCheck:
            return "No Swift files to evaluate."
        case .violations(let violations):
            let details = violations.map {
                let location = [($0.file ?? "unknown"), $0.line.map(String.init) ?? "?", $0.column.map(String.init) ?? "?"]
                    .joined(separator: ":")
                return "\(location): [\($0.ruleId)] \($0.reason)"
            }
            return details.joined(separator: "\n")
        case .runtime(let reason):
            return reason
        }
    }
}

struct RinterSemanticEngine {
    private let projectRootURL: URL
    private let rinfileURL: URL
    private let loadPolicy: (URL) throws -> RinPolicy
    private let loadFiles: (URL) throws -> [DiffedSwiftFile]
    private let evaluator: RinRuleEvaluating
    private let logger: RinLogger

    init(
        projectRootURL: URL,
        rinfileURL: URL,
        rinfileLoader: RinfileLoader = .init(),
        diffProvider: GitDiffProvider = .init(),
        checkAllFiles: Bool = false,
        evaluator: RinRuleEvaluating = SwiftSyntaxRuleEvaluator(),
        logger: RinLogger = ConsoleLogger(verbose: false)
    ) {
        self.projectRootURL = projectRootURL
        self.rinfileURL = rinfileURL
        self.loadPolicy = rinfileLoader.load
        self.loadFiles = { root in
            if checkAllFiles {
                return try diffProvider.allSwiftFiles(projectRootURL: root)
            }
            return try diffProvider.changedSwiftFiles(projectRootURL: root)
        }
        self.evaluator = evaluator
        self.logger = logger
    }

    init(
        projectRootURL: URL,
        rinfileURL: URL,
        loadPolicy: @escaping (URL) throws -> RinPolicy,
        loadFiles: @escaping (URL) throws -> [DiffedSwiftFile],
        evaluator: RinRuleEvaluating = SwiftSyntaxRuleEvaluator(),
        logger: RinLogger = ConsoleLogger(verbose: false)
    ) {
        self.projectRootURL = projectRootURL
        self.rinfileURL = rinfileURL
        self.loadPolicy = loadPolicy
        self.loadFiles = loadFiles
        self.evaluator = evaluator
        self.logger = logger
    }

    func check(
        ruleID: String? = nil
    ) async throws {
        let rawPolicy = try loadPolicy(rinfileURL)
        let policy: RinPolicy
        if let ruleID, !ruleID.isEmpty {
            let filtered = rawPolicy.rules.filter { $0.id == ruleID }
            guard !filtered.isEmpty else {
                throw RinterSemanticEngineError.runtime("Rule not found: \(ruleID)")
            }
            policy = RinPolicy(include: rawPolicy.include, exclude: rawPolicy.exclude, rules: filtered)
        } else {
            policy = rawPolicy
        }

        let swiftFiles = try loadFiles(projectRootURL)
        let targetFiles = swiftFiles.filter {
            shouldEvaluate(path: $0.path, include: policy.include, exclude: policy.exclude)
        }
        guard !targetFiles.isEmpty else {
            throw RinterSemanticEngineError.noSwiftFilesToCheck
        }

        var allViolations: [RinSemanticViolation] = []
        for rule in policy.rules {
            let scopedFiles = targetFiles.filter {
                shouldEvaluate(path: $0.path, include: rule.scopeInclude, exclude: rule.scopeExclude)
            }
            guard !scopedFiles.isEmpty else { continue }

            let scopedPolicy = RinPolicy(
                include: policy.include,
                exclude: policy.exclude,
                rules: [rule]
            )
            for file in scopedFiles {
                logger.debug("Evaluating \(file.path) [\(rule.id)]")
                let violations = try evaluator.evaluate(file: file, policy: scopedPolicy)
                allViolations.append(contentsOf: violations)
            }
        }

        if !allViolations.isEmpty {
            throw RinterSemanticEngineError.violations(allViolations)
        }
    }

    private func shouldEvaluate(path: String, include: [String], exclude: [String]) -> Bool {
        if !include.isEmpty && !include.contains(where: { wildcardMatches(path, pattern: $0) }) {
            return false
        }
        if exclude.contains(where: { wildcardMatches(path, pattern: $0) }) {
            return false
        }
        return true
    }

    private func wildcardMatches(_ text: String, pattern: String) -> Bool {
        let placeholder = "__DOUBLE_STAR__"
        let tokenized = pattern.replacingOccurrences(of: "**", with: placeholder)
        let regexPattern = NSRegularExpression.escapedPattern(for: tokenized)
            .replacingOccurrences(of: placeholder, with: ".*")
            .replacingOccurrences(of: "\\*", with: "[^/]*")
        guard let regex = try? NSRegularExpression(pattern: "^\(regexPattern)$") else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}

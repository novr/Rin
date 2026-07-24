import Foundation

enum RinConfigValidatorError: Error, LocalizedError {
    case duplicateRuleID(String)
    case emptyRuleID
    case emptyRuleBody(String)

    var errorDescription: String? {
        switch self {
        case .duplicateRuleID(let id):
            return "Duplicate rule ID: \(id)"
        case .emptyRuleID:
            return "Rule ID must not be empty."
        case .emptyRuleBody(let id):
            return "Rule body must not be empty: \(id)"
        }
    }
}

struct RinConfigValidator {
    private let loadPolicy: (URL) throws -> RinPolicy

    init(loader: RinfileLoader = .init()) {
        self.loadPolicy = loader.load
    }

    init(loadPolicy: @escaping (URL) throws -> RinPolicy) {
        self.loadPolicy = loadPolicy
    }

    func validate(at rinfileURL: URL) throws {
        let policy = try loadPolicy(rinfileURL)
        var ruleIDs = Set<String>()

        for rule in policy.rules {
            guard !rule.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RinConfigValidatorError.emptyRuleID
            }
            guard ruleIDs.insert(rule.id).inserted else {
                throw RinConfigValidatorError.duplicateRuleID(rule.id)
            }
            guard !rule.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RinConfigValidatorError.emptyRuleBody(rule.id)
            }
            try SwiftSyntaxRuleEvaluator.validate(rule: rule)
        }
    }
}

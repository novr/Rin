import Foundation

enum Rin {
    static func Policy(@PolicyBuilder _ content: () -> [PolicyElement]) -> PolicyDocument {
        PolicyDocument(elements: content())
    }
}

@resultBuilder
enum PolicyBuilder {
    static func buildBlock(_ components: PolicyElement...) -> [PolicyElement] {
        components
    }
}

@resultBuilder
enum RulesBuilder {
    static func buildBlock(_ components: Rule...) -> [Rule] {
        components
    }
}

@resultBuilder
enum RuleBodyBuilder {
    static func buildBlock(_ components: String...) -> String {
        components.joined(separator: "\n")
    }

    static func buildExpression(_ expression: String) -> String {
        expression
    }

    static func buildExpression(_ expression: RuleClause) -> String {
        expression.rendered
    }

    static func buildOptional(_ component: String?) -> String {
        component ?? ""
    }

    static func buildEither(first component: String) -> String {
        component
    }

    static func buildEither(second component: String) -> String {
        component
    }
}

struct PolicyDocument {
    let elements: [PolicyElement]

    init(elements: [PolicyElement]) {
        self.elements = elements
    }
}

enum PolicyElement {
    case target(TargetConfig)
    case rules([Rule])
}

struct TargetConfig {
    let include: [String]
    let exclude: [String]

    init(include: [String] = [], exclude: [String] = []) {
        self.include = include
        self.exclude = exclude
    }
}

enum Severity: String, Codable {
    case warning
    case error
}

struct Rule {
    let id: String
    let body: String
    let messageText: String?
    let severityValue: Severity?
    let scopeInclude: [String]
    let scopeExclude: [String]

    init(id: String, @RuleBodyBuilder body: () -> String) {
        self.id = id
        self.body = body()
        self.messageText = nil
        self.severityValue = nil
        self.scopeInclude = []
        self.scopeExclude = []
    }

    private init(
        id: String,
        body: String,
        messageText: String?,
        severityValue: Severity?,
        scopeInclude: [String],
        scopeExclude: [String]
    ) {
        self.id = id
        self.body = body
        self.messageText = messageText
        self.severityValue = severityValue
        self.scopeInclude = scopeInclude
        self.scopeExclude = scopeExclude
    }

    func message(_ text: String) -> Rule {
        Rule(
            id: id,
            body: body,
            messageText: text,
            severityValue: severityValue,
            scopeInclude: scopeInclude,
            scopeExclude: scopeExclude
        )
    }

    func severity(_ severity: Severity) -> Rule {
        Rule(
            id: id,
            body: body,
            messageText: messageText,
            severityValue: severity,
            scopeInclude: scopeInclude,
            scopeExclude: scopeExclude
        )
    }

    func scope(include: [String] = [], exclude: [String] = []) -> Rule {
        Rule(
            id: id,
            body: body,
            messageText: messageText,
            severityValue: severityValue,
            scopeInclude: include,
            scopeExclude: exclude
        )
    }
}

struct RuleClause {
    let rendered: String

    init(_ rendered: String) {
        self.rendered = rendered
    }
}

enum ErrorTarget {
    case `case`(String)

    fileprivate var rendered: String {
        switch self {
        case .case(let name):
            return #".case("\#(name)")"#
        }
    }
}

enum ErrorHandling {
    case through
    case assign(to: String)
    case transform(by: String)
    case rethrow

    fileprivate var rendered: String {
        switch self {
        case .through:
            return ".through"
        case .assign(let target):
            return #".assign(to: "\#(target)")"#
        case .transform(let function):
            return #".transform(by: "\#(function)")"#
        case .rethrow:
            return ".rethrow"
        }
    }
}

struct RuleCallTarget {
    let typeName: String
    let methodName: String

    init(_ typeName: String, _ methodName: String) {
        self.typeName = typeName
        self.methodName = methodName
    }

    fileprivate var rendered: String {
        "[\(typeName), \(methodName)]"
    }
}

func MustHandleError(target: ErrorTarget, as handling: ErrorHandling) -> RuleClause {
    RuleClause("MustHandleError(target: \(target.rendered), as: \(handling.rendered))")
}

func MustHandleError(check: ErrorTarget) -> RuleClause {
    MustHandleError(target: check, as: .through)
}

func MustCall(_ target: RuleCallTarget) -> RuleClause {
    RuleClause("MustCall(\(target.rendered))")
}

func MustCallAnyOf(_ targets: [RuleCallTarget]) -> RuleClause {
    let renderedTargets = targets.map(\.rendered).joined(separator: ", ")
    return RuleClause("MustCallAnyOf([\n\(renderedTargets)\n])")
}

func WhenCalls(_ trigger: RuleCallTarget, mustAlsoCall requirements: [RuleCallTarget]) -> RuleClause {
    let renderedRequirements = requirements.map(\.rendered).joined(separator: ", ")
    return RuleClause(
        "WhenCalls(\(trigger.rendered)).mustAlsoCall([\n\(renderedRequirements)\n])"
    )
}

func Target(include: [String] = [], exclude: [String] = []) -> PolicyElement {
    .target(.init(include: include, exclude: exclude))
}

func Rules(@RulesBuilder _ content: () -> [Rule]) -> PolicyElement {
    .rules(content())
}

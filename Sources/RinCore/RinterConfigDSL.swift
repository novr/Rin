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

    static func buildExpression(_ expression: WhenCallsNameClause) -> String {
        expression.rendered
    }

    static func buildExpression(_ expression: WhenCallsClause) -> String {
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

enum EmptyUnitPolicy {
    case skip
    case violate

    fileprivate var rendered: String {
        switch self {
        case .skip:
            return ".skip"
        case .violate:
            return ".violate"
        }
    }
}

enum FunctionNamePattern {
    case exact(String)
    case prefix(String)
    case suffix(String)

    fileprivate var rendered: String {
        switch self {
        case .exact(let value):
            return #".exact("\#(value)")"#
        case .prefix(let value):
            return #".prefix("\#(value)")"#
        case .suffix(let value):
            return #".suffix("\#(value)")"#
        }
    }
}

enum UnitPathScope {
    case everyFunction(ifEmpty: EmptyUnitPolicy = .violate)
    case namedFunctions(String, ifEmpty: EmptyUnitPolicy = .violate)
    case matchingFunctions(FunctionNamePattern, ifEmpty: EmptyUnitPolicy = .violate)
    case everyCatch(ifEmpty: EmptyUnitPolicy = .violate)
    case namedFunctionCatches(String, ifEmpty: EmptyUnitPolicy = .violate)

    fileprivate var rendered: String {
        switch self {
        case .everyFunction(let ifEmpty):
            return #"UnitPathScope.everyFunction(ifEmpty: \#(ifEmpty.rendered))"#
        case .namedFunctions(let name, let ifEmpty):
            return #"UnitPathScope.namedFunctions("\#(name)", ifEmpty: \#(ifEmpty.rendered))"#
        case .matchingFunctions(let pattern, let ifEmpty):
            return #"UnitPathScope.matchingFunctions(\#(pattern.rendered), ifEmpty: \#(ifEmpty.rendered))"#
        case .everyCatch(let ifEmpty):
            return #"UnitPathScope.everyCatch(ifEmpty: \#(ifEmpty.rendered))"#
        case .namedFunctionCatches(let name, let ifEmpty):
            return #"UnitPathScope.namedFunctionCatches("\#(name)", ifEmpty: \#(ifEmpty.rendered))"#
        }
    }
}

enum FollowUpScope {
    case sameFunction
    case entireFile

    fileprivate var rendered: String {
        switch self {
        case .sameFunction:
            return ".sameFunction"
        case .entireFile:
            return ".entireFile"
        }
    }
}

enum WhenUnmentionedPolicy {
    case skip
    case violate

    fileprivate var rendered: String {
        switch self {
        case .skip:
            return ".skip"
        case .violate:
            return ".violate"
        }
    }
}

enum TypeNamePattern {
    case exact(String)
    case prefix(String)
    case suffix(String)

    fileprivate var rendered: String {
        switch self {
        case .exact(let value):
            return #".exact("\#(value)")"#
        case .prefix(let value):
            return #".prefix("\#(value)")"#
        case .suffix(let value):
            return #".suffix("\#(value)")"#
        }
    }
}

enum LocalTypePattern {
    case anyConformance(String)

    fileprivate var rendered: String {
        switch self {
        case .anyConformance(let protocolName):
            return #".anyConformance("\#(protocolName)")"#
        }
    }
}

struct LocalBindingConstraint {
    let identifier: String
    let typePattern: LocalTypePattern
    let initializerIdentifier: String

    init(identifier: String, typePattern: LocalTypePattern, initializerIdentifier: String) {
        self.identifier = identifier
        self.typePattern = typePattern
        self.initializerIdentifier = initializerIdentifier
    }

    fileprivate var rendered: String {
        """
        LocalBindingConstraint(
            identifier: "\(identifier)",
            typePattern: \(typePattern.rendered),
            initializerIdentifier: "\(initializerIdentifier)"
        )
        """
    }
}

enum DeclarationConstraint {
    case local(binding: LocalBindingConstraint)

    fileprivate var rendered: String {
        switch self {
        case .local(let binding):
            return ".local(binding: \(binding.rendered))"
        }
    }
}

struct WhenCallsNameClause {
    fileprivate let rendered: String

    fileprivate init(rendered: String) {
        self.rendered = rendered
    }

    func inArgument(argumentLabel: String) -> WhenCallsNameClause {
        WhenCallsNameClause(
            rendered: #"\#(rendered).inArgument(argumentLabel: "\#(argumentLabel)")"#
        )
    }

    func mustUse(identifier: String) -> WhenCallsNameClause {
        WhenCallsNameClause(
            rendered: #"\#(rendered).mustUse(identifier: "\#(identifier)")"#
        )
    }

    func mustNotUse(identifier: String) -> RuleClause {
        RuleClause(
            #"\#(rendered).mustNotUse(identifier: "\#(identifier)")"#
        )
    }
}

struct WhenCallsClause {
    fileprivate let trigger: RuleCallTarget
    fileprivate let requirements: [RuleCallTarget]
    fileprivate let orRequirementGroups: [[RuleCallTarget]]
    fileprivate let followUpScope: FollowUpScope

    fileprivate init(
        trigger: RuleCallTarget,
        requirements: [RuleCallTarget] = [],
        orRequirementGroups: [[RuleCallTarget]] = [],
        followUpScope: FollowUpScope = .sameFunction
    ) {
        self.trigger = trigger
        self.requirements = requirements
        self.orRequirementGroups = orRequirementGroups
        self.followUpScope = followUpScope
    }

    func mustAlsoCall(receiver: RuleCallReceiver, method: String) -> WhenCallsClause {
        var updated = requirements
        updated.append(RuleCallTarget(receiver: receiver, method: method))
        return WhenCallsClause(
            trigger: trigger,
            requirements: updated,
            orRequirementGroups: orRequirementGroups,
            followUpScope: followUpScope
        )
    }

    func mustAlsoCallAnyOf(_ targets: [RuleCallTarget]) -> WhenCallsClause {
        var updated = orRequirementGroups
        updated.append(targets)
        return WhenCallsClause(
            trigger: trigger,
            requirements: requirements,
            orRequirementGroups: updated,
            followUpScope: followUpScope
        )
    }

    fileprivate var rendered: String {
        var result =
            "WhenCalls(receiver: \(trigger.receiver.rendered), method: \"\(trigger.methodName)\", onPath: \(followUpScope.rendered))"
        for requirement in requirements {
            result += ".mustAlsoCall(receiver: \(requirement.receiver.rendered), method: \"\(requirement.methodName)\")"
        }
        for group in orRequirementGroups {
            let renderedTargets = group.map(\.rendered).joined(separator: ",\n")
            result += ".mustAlsoCallAnyOf([\n\(renderedTargets)\n])"
        }
        return result
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

enum RuleCallReceiver {
    case symbol(String)
    case none
    case any

    fileprivate var rendered: String {
        switch self {
        case .symbol(let value):
            return #".symbol("\#(value)")"#
        case .none:
            return ".none"
        case .any:
            return ".any"
        }
    }
}

struct RuleCallTarget {
    let receiver: RuleCallReceiver
    let methodName: String

    init(receiver: RuleCallReceiver, method: String) {
        self.receiver = receiver
        self.methodName = method
    }

    fileprivate var rendered: String {
        #"RuleCallTarget(receiver: \#(receiver.rendered), method: "\#(methodName)")"#
    }
}

func MustHandleError(
    target: ErrorTarget,
    as handling: ErrorHandling,
    onPath: UnitPathScope = .everyCatch(),
    whenUnmentioned: WhenUnmentionedPolicy = .violate
) -> RuleClause {
    RuleClause(
        """
        MustHandleError(target: \(target.rendered), as: \(handling.rendered), onPath: \(onPath.rendered), whenUnmentioned: \(whenUnmentioned.rendered))
        """
    )
}

func MustHandleError(check: ErrorTarget) -> RuleClause {
    MustHandleError(target: check, as: .through)
}

func RuleCall(receiver: RuleCallReceiver, method: String) -> RuleCallTarget {
    RuleCallTarget(receiver: receiver, method: method)
}

func MustCall(
    receiver: RuleCallReceiver,
    method: String,
    onPath: UnitPathScope = .everyFunction()
) -> RuleClause {
    RuleClause(
        "MustCall(receiver: \(receiver.rendered), method: \"\(method)\", onPath: \(onPath.rendered))"
    )
}

func MustCall(_ target: RuleCallTarget, onPath: UnitPathScope = .everyFunction()) -> RuleClause {
    MustCall(receiver: target.receiver, method: target.methodName, onPath: onPath)
}

func MustCallAnyOf(_ targets: [RuleCallTarget], onPath: UnitPathScope = .everyFunction()) -> RuleClause {
    let renderedTargets = targets.map { target in
        "RuleCall(receiver: \(target.receiver.rendered), method: \"\(target.methodName)\")"
    }.joined(separator: ",\n")
    return RuleClause("MustCallAnyOf([\n\(renderedTargets)\n], onPath: \(onPath.rendered))")
}

func WhenCalls(_ trigger: RuleCallTarget, mustAlsoCall requirements: [RuleCallTarget]) -> RuleClause {
    var clause = WhenCallsClause(trigger: trigger)
    for requirement in requirements {
        clause = clause.mustAlsoCall(receiver: requirement.receiver, method: requirement.methodName)
    }
    return RuleClause(clause.rendered)
}

func WhenCalls(
    receiver: RuleCallReceiver,
    method: String,
    onPath: FollowUpScope = .sameFunction
) -> WhenCallsClause {
    WhenCallsClause(
        trigger: RuleCallTarget(receiver: receiver, method: method),
        followUpScope: onPath
    )
}

func MustDeclare(_ constraint: DeclarationConstraint, onPath: UnitPathScope = .everyFunction()) -> RuleClause {
    RuleClause("MustDeclare(\(constraint.rendered), onPath: \(onPath.rendered))")
}

func MustThrow(type: String, onPath: UnitPathScope = .everyFunction()) -> RuleClause {
    RuleClause("MustThrow(type: \"\(type)\", onPath: \(onPath.rendered))")
}

func WhenCalls(name: TypeNamePattern) -> WhenCallsNameClause {
    WhenCallsNameClause(
        rendered: "WhenCalls(name: \(name.rendered))"
    )
}

func Target(include: [String] = [], exclude: [String] = []) -> PolicyElement {
    .target(.init(include: include, exclude: exclude))
}

func Rules(@RulesBuilder _ content: () -> [Rule]) -> PolicyElement {
    .rules(content())
}

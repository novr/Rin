import Foundation
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

protocol RinRuleEvaluating {
    func evaluate(file: DiffedSwiftFile, policy: RinPolicy) throws -> [RinSemanticViolation]
}

enum SwiftSyntaxRuleEvaluatorError: Error, LocalizedError {
    case invalidSwiftFile(path: String, diagnostics: [String])
    case invalidRuleBody(ruleID: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidSwiftFile(let path, let diagnostics):
            if diagnostics.isEmpty {
                return "Failed to parse Swift file: \(path)"
            }
            let joinedDiagnostics = diagnostics.joined(separator: "\n")
            return """
            Failed to parse Swift file: \(path)
            \(joinedDiagnostics)
            """
        case .invalidRuleBody(let ruleID, let reason):
            return "Failed to parse rule body for `\(ruleID)`: \(reason)"
        }
    }
}

struct SwiftSyntaxRuleEvaluator: RinRuleEvaluating {
    func evaluate(file: DiffedSwiftFile, policy: RinPolicy) throws -> [RinSemanticViolation] {
        let syntax = Parser.parse(source: file.source)
        guard !syntax.hasError else {
            let converter = SourceLocationConverter(fileName: file.path, tree: syntax)
            let diagnostics = ParseDiagnosticsGenerator.diagnostics(for: syntax).map { diagnostic in
                let position = diagnostic.position
                let location = converter.location(for: position)
                return "\(location.line):\(location.column) \(diagnostic.message)"
            }
            throw SwiftSyntaxRuleEvaluatorError.invalidSwiftFile(path: file.path, diagnostics: diagnostics)
        }

        let converter = SourceLocationConverter(fileName: file.path, tree: syntax)
        let collector = FunctionCallCollector(converter: converter, viewMode: .sourceAccurate)
        collector.walk(syntax)
        let calls = collector.calls
        let catchClauses = collector.catchClauses

        var violations: [RinSemanticViolation] = []
        for rule in policy.rules {
            violations.append(
                contentsOf: try evaluateRule(
                    rule,
                    calls: calls,
                    catchClauses: catchClauses,
                    filePath: file.path
                )
            )
        }
        return violations
    }

    private func evaluateRule(
        _ rule: RinRule,
        calls: [CallSite],
        catchClauses: [CatchClauseSite],
        filePath: String
    ) throws -> [RinSemanticViolation] {
        var violations: [RinSemanticViolation] = []
        let fallbackLocation = calls.first.map { ($0.line, $0.column) }
            ?? catchClauses.first.map { ($0.line, $0.column) }
            ?? (1, 1)
        let parsedRuleBody: ParsedRuleBody
        do {
            parsedRuleBody = try RuleBodyParser.parse(body: rule.body)
        } catch let parserError as RuleBodyParserError {
            throw SwiftSyntaxRuleEvaluatorError.invalidRuleBody(ruleID: rule.id, reason: parserError.localizedDescription)
        }

        for requiredCall in parsedRuleBody.mustCallTargets {
            if !matches(requiredCall, in: calls) {
                violations.append(
                    RinSemanticViolation(
                        ruleId: rule.id,
                        reason: "Required call `\(requiredCall.rendered)` was not found.",
                        file: filePath,
                        line: fallbackLocation.0,
                        column: fallbackLocation.1
                    )
                )
            }
        }

        for anyGroup in parsedRuleBody.mustCallAnyOfGroups {
            if anyGroup.allSatisfy({ !matches($0, in: calls) }) {
                violations.append(
                    RinSemanticViolation(
                        ruleId: rule.id,
                        reason: "At least one required call was not found: \(anyGroup.map(\.rendered).joined(separator: ", ")).",
                        file: filePath,
                        line: fallbackLocation.0,
                        column: fallbackLocation.1
                    )
                )
            }
        }

        for conditional in parsedRuleBody.whenCallsConditions {
            guard let triggerCall = firstMatch(conditional.trigger, in: calls) else { continue }
            let missing = conditional.requirements.filter { !matches($0, in: calls) }
            if !missing.isEmpty {
                violations.append(
                    RinSemanticViolation(
                        ruleId: rule.id,
                        reason: "When `\(conditional.trigger.rendered)` is called, required calls are missing: \(missing.map(\.rendered).joined(separator: ", ")).",
                        file: filePath,
                        line: triggerCall.line,
                        column: triggerCall.column
                    )
                )
            }
        }

        for errorCheck in parsedRuleBody.mustHandleErrorChecks {
            // If a file has no catch clause, skip this rule.
            guard !catchClauses.isEmpty else { continue }
            switch errorCheck {
            case .case(let requiredCase):
                if !catchClauses.contains(where: { $0.handledCases.contains(requiredCase) }) {
                    violations.append(
                        RinSemanticViolation(
                            ruleId: rule.id,
                            reason: "Required catch handling `case .\(requiredCase)` was not found.",
                            file: filePath,
                            line: fallbackLocation.0,
                            column: fallbackLocation.1
                        )
                    )
                }
            }
        }

        return violations
    }

    private func matches(_ target: RuleCallPattern, in calls: [CallSite]) -> Bool {
        firstMatch(target, in: calls) != nil
    }

    private func firstMatch(_ target: RuleCallPattern, in calls: [CallSite]) -> CallSite? {
        return calls.first { call in
            guard call.method == target.methodName else { return false }
            if target.typeName == "*" { return true }
            guard case .simpleName(let receiverName) = call.receiver else { return false }
            return receiverName == target.typeName
        }
    }
}

private final class FunctionCallCollector: SyntaxVisitor {
    private let converter: SourceLocationConverter
    private var catchClauseStack: [Int] = []
    private(set) var calls: [CallSite] = []
    private(set) var catchClauses: [CatchClauseSite] = []

    init(converter: SourceLocationConverter, viewMode: SyntaxTreeViewMode) {
        self.converter = converter
        super.init(viewMode: viewMode)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let location = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        if let declRef = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            calls.append(
                CallSite(
                    receiver: .none,
                    method: declRef.baseName.text,
                    line: location.line,
                    column: location.column
                )
            )
        } else if let memberAccess = node.calledExpression.as(MemberAccessExprSyntax.self) {
            calls.append(
                CallSite(
                    receiver: parseReceiver(memberAccess.base),
                    method: memberAccess.declName.baseName.text,
                    line: location.line,
                    column: location.column
                )
            )
        }
        return .visitChildren
    }

    override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind {
        let location = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        catchClauses.append(
            CatchClauseSite(
                line: location.line,
                column: location.column,
                handledCases: []
            )
        )
        catchClauseStack.append(catchClauses.count - 1)
        return .visitChildren
    }

    override func visitPost(_ node: CatchClauseSyntax) {
        _ = catchClauseStack.popLast()
    }

    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        collectCaseChecksIfNeeded(from: node.conditions)
        return .visitChildren
    }

    override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
        collectCaseChecksIfNeeded(from: node.conditions)
        return .visitChildren
    }

    private func collectCaseChecksIfNeeded(from conditions: ConditionElementListSyntax) {
        guard let currentCatchIndex = catchClauseStack.last else { return }
        for condition in conditions {
            guard let matching = condition.condition.as(MatchingPatternConditionSyntax.self),
                  let caseName = extractCaseName(from: matching.pattern)
            else {
                continue
            }
            catchClauses[currentCatchIndex].handledCases.insert(caseName)
        }
    }

    private func extractCaseName(from pattern: PatternSyntax) -> String? {
        if let valueBinding = pattern.as(ValueBindingPatternSyntax.self) {
            return extractCaseName(from: valueBinding.pattern)
        }
        if let expressionPattern = pattern.as(ExpressionPatternSyntax.self) {
            if let member = expressionPattern.expression.as(MemberAccessExprSyntax.self),
               member.base == nil {
                return member.declName.baseName.text
            }
            if let declRef = expressionPattern.expression.as(DeclReferenceExprSyntax.self) {
                return declRef.baseName.text
            }
        }
        if let tuplePattern = pattern.as(TuplePatternSyntax.self) {
            for element in tuplePattern.elements {
                if let name = extractCaseName(from: element.pattern) {
                    return name
                }
            }
        }
        return nil
    }

    private func parseReceiver(_ expression: ExprSyntax?) -> CallReceiver {
        guard let expression else { return .none }
        if let declRef = expression.as(DeclReferenceExprSyntax.self) {
            return .simpleName(declRef.baseName.text)
        }
        return .complex
    }
}

private enum RuleBodyParser {
    static func parse(body: String) throws -> ParsedRuleBody {
        let wrappedSource = """
        func __rin_rule_body__() {
        \(body)
        }
        """
        let file = Parser.parse(source: wrappedSource)
        guard !file.hasError else {
            throw RuleBodyParserError.invalidSyntax("rule body contains invalid Swift syntax")
        }
        guard let functionDecl = file.statements.first?.item.as(FunctionDeclSyntax.self),
              let statements = functionDecl.body?.statements
        else {
            throw RuleBodyParserError.invalidSyntax("failed to read wrapped function body")
        }

        var parsed = ParsedRuleBody()
        for statement in statements {
            guard let expression = statement.item.as(ExprSyntax.self),
                  let callExpr = expression.as(FunctionCallExprSyntax.self)
            else {
                continue
            }
            let called = calledName(of: callExpr.calledExpression)
            if called == "MustCall" {
                guard let firstArg = callExpr.arguments.first?.expression else {
                    throw RuleBodyParserError.invalidClause("MustCall requires a target")
                }
                parsed.mustCallTargets.append(try parseRuleCallPattern(firstArg))
                continue
            }
            if called == "MustCallAnyOf" {
                guard let firstArg = callExpr.arguments.first?.expression,
                      let arrayExpr = firstArg.as(ArrayExprSyntax.self)
                else {
                    throw RuleBodyParserError.invalidClause("MustCallAnyOf requires array literal")
                }
                let patterns = try arrayExpr.elements.map { try parseRuleCallPattern($0.expression) }
                parsed.mustCallAnyOfGroups.append(patterns)
                continue
            }
            if called == "MustHandleError" {
                guard let checkArg = callExpr.arguments.first(where: { $0.label?.text == "check" }),
                      let caseCall = checkArg.expression.as(FunctionCallExprSyntax.self),
                      calledName(of: caseCall.calledExpression) == "case",
                      let firstArg = caseCall.arguments.first?.expression,
                      let value = stringLiteralValue(firstArg)
                else {
                    throw RuleBodyParserError.invalidClause("MustHandleError(check: .case(\"...\")) is required")
                }
                parsed.mustHandleErrorChecks.append(.case(value))
                continue
            }
            if called == "mustAlsoCall" {
                guard let baseCall = callExpr.calledExpression.as(MemberAccessExprSyntax.self)?.base?.as(FunctionCallExprSyntax.self),
                      calledName(of: baseCall.calledExpression) == "WhenCalls",
                      let triggerExpr = baseCall.arguments.first?.expression
                else {
                    throw RuleBodyParserError.invalidClause("WhenCalls(...).mustAlsoCall(...) requires a trigger")
                }
                guard let reqExpr = callExpr.arguments.first?.expression,
                      let reqArray = reqExpr.as(ArrayExprSyntax.self)
                else {
                    throw RuleBodyParserError.invalidClause("mustAlsoCall requires requirements array")
                }
                let trigger = try parseRuleCallPattern(triggerExpr)
                let requirements = try reqArray.elements.map { try parseRuleCallPattern($0.expression) }
                parsed.whenCallsConditions.append((trigger: trigger, requirements: requirements))
            }
        }
        return parsed
    }

    private static func parseRuleCallPattern(_ expression: ExprSyntax) throws -> RuleCallPattern {
        if let arrayExpr = expression.as(ArrayExprSyntax.self) {
            guard arrayExpr.elements.count == 2 else {
                throw RuleBodyParserError.invalidClause("call pattern array requires two elements")
            }
            let typeName = try parsePatternName(arrayExpr.elements[arrayExpr.elements.startIndex].expression)
            let methodName = try parsePatternName(arrayExpr.elements[arrayExpr.elements.index(after: arrayExpr.elements.startIndex)].expression)
            return RuleCallPattern(typeName: typeName, methodName: methodName)
        }
        if let callExpr = expression.as(FunctionCallExprSyntax.self),
           calledName(of: callExpr.calledExpression) == "RuleCallTarget" {
            guard let typeArg = callExpr.arguments.first?.expression,
                  let methodArg = callExpr.arguments.dropFirst().first?.expression
            else {
                throw RuleBodyParserError.invalidClause("RuleCallTarget requires type and method")
            }
            guard let typeName = stringLiteralValue(typeArg),
                  let methodName = stringLiteralValue(methodArg)
            else {
                throw RuleBodyParserError.invalidClause("RuleCallTarget arguments must be string literals")
            }
            return RuleCallPattern(typeName: typeName, methodName: methodName)
        }
        throw RuleBodyParserError.invalidClause("unsupported call target expression: \(expression.trimmedDescription)")
    }

    private static func parsePatternName(_ expression: ExprSyntax) throws -> String {
        if let declRef = expression.as(DeclReferenceExprSyntax.self) {
            return declRef.baseName.text
        }
        if let string = stringLiteralValue(expression) {
            return string
        }
        throw RuleBodyParserError.invalidClause("pattern element must be identifier or string literal")
    }

    private static func calledName(of expression: ExprSyntax) -> String? {
        if let declRef = expression.as(DeclReferenceExprSyntax.self) {
            return declRef.baseName.text
        }
        if let member = expression.as(MemberAccessExprSyntax.self) {
            return member.declName.baseName.text
        }
        return nil
    }

    private static func stringLiteralValue(_ expression: ExprSyntax) -> String? {
        guard let literal = expression.as(StringLiteralExprSyntax.self) else {
            return nil
        }
        var value = ""
        for segment in literal.segments {
            guard let text = segment.as(StringSegmentSyntax.self) else {
                return nil
            }
            value += text.content.text
        }
        return value
    }
}

private enum RuleBodyParserError: LocalizedError {
    case invalidSyntax(String)
    case invalidClause(String)

    var errorDescription: String? {
        switch self {
        case .invalidSyntax(let reason), .invalidClause(let reason):
            return reason
        }
    }
}

private struct ParsedRuleBody {
    var mustCallTargets: [RuleCallPattern] = []
    var mustCallAnyOfGroups: [[RuleCallPattern]] = []
    var whenCallsConditions: [(trigger: RuleCallPattern, requirements: [RuleCallPattern])] = []
    var mustHandleErrorChecks: [ErrorHandlingCheck] = []
}

private struct CallSite {
    let receiver: CallReceiver
    let method: String
    let line: Int
    let column: Int
}

private enum CallReceiver {
    case none
    case simpleName(String)
    case complex
}

private struct CatchClauseSite {
    let line: Int
    let column: Int
    var handledCases: Set<String>
}

private enum ErrorHandlingCheck {
    case `case`(String)
}

private struct RuleCallPattern {
    let typeName: String
    let methodName: String

    var rendered: String {
        "[\(typeName), \(methodName)]"
    }
}


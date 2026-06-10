import Foundation
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

protocol RinRuleEvaluating {
    func evaluate(file: DiffedSwiftFile, policy: RinPolicy) throws -> [RinSemanticViolation]
}

enum SwiftSyntaxRuleEvaluatorError: Error, LocalizedError {
    case invalidSwiftFile(path: String, diagnostics: [String])

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
        let catchCases = collector.catchCases

        var violations: [RinSemanticViolation] = []
        for rule in policy.rules {
            violations.append(contentsOf: evaluateRule(rule, calls: calls, catchCases: catchCases, filePath: file.path))
        }
        return violations
    }

    private func evaluateRule(
        _ rule: RinRule,
        calls: [CallSite],
        catchCases: [CatchCaseSite],
        filePath: String
    ) -> [RinSemanticViolation] {
        var violations: [RinSemanticViolation] = []
        let fallbackLocation = calls.first.map { ($0.line, $0.column) }
            ?? catchCases.first.map { ($0.line, $0.column) }
            ?? (1, 1)

        for requiredCall in RuleBodyParser.mustCallTargets(in: rule.body) {
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

        for anyGroup in RuleBodyParser.mustCallAnyOfGroups(in: rule.body) {
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

        for conditional in RuleBodyParser.whenCallsConditions(in: rule.body) {
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

        for errorCheck in RuleBodyParser.mustHandleErrorChecks(in: rule.body) {
            switch errorCheck {
            case .case(let requiredCase):
                if !catchCases.contains(where: { $0.caseName == requiredCase }) {
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
            return call.receiver == target.typeName
        }
    }
}

private final class FunctionCallCollector: SyntaxVisitor {
    private let converter: SourceLocationConverter
    private var catchDepth: Int = 0
    private let caseConditionRegex = try! NSRegularExpression(
        pattern: #"^\s*case\s+\.([A-Za-z_][A-Za-z0-9_]*)\s*="#
    )
    private(set) var calls: [CallSite] = []
    private(set) var catchCases: [CatchCaseSite] = []

    init(converter: SourceLocationConverter, viewMode: SyntaxTreeViewMode) {
        self.converter = converter
        super.init(viewMode: viewMode)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let location = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        if let declRef = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            calls.append(
                CallSite(
                    receiver: nil,
                    method: declRef.baseName.text,
                    line: location.line,
                    column: location.column
                )
            )
        } else if let memberAccess = node.calledExpression.as(MemberAccessExprSyntax.self) {
            calls.append(
                CallSite(
                    receiver: memberAccess.base?.trimmedDescription,
                    method: memberAccess.declName.baseName.text,
                    line: location.line,
                    column: location.column
                )
            )
        }
        return .visitChildren
    }

    override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind {
        catchDepth += 1
        return .visitChildren
    }

    override func visitPost(_ node: CatchClauseSyntax) {
        catchDepth -= 1
    }

    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        collectCaseChecksIfNeeded(from: node.conditions, at: node.positionAfterSkippingLeadingTrivia)
        return .visitChildren
    }

    override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
        collectCaseChecksIfNeeded(from: node.conditions, at: node.positionAfterSkippingLeadingTrivia)
        return .visitChildren
    }

    private func collectCaseChecksIfNeeded(from conditions: ConditionElementListSyntax, at position: AbsolutePosition) {
        guard catchDepth > 0 else { return }
        for condition in conditions {
            let text = condition.condition.trimmedDescription
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = caseConditionRegex.firstMatch(in: text, range: range),
                  match.numberOfRanges == 2,
                  let caseRange = Range(match.range(at: 1), in: text)
            else {
                continue
            }
            let location = converter.location(for: position)
            catchCases.append(
                CatchCaseSite(
                    caseName: String(text[caseRange]),
                    line: location.line,
                    column: location.column
                )
            )
        }
    }
}

private enum RuleBodyParser {
    static func mustCallTargets(in body: String) -> [RuleCallPattern] {
        extractCallPatterns(withPattern: #"MustCall\((.*?)\)"#, from: body)
    }

    static func mustCallAnyOfGroups(in body: String) -> [[RuleCallPattern]] {
        extractGroups(withPattern: #"MustCallAnyOf\(\[(.*?)\]\)"#, from: body)
    }

    static func whenCallsConditions(in body: String) -> [(trigger: RuleCallPattern, requirements: [RuleCallPattern])] {
        guard let regex = try? NSRegularExpression(
            pattern: #"WhenCalls\((.*?)\)\.mustAlsoCall\(\[(.*?)\]\)"#,
            options: [.dotMatchesLineSeparators]
        ) else {
            return []
        }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        return regex.matches(in: body, range: range).compactMap { match in
            guard match.numberOfRanges == 3,
                  let triggerRange = Range(match.range(at: 1), in: body),
                  let requirementsRange = Range(match.range(at: 2), in: body)
            else {
                return nil
            }
            let triggers = extractPairs(from: String(body[triggerRange]))
            guard let trigger = triggers.first else { return nil }
            let requirements = extractPairs(from: String(body[requirementsRange]))
            return (trigger: trigger, requirements: requirements)
        }
    }

    static func mustHandleErrorChecks(in body: String) -> [ErrorHandlingCheck] {
        guard let regex = try? NSRegularExpression(
            pattern: #"MustHandleError\(\s*check:\s*\.case\("([A-Za-z_][A-Za-z0-9_]*)"\)\s*\)"#
        ) else {
            return []
        }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        return regex.matches(in: body, range: range).compactMap { match in
            guard match.numberOfRanges == 2,
                  let caseRange = Range(match.range(at: 1), in: body)
            else {
                return nil
            }
            return .case(String(body[caseRange]))
        }
    }

    private static func extractCallPatterns(withPattern pattern: String, from text: String) -> [RuleCallPattern] {
        extractGroups(withPattern: pattern, from: text).flatMap { $0 }
    }

    private static func extractGroups(withPattern pattern: String, from text: String) -> [[RuleCallPattern]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let bodyRange = Range(match.range(at: 1), in: text)
            else {
                return nil
            }
            return extractPairs(from: String(text[bodyRange]))
        }
    }

    private static func extractPairs(from text: String) -> [RuleCallPattern] {
        guard let regex = try? NSRegularExpression(
            pattern: #"\[\s*([A-Za-z_][A-Za-z0-9_]*|\*)\s*,\s*([A-Za-z_][A-Za-z0-9_]*|\*)\s*\]"#
        ) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges == 3,
                  let typeRange = Range(match.range(at: 1), in: text),
                  let methodRange = Range(match.range(at: 2), in: text)
            else {
                return nil
            }
            return RuleCallPattern(
                typeName: String(text[typeRange]),
                methodName: String(text[methodRange])
            )
        }
    }
}

private struct CallSite {
    let receiver: String?
    let method: String
    let line: Int
    let column: Int
}

private struct CatchCaseSite {
    let caseName: String
    let line: Int
    let column: Int
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


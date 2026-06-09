import Foundation
import SwiftParser
import SwiftSyntax

protocol RinRuleEvaluating {
    func evaluate(file: DiffedSwiftFile, policy: RinPolicy) throws -> [RinSemanticViolation]
}

enum SwiftSyntaxRuleEvaluatorError: Error, LocalizedError {
    case invalidSwiftFile(String)

    var errorDescription: String? {
        switch self {
        case .invalidSwiftFile(let path):
            return "Failed to parse Swift file: \(path)"
        }
    }
}

struct SwiftSyntaxRuleEvaluator: RinRuleEvaluating {
    func evaluate(file: DiffedSwiftFile, policy: RinPolicy) throws -> [RinSemanticViolation] {
        let syntax = Parser.parse(source: file.source)
        guard !syntax.hasError else {
            throw SwiftSyntaxRuleEvaluatorError.invalidSwiftFile(file.path)
        }

        let converter = SourceLocationConverter(fileName: file.path, tree: syntax)
        let collector = FunctionCallCollector(converter: converter, viewMode: .sourceAccurate)
        collector.walk(syntax)
        let calls = collector.calls

        var violations: [RinSemanticViolation] = []
        for rule in policy.rules {
            violations.append(contentsOf: evaluateRule(rule, calls: calls, filePath: file.path))
        }
        return violations
    }

    private func evaluateRule(
        _ rule: RinRule,
        calls: [CallSite],
        filePath: String
    ) -> [RinSemanticViolation] {
        var violations: [RinSemanticViolation] = []
        let fallbackLocation = calls.first.map { ($0.line, $0.column) } ?? (1, 1)

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
    private(set) var calls: [CallSite] = []

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

private struct RuleCallPattern {
    let typeName: String
    let methodName: String

    var rendered: String {
        "[\(typeName), \(methodName)]"
    }
}


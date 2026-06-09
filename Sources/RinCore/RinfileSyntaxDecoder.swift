import Foundation
import SwiftParser
import SwiftSyntax

enum RinfileSyntaxDecoderError: Error, LocalizedError {
    case unsupportedSyntax(String)
    case missingPolicyRoot
    case duplicateTarget
    case duplicateRulesBlock
    case invalidRule(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSyntax(let message):
            return "Unsupported Rinfile syntax: \(message)"
        case .missingPolicyRoot:
            return "Rinfile.swift must define `let <name> = Rin.Policy { ... }`."
        case .duplicateTarget:
            return "Rinfile.swift can define Target only once."
        case .duplicateRulesBlock:
            return "Rinfile.swift can define Rules only once."
        case .invalidRule(let reason):
            return "Invalid rule definition: \(reason)"
        }
    }
}

struct RinfileSyntaxDecoder {
    init() {}

    func decode(source: String) throws -> RinPolicy {
        let file = Parser.parse(source: source)
        guard let policyCall = try findPolicyCall(in: file) else {
            throw RinfileSyntaxDecoderError.missingPolicyRoot
        }
        return try decodePolicy(from: policyCall)
    }
    
    private func findPolicyCall(in file: SourceFileSyntax) throws -> FunctionCallExprSyntax? {
        for statement in file.statements {
            guard let variableDecl = statement.item.as(VariableDeclSyntax.self),
                  let binding = variableDecl.bindings.first
            else {
                continue
            }

            guard let initializer = binding.initializer,
                  let call = initializer.value.as(FunctionCallExprSyntax.self),
                  let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                  member.declName.baseName.text == "Policy",
                  member.base?.trimmedDescription == "Rin"
            else {
                continue
            }
            return call
        }
        return nil
    }
    
    private func decodePolicy(from call: FunctionCallExprSyntax) throws -> RinPolicy {
        guard let closure = call.trailingClosure else {
            throw RinfileSyntaxDecoderError.unsupportedSyntax("Rin.Policy requires trailing closure.")
        }

        var include: [String] = []
        var exclude: [String] = []
        var rules: [RinRule] = []
        var seenTarget = false
        var seenRules = false

        for statement in closure.statements {
            guard let expression = statement.item.as(FunctionCallExprSyntax.self) else {
                throw RinfileSyntaxDecoderError.unsupportedSyntax(
                    "Policy body supports only Target(...) and Rules { ... }."
                )
            }
            guard let declRef = expression.calledExpression.as(DeclReferenceExprSyntax.self) else {
                throw RinfileSyntaxDecoderError.unsupportedSyntax("Unsupported policy element.")
            }
            switch declRef.baseName.text {
            case "Target":
                if seenTarget { throw RinfileSyntaxDecoderError.duplicateTarget }
                seenTarget = true
                include = try parseStringArray(for: "include", in: expression.arguments)
                exclude = try parseStringArray(for: "exclude", in: expression.arguments)
            case "Rules":
                if seenRules { throw RinfileSyntaxDecoderError.duplicateRulesBlock }
                seenRules = true
                rules = try decodeRules(expression)
            default:
                throw RinfileSyntaxDecoderError.unsupportedSyntax(
                    "Unknown policy element `\(declRef.baseName.text)`."
                )
            }
        }
        return RinPolicy(include: include, exclude: exclude, rules: rules)
    }
    
    private func decodeRules(_ call: FunctionCallExprSyntax) throws -> [RinRule] {
        guard let closure = call.trailingClosure else {
            throw RinfileSyntaxDecoderError.unsupportedSyntax("Rules requires trailing closure.")
        }

        return try closure.statements.map { statement in
            guard let functionCall = statement.item.as(FunctionCallExprSyntax.self) else {
                throw RinfileSyntaxDecoderError.unsupportedSyntax(
                    "Rules block supports only Rule(...) declarations."
                )
            }
            return try decodeRule(functionCall)
        }
    }
    
    private func decodeRule(_ expression: FunctionCallExprSyntax) throws -> RinRule {
        var message: String?
        var severity: Severity?
        var scopeInclude: [String] = []
        var scopeExclude: [String] = []
        var rootCall = expression

        while let member = rootCall.calledExpression.as(MemberAccessExprSyntax.self),
              let baseCall = member.base?.as(FunctionCallExprSyntax.self) {
            let method = member.declName.baseName.text
            switch method {
            case "message":
                message = try parseStringLiteral(
                    from: rootCall.arguments.first?.expression,
                    errorMessage: "message(...) requires string literal."
                )
            case "severity":
                severity = try parseSeverity(rootCall.arguments.first?.expression)
            case "scope":
                scopeInclude = try parseStringArray(for: "include", in: rootCall.arguments)
                scopeExclude = try parseStringArray(for: "exclude", in: rootCall.arguments)
            default:
                throw RinfileSyntaxDecoderError.unsupportedSyntax(
                    "Rule supports only message(...), severity(...), and scope(...)."
                )
            }
            rootCall = baseCall
        }

        guard let declRef = rootCall.calledExpression.as(DeclReferenceExprSyntax.self),
              declRef.baseName.text == "Rule"
        else {
            throw RinfileSyntaxDecoderError.unsupportedSyntax("Rules block supports only Rule(...) declarations.")
        }

        guard let idExpression = rootCall.arguments.first(where: { $0.label?.text == "id" })?.expression else {
            throw RinfileSyntaxDecoderError.invalidRule("Rule(id:) is required.")
        }
        let id = try parseStringLiteral(from: idExpression, errorMessage: "Rule id must be string literal.")
        guard let bodyStatements = rootCall.trailingClosure?.statements, !bodyStatements.isEmpty else {
            throw RinfileSyntaxDecoderError.invalidRule("Rule body is required.")
        }

        var bodyParts: [String] = []
        for statement in bodyStatements {
            guard let expr = statement.item.as(ExprSyntax.self) else { continue }
            if let stringValue = try parseOptionalStringLiteral(from: expr) {
                bodyParts.append(stringValue)
            } else {
                bodyParts.append(expr.trimmedDescription)
            }
        }
        let body = bodyParts.joined(separator: "\n")

        return RinRule(
            id: id,
            body: body,
            message: message,
            severity: severity,
            scopeInclude: scopeInclude,
            scopeExclude: scopeExclude
        )
    }
    
    private func parseStringArray(
        for label: String,
        in arguments: LabeledExprListSyntax
    ) throws -> [String] {
        guard let expression = arguments.first(where: { $0.label?.text == label })?.expression else {
            return []
        }
        guard let array = expression.as(ArrayExprSyntax.self) else {
            throw RinfileSyntaxDecoderError.unsupportedSyntax("\(label) must be string array literal.")
        }
        return try array.elements.map { element in
            try parseStringLiteral(from: element.expression, errorMessage: "\(label) values must be strings.")
        }
    }
    
    private func parseStringLiteral(from expression: ExprSyntax?, errorMessage: String) throws -> String {
        guard let expression,
              let parsed = try parseOptionalStringLiteral(from: expression)
        else {
            throw RinfileSyntaxDecoderError.unsupportedSyntax(errorMessage)
        }
        return parsed
    }
    
    private func parseOptionalStringLiteral(from expression: ExprSyntax) throws -> String? {
        guard let literal = expression.as(StringLiteralExprSyntax.self) else {
            return nil
        }
        var collected = ""
        for segment in literal.segments {
            if let text = segment.as(StringSegmentSyntax.self) {
                collected += text.content.text
                continue
            }
            throw RinfileSyntaxDecoderError.unsupportedSyntax("String interpolation is not allowed in Rinfile.")
        }
        return collected
    }
    
    private func parseSeverity(_ expression: ExprSyntax?) throws -> Severity {
        guard let member = expression?.as(MemberAccessExprSyntax.self),
              let severity = Severity(rawValue: member.declName.baseName.text)
        else {
            throw RinfileSyntaxDecoderError.unsupportedSyntax(
                "severity(...) must be one of .warning or .error."
            )
        }
        return severity
    }
}

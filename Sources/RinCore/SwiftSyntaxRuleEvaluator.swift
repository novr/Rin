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
        let creations = collector.creations
        let localDeclarations = collector.localDeclarations
        let allFunctionIDs = collector.allFunctionIDs
        let functionLocations = collector.functionLocations

        var violations: [RinSemanticViolation] = []
        for rule in policy.rules {
            violations.append(
                contentsOf: try evaluateRule(
                    rule,
                    calls: calls,
                    catchClauses: catchClauses,
                    creations: creations,
                    localDeclarations: localDeclarations,
                    allFunctionIDs: allFunctionIDs,
                    functionLocations: functionLocations,
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
        creations: [TypeCreationSite],
        localDeclarations: [LocalDeclarationSite],
        allFunctionIDs: [Int],
        functionLocations: [Int: (line: Int, column: Int)],
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
            switch errorCheck.handling {
            case .through:
                if !catchClauses.contains(where: { $0.ignoredCases.contains(errorCheck.targetCase) }) {
                    violations.append(
                        RinSemanticViolation(
                            ruleId: rule.id,
                            reason: "Required through catch handling `case .\(errorCheck.targetCase)` was not found.",
                            file: filePath,
                            line: fallbackLocation.0,
                            column: fallbackLocation.1
                        )
                    )
                }
            case .assign(let target):
                if !catchClauses.contains(where: {
                    $0.handledCases.contains(errorCheck.targetCase) &&
                        ($0.caseHandling[errorCheck.targetCase]?.assignedTargets.contains(target) ?? false)
                }) {
                    violations.append(
                        RinSemanticViolation(
                            ruleId: rule.id,
                            reason: "Required assignment handling for `case .\(errorCheck.targetCase)` to `\(target)` was not found.",
                            file: filePath,
                            line: fallbackLocation.0,
                            column: fallbackLocation.1
                        )
                    )
                }
            case .transform(let functionName):
                if !catchClauses.contains(where: {
                    $0.handledCases.contains(errorCheck.targetCase) &&
                        ($0.caseHandling[errorCheck.targetCase]?.calledFunctions.contains(functionName) ?? false)
                }) {
                    violations.append(
                        RinSemanticViolation(
                            ruleId: rule.id,
                            reason: "Required transform handling for `case .\(errorCheck.targetCase)` using `\(functionName)` was not found.",
                            file: filePath,
                            line: fallbackLocation.0,
                            column: fallbackLocation.1
                        )
                    )
                }
            case .rethrow:
                if !catchClauses.contains(where: {
                    $0.handledCases.contains(errorCheck.targetCase) &&
                        ($0.caseHandling[errorCheck.targetCase]?.hasThrow ?? false)
                }) {
                    violations.append(
                        RinSemanticViolation(
                            ruleId: rule.id,
                            reason: "Required rethrow handling for `case .\(errorCheck.targetCase)` was not found.",
                            file: filePath,
                            line: fallbackLocation.0,
                            column: fallbackLocation.1
                        )
                    )
                }
            }
        }

        if parsedRuleBody.whenCallsNameChecks.isEmpty {
            for declareCheck in parsedRuleBody.mustDeclareLocalChecks {
                for functionID in allFunctionIDs {
                    if matchesLocalDeclaration(declareCheck, declarations: localDeclarations, functionID: functionID) {
                        continue
                    }
                    let location = functionLocations[functionID] ?? fallbackLocation
                    violations.append(
                        RinSemanticViolation(
                            ruleId: rule.id,
                            reason: "Required local declaration `\(declareCheck.identifier)` was not found in the same function.",
                            file: filePath,
                            line: location.0,
                            column: location.1
                        )
                    )
                }
            }
        } else {
            for nameCheck in parsedRuleBody.whenCallsNameChecks {
                let matchedCreations = creations.filter { typeNameMatches($0.typeName, pattern: nameCheck.namePattern) }
                guard !matchedCreations.isEmpty else { continue }

                for creation in matchedCreations {
                    guard let argument = creation.arguments.first(where: { $0.label == nameCheck.argumentLabel }) else {
                        violations.append(
                            RinSemanticViolation(
                                ruleId: rule.id,
                                reason: "When `\(nameCheck.namePattern.rendered)` is called, argument label `\(nameCheck.argumentLabel)` is required.",
                                file: filePath,
                                line: creation.line,
                                column: creation.column
                            )
                        )
                        continue
                    }

                    guard case .identifier(let identifier) = argument.value else {
                        violations.append(
                            RinSemanticViolation(
                                ruleId: rule.id,
                                reason: "Argument `\(nameCheck.argumentLabel)` must use identifier `\(nameCheck.mustUseIdentifier)` as a standalone identifier.",
                                file: filePath,
                                line: creation.line,
                                column: creation.column
                            )
                        )
                        continue
                    }

                    if identifier != nameCheck.mustUseIdentifier {
                        violations.append(
                            RinSemanticViolation(
                                ruleId: rule.id,
                                reason: "Argument `\(nameCheck.argumentLabel)` must use identifier `\(nameCheck.mustUseIdentifier)`.",
                                file: filePath,
                                line: creation.line,
                                column: creation.column
                            )
                        )
                    }
                    if identifier == nameCheck.mustNotUseIdentifier {
                        violations.append(
                            RinSemanticViolation(
                                ruleId: rule.id,
                                reason: "Argument `\(nameCheck.argumentLabel)` must not use identifier `\(nameCheck.mustNotUseIdentifier)`.",
                                file: filePath,
                                line: creation.line,
                                column: creation.column
                            )
                        )
                    }

                    for declareCheck in parsedRuleBody.mustDeclareLocalChecks {
                        if !matchesLocalDeclaration(declareCheck, declarations: localDeclarations, functionID: creation.functionID) {
                            violations.append(
                                RinSemanticViolation(
                                    ruleId: rule.id,
                                    reason: "When `\(nameCheck.namePattern.rendered)` is called, local declaration `\(declareCheck.identifier)` is required in the same function.",
                                    file: filePath,
                                    line: creation.line,
                                    column: creation.column
                                )
                            )
                        }
                    }
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
            switch target.receiver {
            case .any:
                return true
            case .none:
                if case .none = call.receiver { return true }
                return false
            case .symbol(let name):
                guard case .simpleName(let receiverName) = call.receiver else { return false }
                return receiverName == name
            }
        }
    }

    private func typeNameMatches(_ typeName: String, pattern: TypeNamePatternRule) -> Bool {
        switch pattern {
        case .exact(let value):
            return typeName == value
        case .prefix(let value):
            return typeName.hasPrefix(value)
        case .suffix(let value):
            return typeName.hasSuffix(value)
        }
    }

    private func matchesLocalDeclaration(
        _ check: LocalBindingRule,
        declarations: [LocalDeclarationSite],
        functionID: Int?
    ) -> Bool {
        declarations.contains { declaration in
            if let functionID, declaration.functionID != functionID {
                return false
            }
            guard declaration.identifier == check.identifier else { return false }
            guard declaration.isLet else { return false }
            guard declaration.initializerIdentifier == check.initializerIdentifier else { return false }
            return localTypeMatches(declaration.typeAnnotation, pattern: check.typePattern)
        }
    }

    private func localTypeMatches(_ typeAnnotation: TypeSyntax?, pattern: LocalTypePatternRule) -> Bool {
        guard let typeAnnotation else { return false }
        switch pattern {
        case .anyConformance(let protocolName):
            guard let someOrAny = typeAnnotation.as(SomeOrAnyTypeSyntax.self),
                  someOrAny.someOrAnySpecifier.text == "any"
            else {
                return false
            }
            return syntaxContainsIdentifierType(Syntax(someOrAny.constraint), name: protocolName)
        }
    }

    private func syntaxContainsIdentifierType(_ syntax: Syntax, name: String) -> Bool {
        if let identifierType = syntax.as(IdentifierTypeSyntax.self),
           identifierType.name.text == name {
            return true
        }
        for child in syntax.children(viewMode: .sourceAccurate) {
            if syntaxContainsIdentifierType(child, name: name) {
                return true
            }
        }
        return false
    }
}

private final class FunctionCallCollector: SyntaxVisitor {
    private let converter: SourceLocationConverter
    private var catchClauseStack: [Int] = []
    private var functionStack: [Int] = []
    private var nextFunctionID = 0
    private(set) var allFunctionIDs: [Int] = []
    private(set) var functionLocations: [Int: (line: Int, column: Int)] = [:]
    private(set) var calls: [CallSite] = []
    private(set) var catchClauses: [CatchClauseSite] = []
    private(set) var creations: [TypeCreationSite] = []
    private(set) var localDeclarations: [LocalDeclarationSite] = []

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
            if let functionID = functionStack.last,
               looksLikeTypeInitializer(name: declRef.baseName.text) {
                creations.append(
                    TypeCreationSite(
                        typeName: declRef.baseName.text,
                        arguments: parseArguments(node.arguments),
                        functionID: functionID,
                        line: location.line,
                        column: location.column
                    )
                )
            }
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

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let functionID = nextFunctionID
        nextFunctionID += 1
        allFunctionIDs.append(functionID)
        let location = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        functionLocations[functionID] = (location.line, location.column)
        functionStack.append(functionID)
        return .visitChildren
    }

    override func visitPost(_ node: FunctionDeclSyntax) {
        _ = functionStack.popLast()
    }

    override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind {
        let location = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        catchClauses.append(
            CatchClauseSite(
                line: location.line,
                column: location.column,
                handledCases: [],
                ignoredCases: [],
                caseHandling: [:]
            )
        )
        catchClauseStack.append(catchClauses.count - 1)
        return .visitChildren
    }

    override func visitPost(_ node: CatchClauseSyntax) {
        _ = catchClauseStack.popLast()
    }

    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        collectCaseChecksIfNeeded(from: node.conditions, caseBody: node.body)
        return .visitChildren
    }

    override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
        collectCaseChecksIfNeeded(from: node.conditions, caseBody: nil)
        return .visitChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let functionID = functionStack.last else {
            return .visitChildren
        }
        let isLet = node.bindingSpecifier.tokenKind == .keyword(.let)
        let location = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        for binding in node.bindings {
            guard let identifierPattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
            let initializerIdentifier: String?
            if let initializerExpression = binding.initializer?.value.as(DeclReferenceExprSyntax.self) {
                initializerIdentifier = initializerExpression.baseName.text
            } else {
                initializerIdentifier = nil
            }
            localDeclarations.append(
                LocalDeclarationSite(
                    identifier: identifierPattern.identifier.text,
                    typeAnnotation: binding.typeAnnotation?.type,
                    initializerIdentifier: initializerIdentifier,
                    isLet: isLet,
                    functionID: functionID,
                    line: location.line,
                    column: location.column
                )
            )
        }
        return .visitChildren
    }

    private func collectCaseChecksIfNeeded(from conditions: ConditionElementListSyntax, caseBody: CodeBlockSyntax?) {
        guard let currentCatchIndex = catchClauseStack.last else { return }
        for condition in conditions {
            guard let matching = condition.condition.as(MatchingPatternConditionSyntax.self),
                  let caseName = extractCaseName(from: matching.pattern)
            else {
                continue
            }
            catchClauses[currentCatchIndex].handledCases.insert(caseName)
            if let caseBody, bodyContainsThrough(caseBody) {
                catchClauses[currentCatchIndex].ignoredCases.insert(caseName)
                updateCaseHandling(caseName: caseName, body: caseBody, catchIndex: currentCatchIndex)
            } else if let caseBody {
                updateCaseHandling(caseName: caseName, body: caseBody, catchIndex: currentCatchIndex)
            }
        }
    }

    private func bodyContainsThrough(_ body: CodeBlockSyntax) -> Bool {
        for statement in body.statements {
            if statement.item.as(ReturnStmtSyntax.self) != nil ||
                statement.item.as(ContinueStmtSyntax.self) != nil ||
                statement.item.as(BreakStmtSyntax.self) != nil {
                return true
            }
            if let nestedIf = statement.item.as(IfExprSyntax.self), bodyContainsThrough(nestedIf.body) {
                return true
            }
            if let nestedGuard = statement.item.as(GuardStmtSyntax.self), bodyContainsThrough(nestedGuard.body) {
                return true
            }
        }
        return false
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

    private func parseArguments(_ arguments: LabeledExprListSyntax) -> [LabeledArgumentSite] {
        arguments.map { argument in
            let label = argument.label?.text ?? "_"
            if let identifier = argument.expression.as(DeclReferenceExprSyntax.self) {
                return LabeledArgumentSite(label: label, value: .identifier(identifier.baseName.text))
            }
            return LabeledArgumentSite(label: label, value: .other(argument.expression.trimmedDescription))
        }
    }

    private func looksLikeTypeInitializer(name: String) -> Bool {
        guard let first = name.first else { return false }
        return first.isUppercase
    }

    private func updateCaseHandling(caseName: String, body: CodeBlockSyntax, catchIndex: Int) {
        var handling = catchClauses[catchIndex].caseHandling[caseName] ?? CaseHandlingSnapshot()
        for statement in body.statements {
            if let expression = statement.item.as(ExprSyntax.self),
               let sequence = expression.as(SequenceExprSyntax.self) {
                let parts = Array(sequence.elements)
                if parts.count >= 3,
                   parts[1].as(AssignmentExprSyntax.self) != nil,
                   let target = extractAssignmentTarget(parts[0]) {
                    handling.assignedTargets.insert(target)
                }
                for part in parts {
                    if let callExpr = part.as(FunctionCallExprSyntax.self) {
                        if let declRef = callExpr.calledExpression.as(DeclReferenceExprSyntax.self) {
                            handling.calledFunctions.insert(declRef.baseName.text)
                        } else if let member = callExpr.calledExpression.as(MemberAccessExprSyntax.self) {
                            handling.calledFunctions.insert(member.declName.baseName.text)
                        }
                    }
                }
            }
            if let expression = statement.item.as(ExprSyntax.self),
               let callExpr = expression.as(FunctionCallExprSyntax.self) {
                if let declRef = callExpr.calledExpression.as(DeclReferenceExprSyntax.self) {
                    handling.calledFunctions.insert(declRef.baseName.text)
                } else if let member = callExpr.calledExpression.as(MemberAccessExprSyntax.self) {
                    handling.calledFunctions.insert(member.declName.baseName.text)
                }
            }
            if statement.item.as(ThrowStmtSyntax.self) != nil {
                handling.hasThrow = true
            }
            if let nestedIf = statement.item.as(IfExprSyntax.self) {
                updateCaseHandling(caseName: caseName, body: nestedIf.body, catchIndex: catchIndex)
            }
        }
        catchClauses[catchIndex].caseHandling[caseName] = handling
    }

    private func extractAssignmentTarget(_ expression: ExprSyntax) -> String? {
        if let declRef = expression.as(DeclReferenceExprSyntax.self) {
            return declRef.baseName.text
        }
        if let member = expression.as(MemberAccessExprSyntax.self) {
            return member.declName.baseName.text
        }
        return nil
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
                if let receiverExpr = callExpr.arguments.first(where: { $0.label?.text == "receiver" })?.expression,
                   let methodExpr = callExpr.arguments.first(where: { $0.label?.text == "method" })?.expression {
                    let receiver = try parseReceiverPattern(receiverExpr)
                    guard let methodName = stringLiteralValue(methodExpr) else {
                        throw RuleBodyParserError.invalidClause("MustCall method must be a string literal")
                    }
                    parsed.mustCallTargets.append(RuleCallPattern(receiver: receiver, methodName: methodName))
                } else if let firstArg = callExpr.arguments.first?.expression {
                    parsed.mustCallTargets.append(try parseRuleCallPattern(firstArg))
                } else {
                    throw RuleBodyParserError.invalidClause("MustCall requires a target")
                }
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
                let targetArg = callExpr.arguments.first(where: { $0.label?.text == "target" })
                    ?? callExpr.arguments.first(where: { $0.label?.text == "check" })
                guard let targetArg,
                      let caseCall = targetArg.expression.as(FunctionCallExprSyntax.self),
                      calledName(of: caseCall.calledExpression) == "case",
                      let firstArg = caseCall.arguments.first?.expression,
                      let value = stringLiteralValue(firstArg)
                else {
                    throw RuleBodyParserError.invalidClause("MustHandleError(target: .case(\"...\"), as: <handling>) is required")
                }
                let handling = try parseErrorHandling(callExpr.arguments)
                parsed.mustHandleErrorChecks.append(
                    ErrorHandlingCheck(targetCase: value, handling: handling)
                )
                continue
            }
            if called == "mustAlsoCall" {
                let parsedWhenCalls = try parseWhenCallsChain(from: callExpr)
                let trigger = parsedWhenCalls.trigger
                let requirements = parsedWhenCalls.requirements
                parsed.whenCallsConditions.append((trigger: trigger, requirements: requirements))
                continue
            }
            if called == "MustDeclare" {
                guard let firstArg = callExpr.arguments.first?.expression else {
                    throw RuleBodyParserError.invalidClause("MustDeclare requires declaration constraint")
                }
                parsed.mustDeclareLocalChecks.append(try parseMustDeclareLocal(firstArg))
                continue
            }
            if called == "mustNotUse" || called == "mustUse" || called == "inArgument" || called == "WhenCreates" {
                parsed.whenCallsNameChecks.append(try parseWhenCallsNameChain(from: callExpr))
                continue
            }
            if called == "WhenCalls",
               callExpr.arguments.contains(where: { $0.label?.text == "name" }) {
                parsed.whenCallsNameChecks.append(try parseWhenCallsNameChain(from: callExpr))
                continue
            }
            throw RuleBodyParserError.invalidClause(
                "Unsupported top-level clause in rule body: \(called ?? "unknown")"
            )
        }
        return parsed
    }

    private static func parseMustDeclareLocal(_ expression: ExprSyntax) throws -> LocalBindingRule {
        guard let localCall = expression.as(FunctionCallExprSyntax.self),
              calledName(of: localCall.calledExpression) == "local",
              let bindingExpr = localCall.arguments.first(where: { $0.label?.text == "binding" })?.expression
        else {
            throw RuleBodyParserError.invalidClause("MustDeclare requires .local(binding: ...)")
        }
        guard let bindingCall = bindingExpr.as(FunctionCallExprSyntax.self),
              calledName(of: bindingCall.calledExpression) == "LocalBindingConstraint"
        else {
            throw RuleBodyParserError.invalidClause("local binding must use LocalBindingConstraint(...)")
        }
        guard let identifierExpr = bindingCall.arguments.first(where: { $0.label?.text == "identifier" })?.expression,
              let identifier = stringLiteralValue(identifierExpr),
              let initializerExpr = bindingCall.arguments.first(where: { $0.label?.text == "initializerIdentifier" })?.expression,
              let initializerIdentifier = stringLiteralValue(initializerExpr),
              let typeExpr = bindingCall.arguments.first(where: { $0.label?.text == "typePattern" })?.expression
        else {
            throw RuleBodyParserError.invalidClause("LocalBindingConstraint requires identifier/typePattern/initializerIdentifier")
        }
        let typePattern = try parseLocalTypePattern(typeExpr)
        return LocalBindingRule(
            identifier: identifier,
            typePattern: typePattern,
            initializerIdentifier: initializerIdentifier
        )
    }

    private static func parseLocalTypePattern(_ expression: ExprSyntax) throws -> LocalTypePatternRule {
        guard let callExpr = expression.as(FunctionCallExprSyntax.self),
              calledName(of: callExpr.calledExpression) == "anyConformance",
              let firstArg = callExpr.arguments.first?.expression,
              let protocolName = stringLiteralValue(firstArg)
        else {
            throw RuleBodyParserError.invalidClause("typePattern must be .anyConformance(\"...\")")
        }
        return .anyConformance(protocolName)
    }

    private static func parseWhenCallsNameChain(from expression: FunctionCallExprSyntax) throws -> WhenCallsNameRule {
        var current: FunctionCallExprSyntax? = expression
        var namePattern: TypeNamePatternRule?
        var argumentLabel: String?
        var mustUseIdentifier: String?
        var mustNotUseIdentifier: String?

        while let call = current {
            let called = calledName(of: call.calledExpression)
            switch called {
            case "mustNotUse":
                guard let identifierExpr = call.arguments.first(where: { $0.label?.text == "identifier" })?.expression,
                      let identifier = stringLiteralValue(identifierExpr)
                else {
                    throw RuleBodyParserError.invalidClause("mustNotUse requires identifier string literal")
                }
                mustNotUseIdentifier = identifier
                current = call.calledExpression.as(MemberAccessExprSyntax.self)?.base?.as(FunctionCallExprSyntax.self)
            case "mustUse":
                guard let identifierExpr = call.arguments.first(where: { $0.label?.text == "identifier" })?.expression,
                      let identifier = stringLiteralValue(identifierExpr)
                else {
                    throw RuleBodyParserError.invalidClause("mustUse requires identifier string literal")
                }
                mustUseIdentifier = identifier
                current = call.calledExpression.as(MemberAccessExprSyntax.self)?.base?.as(FunctionCallExprSyntax.self)
            case "inArgument":
                guard let labelExpr = call.arguments.first(where: { $0.label?.text == "argumentLabel" })?.expression,
                      let label = stringLiteralValue(labelExpr)
                else {
                    throw RuleBodyParserError.invalidClause("inArgument requires argumentLabel string literal")
                }
                argumentLabel = label
                current = call.calledExpression.as(MemberAccessExprSyntax.self)?.base?.as(FunctionCallExprSyntax.self)
            case "WhenCalls":
                if let nameExpr = call.arguments.first(where: { $0.label?.text == "name" })?.expression {
                    namePattern = try parseTypeNamePattern(nameExpr)
                    current = nil
                } else {
                    throw RuleBodyParserError.invalidClause("WhenCalls(name:) requires name pattern")
                }
            case "WhenCreates":
                guard let patternExpr = call.arguments.first(where: { $0.label?.text == "typeNamePattern" })?.expression
                else {
                    throw RuleBodyParserError.invalidClause("WhenCreates requires typeNamePattern")
                }
                namePattern = try parseTypeNamePattern(patternExpr)
                current = nil
            default:
                throw RuleBodyParserError.invalidClause("Unsupported WhenCalls(name:) clause: \(called ?? "unknown")")
            }
        }

        guard let namePattern,
              let argumentLabel,
              let mustUseIdentifier,
              let mustNotUseIdentifier
        else {
            throw RuleBodyParserError.invalidClause(
                "WhenCalls(name:) chain requires name, inArgument(argumentLabel:), mustUse(identifier:), and mustNotUse(identifier:)"
            )
        }
        if mustUseIdentifier == mustNotUseIdentifier {
            throw RuleBodyParserError.invalidClause("mustUse and mustNotUse cannot reference the same identifier")
        }
        return WhenCallsNameRule(
            namePattern: namePattern,
            argumentLabel: argumentLabel,
            mustUseIdentifier: mustUseIdentifier,
            mustNotUseIdentifier: mustNotUseIdentifier
        )
    }

    private static func parseTypeNamePattern(_ expression: ExprSyntax) throws -> TypeNamePatternRule {
        guard let patternCall = expression.as(FunctionCallExprSyntax.self),
              let called = calledName(of: patternCall.calledExpression),
              let firstArg = patternCall.arguments.first?.expression,
              let value = stringLiteralValue(firstArg)
        else {
            throw RuleBodyParserError.invalidClause("typeNamePattern must be .exact/.prefix/.suffix with string literal")
        }
        switch called {
        case "exact":
            return .exact(value)
        case "prefix":
            return .prefix(value)
        case "suffix":
            return .suffix(value)
        default:
            throw RuleBodyParserError.invalidClause("Unsupported typeNamePattern: \(called)")
        }
    }

    private static func parseWhenCallsChain(
        from expression: FunctionCallExprSyntax
    ) throws -> (trigger: RuleCallPattern, requirements: [RuleCallPattern]) {
        var current: FunctionCallExprSyntax? = expression
        var trigger: RuleCallPattern?
        var requirements: [RuleCallPattern] = []

        while let call = current {
            let called = calledName(of: call.calledExpression)
            switch called {
            case "mustAlsoCall":
                if let receiverExpr = call.arguments.first(where: { $0.label?.text == "receiver" })?.expression,
                   let methodExpr = call.arguments.first(where: { $0.label?.text == "method" })?.expression {
                    let receiver = try parseReceiverPattern(receiverExpr)
                    guard let methodName = stringLiteralValue(methodExpr) else {
                        throw RuleBodyParserError.invalidClause("mustAlsoCall method must be string literal")
                    }
                    requirements.insert(
                        RuleCallPattern(receiver: receiver, methodName: methodName),
                        at: 0
                    )
                } else if let reqExpr = call.arguments.first?.expression,
                          let reqArray = reqExpr.as(ArrayExprSyntax.self) {
                    let parsed = try reqArray.elements.map { try parseRuleCallPattern($0.expression) }
                    requirements.insert(contentsOf: parsed, at: 0)
                } else {
                    throw RuleBodyParserError.invalidClause(
                        "mustAlsoCall requires either receiver/method or requirements array"
                    )
                }
                current = call.calledExpression.as(MemberAccessExprSyntax.self)?.base?.as(FunctionCallExprSyntax.self)
            case "WhenCalls":
                if let receiverExpr = call.arguments.first(where: { $0.label?.text == "receiver" })?.expression,
                   let methodExpr = call.arguments.first(where: { $0.label?.text == "method" })?.expression {
                    let receiver = try parseReceiverPattern(receiverExpr)
                    guard let methodName = stringLiteralValue(methodExpr) else {
                        throw RuleBodyParserError.invalidClause("WhenCalls method must be string literal")
                    }
                    trigger = RuleCallPattern(receiver: receiver, methodName: methodName)
                } else if let triggerExpr = call.arguments.first?.expression {
                    trigger = try parseRuleCallPattern(triggerExpr)
                } else {
                    throw RuleBodyParserError.invalidClause(
                        "WhenCalls(...).mustAlsoCall(...) requires a trigger"
                    )
                }
                current = nil
            default:
                throw RuleBodyParserError.invalidClause("Unsupported WhenCalls chain clause: \(called ?? "unknown")")
            }
        }

        guard let trigger else {
            throw RuleBodyParserError.invalidClause("WhenCalls(...).mustAlsoCall(...) requires a trigger")
        }
        guard !requirements.isEmpty else {
            throw RuleBodyParserError.invalidClause("mustAlsoCall requires at least one requirement")
        }
        return (trigger, requirements)
    }

    private static func parseRuleCallPattern(_ expression: ExprSyntax) throws -> RuleCallPattern {
        if let callExpr = expression.as(FunctionCallExprSyntax.self),
           let called = calledName(of: callExpr.calledExpression),
           called == "RuleCallTarget" || called == "RuleCall",
           let receiverArg = callExpr.arguments.first(where: { $0.label?.text == "receiver" })?.expression,
           let methodArg = callExpr.arguments.first(where: { $0.label?.text == "method" })?.expression {
            let receiver = try parseReceiverPattern(receiverArg)
            guard let methodName = stringLiteralValue(methodArg) else {
                throw RuleBodyParserError.invalidClause("call target method must be a string literal")
            }
            return RuleCallPattern(receiver: receiver, methodName: methodName)
        }
        throw RuleBodyParserError.invalidClause("unsupported call target expression: \(expression.trimmedDescription)")
    }

    private static func parseReceiverPattern(_ expression: ExprSyntax) throws -> RuleReceiverPattern {
        if let member = expression.as(MemberAccessExprSyntax.self),
           member.base == nil {
            switch member.declName.baseName.text {
            case "any":
                return .any
            case "none":
                return .none
            default:
                throw RuleBodyParserError.invalidClause("Unknown receiver pattern .\(member.declName.baseName.text)")
            }
        }
        if let call = expression.as(FunctionCallExprSyntax.self),
           calledName(of: call.calledExpression) == "symbol",
           let arg = call.arguments.first?.expression,
           let value = stringLiteralValue(arg) {
            return .symbol(value)
        }
        throw RuleBodyParserError.invalidClause("receiver must be .any, .none, or .symbol(\"...\")")
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

    private static func parseErrorHandling(_ arguments: LabeledExprListSyntax) throws -> ErrorHandlingKind {
        guard let asArg = arguments.first(where: { $0.label?.text == "as" }) else {
            throw RuleBodyParserError.invalidClause("MustHandleError requires `as:` handling.")
        }
        if let member = asArg.expression.as(MemberAccessExprSyntax.self) {
            switch member.declName.baseName.text {
            case "through":
                return .through
            case "rethrow":
                return .rethrow
            default:
                throw RuleBodyParserError.invalidClause("Unknown MustHandleError handling: .\(member.declName.baseName.text)")
            }
        }
        if let call = asArg.expression.as(FunctionCallExprSyntax.self),
           let called = calledName(of: call.calledExpression) {
            switch called {
            case "assign":
                if let toArg = call.arguments.first(where: { $0.label?.text == "to" })?.expression,
                   let value = stringLiteralValue(toArg) {
                    return .assign(to: value)
                }
                throw RuleBodyParserError.invalidClause("as: .assign(to: \"...\") requires a string literal")
            case "transform":
                if let byArg = call.arguments.first(where: { $0.label?.text == "by" })?.expression,
                   let value = stringLiteralValue(byArg) {
                    return .transform(by: value)
                }
                throw RuleBodyParserError.invalidClause("as: .transform(by: \"...\") requires a string literal")
            default:
                throw RuleBodyParserError.invalidClause("Unknown MustHandleError handling call: \(called)")
            }
        }
        throw RuleBodyParserError.invalidClause("Unknown MustHandleError handling syntax")
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
    var mustDeclareLocalChecks: [LocalBindingRule] = []
    var whenCallsNameChecks: [WhenCallsNameRule] = []
}

private struct WhenCallsNameRule {
    let namePattern: TypeNamePatternRule
    let argumentLabel: String
    let mustUseIdentifier: String
    let mustNotUseIdentifier: String
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
    var ignoredCases: Set<String>
    var caseHandling: [String: CaseHandlingSnapshot]
}

private struct ErrorHandlingCheck {
    let targetCase: String
    let handling: ErrorHandlingKind
}

private enum ErrorHandlingKind {
    case through
    case assign(to: String)
    case transform(by: String)
    case rethrow
}

private struct CaseHandlingSnapshot {
    var assignedTargets: Set<String> = []
    var calledFunctions: Set<String> = []
    var hasThrow: Bool = false
}

private struct RuleCallPattern {
    let receiver: RuleReceiverPattern
    let methodName: String

    var rendered: String {
        switch receiver {
        case .any:
            return "[any, \(methodName)]"
        case .none:
            return "[none, \(methodName)]"
        case .symbol(let name):
            return "[symbol(\(name)), \(methodName)]"
        }
    }
}

private enum RuleReceiverPattern {
    case symbol(String)
    case none
    case any
}

private enum TypeNamePatternRule {
    case exact(String)
    case prefix(String)
    case suffix(String)

    var rendered: String {
        switch self {
        case .exact(let value):
            return "exact(\(value))"
        case .prefix(let value):
            return "prefix(\(value))"
        case .suffix(let value):
            return "suffix(\(value))"
        }
    }
}

private enum LocalTypePatternRule {
    case anyConformance(String)
}

private struct LocalBindingRule {
    let identifier: String
    let typePattern: LocalTypePatternRule
    let initializerIdentifier: String
}

private struct LabeledArgumentSite {
    let label: String
    let value: ArgumentValueSite
}

private enum ArgumentValueSite {
    case identifier(String)
    case other(String)
}

private struct TypeCreationSite {
    let typeName: String
    let arguments: [LabeledArgumentSite]
    let functionID: Int
    let line: Int
    let column: Int
}

private struct LocalDeclarationSite {
    let identifier: String
    let typeAnnotation: TypeSyntax?
    let initializerIdentifier: String?
    let isLet: Bool
    let functionID: Int
    let line: Int
    let column: Int
}


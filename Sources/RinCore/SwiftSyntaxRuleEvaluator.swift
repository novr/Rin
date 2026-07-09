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
        let functionNames = collector.functionNames
        let functionTypedThrowTypes = collector.functionTypedThrowTypes

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
                    functionNames: functionNames,
                    functionTypedThrowTypes: functionTypedThrowTypes,
                    filePath: file.path
                )
            )
        }
        return violations
    }

    static func collectCallSites(source: String, filePath: String = "Test.swift") throws -> [CollectedCallSite] {
        let syntax = Parser.parse(source: source)
        guard !syntax.hasError else {
            throw SwiftSyntaxRuleEvaluatorError.invalidSwiftFile(path: filePath, diagnostics: [])
        }
        let converter = SourceLocationConverter(fileName: filePath, tree: syntax)
        let collector = FunctionCallCollector(converter: converter, viewMode: .sourceAccurate)
        collector.walk(syntax)
        return collector.calls.map { call in
            CollectedCallSite(
                receiver: call.receiver.collectedDescription,
                method: call.method,
                functionName: call.functionName
            )
        }
    }

    static func collectCatchClauses(source: String, filePath: String = "Test.swift") throws -> [CollectedCatchClause] {
        let syntax = Parser.parse(source: source)
        guard !syntax.hasError else {
            throw SwiftSyntaxRuleEvaluatorError.invalidSwiftFile(path: filePath, diagnostics: [])
        }
        let converter = SourceLocationConverter(fileName: filePath, tree: syntax)
        let collector = FunctionCallCollector(converter: converter, viewMode: .sourceAccurate)
        collector.walk(syntax)
        return collector.catchClauses.map { catchClause in
            CollectedCatchClause(
                line: catchClause.line,
                column: catchClause.column,
                functionName: catchClause.functionName,
                handledCases: catchClause.handledCases.sorted()
            )
        }
    }

    private func evaluateRule(
        _ rule: RinRule,
        calls: [CallSite],
        catchClauses: [CatchClauseSite],
        creations: [TypeCreationSite],
        localDeclarations: [LocalDeclarationSite],
        allFunctionIDs: [Int],
        functionLocations: [Int: (line: Int, column: Int)],
        functionNames: [Int: String],
        functionTypedThrowTypes: [Int: String?],
        filePath: String
    ) throws -> [RinSemanticViolation] {
        var violations: [RinSemanticViolation] = []
        let fileAnchor = calls.first.map { ($0.line, $0.column) }
            ?? catchClauses.first.map { ($0.line, $0.column) }
            ?? (1, 1)
        let parsedRuleBody: ParsedRuleBody
        do {
            parsedRuleBody = try RuleBodyParser.parse(body: rule.body)
        } catch let parserError as RuleBodyParserError {
            throw SwiftSyntaxRuleEvaluatorError.invalidRuleBody(ruleID: rule.id, reason: parserError.localizedDescription)
        }

        for mustCall in parsedRuleBody.mustCallRules {
            violations.append(
                contentsOf: evaluateMustCall(
                    ruleID: rule.id,
                    pattern: mustCall.pattern,
                    onPath: mustCall.onPath,
                    calls: calls,
                    allFunctionIDs: allFunctionIDs,
                    functionLocations: functionLocations,
                    functionNames: functionNames,
                    filePath: filePath,
                    fileAnchor: fileAnchor
                )
            )
        }

        for mustCallAnyOf in parsedRuleBody.mustCallAnyOfRules {
            violations.append(
                contentsOf: evaluateMustCallAnyOf(
                    ruleID: rule.id,
                    patterns: mustCallAnyOf.patterns,
                    onPath: mustCallAnyOf.onPath,
                    calls: calls,
                    allFunctionIDs: allFunctionIDs,
                    functionLocations: functionLocations,
                    functionNames: functionNames,
                    filePath: filePath,
                    fileAnchor: fileAnchor
                )
            )
        }

        for conditional in parsedRuleBody.whenCallsConditions {
            violations.append(
                contentsOf: evaluateWhenCalls(
                    ruleID: rule.id,
                    condition: conditional,
                    calls: calls,
                    filePath: filePath
                )
            )
        }

        for errorCheck in parsedRuleBody.mustHandleErrorRules {
            violations.append(
                contentsOf: evaluateMustHandleError(
                    ruleID: rule.id,
                    check: errorCheck,
                    catchClauses: catchClauses,
                    allFunctionIDs: allFunctionIDs,
                    functionNames: functionNames,
                    filePath: filePath,
                    fileAnchor: fileAnchor
                )
            )
        }

        for mustThrow in parsedRuleBody.mustThrowRules {
            violations.append(
                contentsOf: evaluateMustThrow(
                    ruleID: rule.id,
                    typeName: mustThrow.typeName,
                    onPath: mustThrow.onPath,
                    allFunctionIDs: allFunctionIDs,
                    functionLocations: functionLocations,
                    functionNames: functionNames,
                    functionTypedThrowTypes: functionTypedThrowTypes,
                    filePath: filePath,
                    fileAnchor: fileAnchor
                )
            )
        }

        if parsedRuleBody.whenCallsNameChecks.isEmpty {
            for declareCheck in parsedRuleBody.mustDeclareRules {
                violations.append(
                    contentsOf: evaluateMustDeclare(
                        ruleID: rule.id,
                        declareCheck: declareCheck.binding,
                        onPath: declareCheck.onPath,
                        localDeclarations: localDeclarations,
                        allFunctionIDs: allFunctionIDs,
                        functionLocations: functionLocations,
                        functionNames: functionNames,
                        filePath: filePath,
                        fileAnchor: fileAnchor
                    )
                )
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

                    if let mustNotUse = nameCheck.mustNotUseIdentifier, identifier == mustNotUse {
                        violations.append(
                            RinSemanticViolation(
                                ruleId: rule.id,
                                reason: "Argument `\(nameCheck.argumentLabel)` must not use identifier `\(mustNotUse)`.",
                                file: filePath,
                                line: creation.line,
                                column: creation.column
                            )
                        )
                    } else if identifier != nameCheck.mustUseIdentifier {
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

                    for declareCheck in parsedRuleBody.mustDeclareRules {
                        if !matchesLocalDeclaration(declareCheck.binding, declarations: localDeclarations, functionID: creation.functionID) {
                            violations.append(
                                RinSemanticViolation(
                                    ruleId: rule.id,
                                    reason: "When `\(nameCheck.namePattern.rendered)` is called, local declaration `\(declareCheck.binding.identifier)` is required in the same function.",
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

    private func evaluateMustCall(
        ruleID: String,
        pattern: RuleCallPattern,
        onPath: UnitPathScopeRule,
        calls: [CallSite],
        allFunctionIDs: [Int],
        functionLocations: [Int: (line: Int, column: Int)],
        functionNames: [Int: String],
        filePath: String,
        fileAnchor: (Int, Int)
    ) -> [RinSemanticViolation] {
        let targetFunctionIDs = resolveFunctionUnitIDs(onPath: onPath, allFunctionIDs: allFunctionIDs, functionNames: functionNames)
        if let violation = emptyUnitViolation(
            ruleID: ruleID,
            unitsEmpty: targetFunctionIDs.isEmpty,
            ifEmpty: onPath.ifEmpty,
            filePath: filePath,
            fileAnchor: fileAnchor
        ) {
            return [violation]
        }
        var violations: [RinSemanticViolation] = []
        for functionID in targetFunctionIDs {
            let scopedCalls = calls.filter { $0.functionID == functionID }
            if !matches(pattern, in: scopedCalls) {
                let location = functionLocations[functionID] ?? fileAnchor
                violations.append(
                    RinSemanticViolation(
                        ruleId: ruleID,
                        reason: "Required call `\(pattern.rendered)` was not found.",
                        file: filePath,
                        line: location.0,
                        column: location.1
                    )
                )
            }
        }
        return violations
    }

    private func evaluateMustCallAnyOf(
        ruleID: String,
        patterns: [RuleCallPattern],
        onPath: UnitPathScopeRule,
        calls: [CallSite],
        allFunctionIDs: [Int],
        functionLocations: [Int: (line: Int, column: Int)],
        functionNames: [Int: String],
        filePath: String,
        fileAnchor: (Int, Int)
    ) -> [RinSemanticViolation] {
        let targetFunctionIDs = resolveFunctionUnitIDs(onPath: onPath, allFunctionIDs: allFunctionIDs, functionNames: functionNames)
        if let violation = emptyUnitViolation(
            ruleID: ruleID,
            unitsEmpty: targetFunctionIDs.isEmpty,
            ifEmpty: onPath.ifEmpty,
            filePath: filePath,
            fileAnchor: fileAnchor
        ) {
            return [violation]
        }
        var violations: [RinSemanticViolation] = []
        for functionID in targetFunctionIDs {
            let scopedCalls = calls.filter { $0.functionID == functionID }
            if patterns.allSatisfy({ !matches($0, in: scopedCalls) }) {
                let location = functionLocations[functionID] ?? fileAnchor
                violations.append(
                    RinSemanticViolation(
                        ruleId: ruleID,
                        reason: "At least one required call was not found: \(patterns.map(\.rendered).joined(separator: ", ")).",
                        file: filePath,
                        line: location.0,
                        column: location.1
                    )
                )
            }
        }
        return violations
    }

    private func evaluateWhenCalls(
        ruleID: String,
        condition: WhenCallsCondition,
        calls: [CallSite],
        filePath: String
    ) -> [RinSemanticViolation] {
        let triggers = calls.filter { matches(condition.trigger, in: [$0]) }
        guard !triggers.isEmpty else { return [] }

        var violations: [RinSemanticViolation] = []
        for trigger in triggers {
            let scopedCalls = followUpCalls(for: trigger, scope: condition.followUpScope, allCalls: calls)
            let missingAnd = condition.andRequirements.filter { !matches($0, in: scopedCalls) }
            let missingOrGroups = condition.orRequirementGroups.filter { group in
                group.allSatisfy { !matches($0, in: scopedCalls) }
            }
            if missingAnd.isEmpty && missingOrGroups.isEmpty {
                continue
            }
            var reasons: [String] = []
            if !missingAnd.isEmpty {
                reasons.append("missing AND calls: \(missingAnd.map(\.rendered).joined(separator: ", "))")
            }
            for group in missingOrGroups {
                reasons.append("missing OR group: \(group.map(\.rendered).joined(separator: ", "))")
            }
            violations.append(
                RinSemanticViolation(
                    ruleId: ruleID,
                    reason: "When `\(condition.trigger.rendered)` is called, required calls are missing (\(reasons.joined(separator: "; "))).",
                    file: filePath,
                    line: trigger.line,
                    column: trigger.column
                )
            )
        }
        return violations
    }

    private func evaluateMustHandleError(
        ruleID: String,
        check: MustHandleErrorRule,
        catchClauses: [CatchClauseSite],
        allFunctionIDs: [Int],
        functionNames: [Int: String],
        filePath: String,
        fileAnchor: (Int, Int)
    ) -> [RinSemanticViolation] {
        let targetIndices = resolveCatchUnitIndices(
            onPath: check.onPath,
            catchClauses: catchClauses,
            allFunctionIDs: allFunctionIDs,
            functionNames: functionNames
        )
        if let violation = emptyUnitViolation(
            ruleID: ruleID,
            unitsEmpty: targetIndices.isEmpty,
            ifEmpty: check.onPath.ifEmpty,
            filePath: filePath,
            fileAnchor: fileAnchor,
            reasonPrefix: "Required catch clause"
        ) {
            return [violation]
        }

        var violations: [RinSemanticViolation] = []
        for index in targetIndices {
            let catchClause = catchClauses[index]
            let mentions = catchClause.handledCases.contains(check.targetCase)
            if !mentions {
                if check.whenUnmentioned == .violate {
                    violations.append(
                        RinSemanticViolation(
                            ruleId: ruleID,
                            reason: "Required catch handling for `case .\(check.targetCase)` was not found.",
                            file: filePath,
                            line: catchClause.line,
                            column: catchClause.column
                        )
                    )
                }
                continue
            }
            if !satisfiesErrorHandling(catchClause: catchClause, check: check) {
                violations.append(
                    RinSemanticViolation(
                        ruleId: ruleID,
                        reason: mustHandleErrorReason(for: check),
                        file: filePath,
                        line: catchClause.line,
                        column: catchClause.column
                    )
                )
            }
        }
        return violations
    }

    private func evaluateMustDeclare(
        ruleID: String,
        declareCheck: LocalBindingRule,
        onPath: UnitPathScopeRule,
        localDeclarations: [LocalDeclarationSite],
        allFunctionIDs: [Int],
        functionLocations: [Int: (line: Int, column: Int)],
        functionNames: [Int: String],
        filePath: String,
        fileAnchor: (Int, Int)
    ) -> [RinSemanticViolation] {
        let targetFunctionIDs = resolveFunctionUnitIDs(onPath: onPath, allFunctionIDs: allFunctionIDs, functionNames: functionNames)
        if let violation = emptyUnitViolation(
            ruleID: ruleID,
            unitsEmpty: targetFunctionIDs.isEmpty,
            ifEmpty: onPath.ifEmpty,
            filePath: filePath,
            fileAnchor: fileAnchor
        ) {
            return [violation]
        }
        var violations: [RinSemanticViolation] = []
        for functionID in targetFunctionIDs {
            if matchesLocalDeclaration(declareCheck, declarations: localDeclarations, functionID: functionID) {
                continue
            }
            let location = functionLocations[functionID] ?? fileAnchor
            violations.append(
                RinSemanticViolation(
                    ruleId: ruleID,
                    reason: "Required local declaration `\(declareCheck.identifier)` was not found in the same function.",
                    file: filePath,
                    line: location.0,
                    column: location.1
                )
            )
        }
        return violations
    }

    private func evaluateMustThrow(
        ruleID: String,
        typeName: String,
        onPath: UnitPathScopeRule,
        allFunctionIDs: [Int],
        functionLocations: [Int: (line: Int, column: Int)],
        functionNames: [Int: String],
        functionTypedThrowTypes: [Int: String?],
        filePath: String,
        fileAnchor: (Int, Int)
    ) -> [RinSemanticViolation] {
        let targetFunctionIDs = resolveFunctionUnitIDs(onPath: onPath, allFunctionIDs: allFunctionIDs, functionNames: functionNames)
        if let violation = emptyUnitViolation(
            ruleID: ruleID,
            unitsEmpty: targetFunctionIDs.isEmpty,
            ifEmpty: onPath.ifEmpty,
            filePath: filePath,
            fileAnchor: fileAnchor
        ) {
            return [violation]
        }
        var violations: [RinSemanticViolation] = []
        for functionID in targetFunctionIDs {
            if functionTypedThrowTypes[functionID] != typeName {
                let location = functionLocations[functionID] ?? fileAnchor
                violations.append(
                    RinSemanticViolation(
                        ruleId: ruleID,
                        reason: "Required typed throw `\(typeName)` was not found.",
                        file: filePath,
                        line: location.0,
                        column: location.1
                    )
                )
            }
        }
        return violations
    }

    private func emptyUnitViolation(
        ruleID: String,
        unitsEmpty: Bool,
        ifEmpty: EmptyUnitPolicyRule,
        filePath: String,
        fileAnchor: (Int, Int),
        reasonPrefix: String = "Required evaluation unit"
    ) -> RinSemanticViolation? {
        guard unitsEmpty else { return nil }
        switch ifEmpty {
        case .skip:
            return nil
        case .violate:
            return RinSemanticViolation(
                ruleId: ruleID,
                reason: "\(reasonPrefix) was not found for the declared onPath scope.",
                file: filePath,
                line: fileAnchor.0,
                column: fileAnchor.1
            )
        }
    }

    private func resolveFunctionUnitIDs(
        onPath: UnitPathScopeRule,
        allFunctionIDs: [Int],
        functionNames: [Int: String]
    ) -> [Int] {
        switch onPath.kind {
        case .everyFunction:
            return allFunctionIDs
        case .namedFunctions(let name):
            return allFunctionIDs.filter { functionNames[$0] == name }
        case .matchingFunctions(let pattern):
            return allFunctionIDs.filter { functionNameMatches(functionNames[$0] ?? "", pattern: pattern) }
        case .everyCatch, .namedFunctionCatches:
            return []
        }
    }

    private func resolveCatchUnitIndices(
        onPath: UnitPathScopeRule,
        catchClauses: [CatchClauseSite],
        allFunctionIDs: [Int],
        functionNames: [Int: String]
    ) -> [Int] {
        switch onPath.kind {
        case .everyCatch:
            return Array(catchClauses.indices)
        case .namedFunctionCatches(let name):
            return catchClauses.indices.filter { index in
                guard let functionID = catchClauses[index].functionID else { return false }
                return functionNames[functionID] == name
            }
        case .everyFunction, .namedFunctions, .matchingFunctions:
            return []
        }
    }

    private func functionNameMatches(_ name: String, pattern: FunctionNamePatternRule) -> Bool {
        switch pattern {
        case .exact(let value):
            return name == value
        case .prefix(let value):
            return name.hasPrefix(value)
        case .suffix(let value):
            return name.hasSuffix(value)
        }
    }

    private func followUpCalls(for trigger: CallSite, scope: FollowUpScopeRule, allCalls: [CallSite]) -> [CallSite] {
        switch scope {
        case .sameFunction:
            guard let functionID = trigger.functionID else { return [] }
            return allCalls.filter { $0.functionID == functionID }
        case .entireFile:
            return allCalls
        }
    }

    private func satisfiesErrorHandling(catchClause: CatchClauseSite, check: MustHandleErrorRule) -> Bool {
        switch check.handling {
        case .through:
            return catchClause.ignoredCases.contains(check.targetCase)
        case .assign(let target):
            return catchClause.handledCases.contains(check.targetCase)
                && (catchClause.caseHandling[check.targetCase]?.assignedTargets.contains(target) ?? false)
        case .transform(let functionName):
            return catchClause.handledCases.contains(check.targetCase)
                && (catchClause.caseHandling[check.targetCase]?.calledFunctions.contains(functionName) ?? false)
        case .rethrow:
            return catchClause.handledCases.contains(check.targetCase)
                && (catchClause.caseHandling[check.targetCase]?.hasThrow ?? false)
        }
    }

    private func mustHandleErrorReason(for check: MustHandleErrorRule) -> String {
        switch check.handling {
        case .through:
            return "Required through catch handling `case .\(check.targetCase)` was not found."
        case .assign(let target):
            return "Required assignment handling for `case .\(check.targetCase)` to `\(target)` was not found."
        case .transform(let functionName):
            return "Required transform handling for `case .\(check.targetCase)` using `\(functionName)` was not found."
        case .rethrow:
            return "Required rethrow handling for `case .\(check.targetCase)` was not found."
        }
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
    private(set) var functionNames: [Int: String] = [:]
    private(set) var functionTypedThrowTypes: [Int: String?] = [:]
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
            appendCallSite(
                receiver: .none,
                method: declRef.baseName.text,
                line: location.line,
                column: location.column
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
            appendCallSite(
                receiver: parseReceiver(memberAccess.base),
                method: memberAccess.declName.baseName.text,
                line: location.line,
                column: location.column
            )
        }
        return .visitChildren
    }

    private func appendCallSite(receiver: CallReceiver, method: String, line: Int, column: Int) {
        let functionID = functionStack.last
        calls.append(
            CallSite(
                receiver: receiver,
                method: method,
                functionID: functionID,
                functionName: functionID.flatMap { functionNames[$0] },
                line: line,
                column: column
            )
        )
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let functionID = nextFunctionID
        nextFunctionID += 1
        allFunctionIDs.append(functionID)
        functionNames[functionID] = node.name.text
        functionTypedThrowTypes[functionID] = Self.literalTypedThrowName(
            from: node.signature.effectSpecifiers?.throwsClause
        )
        let location = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        functionLocations[functionID] = (location.line, location.column)
        functionStack.append(functionID)
        return .visitChildren
    }

    static func literalTypedThrowName(from throwsClause: ThrowsClauseSyntax?) -> String? {
        guard let type = throwsClause?.type else { return nil }
        return literalThrownTypeName(from: type)
    }

    private static func literalThrownTypeName(from type: TypeSyntax) -> String? {
        if let identifierType = type.as(IdentifierTypeSyntax.self) {
            return identifierType.name.text
        }
        if let memberType = type.as(MemberTypeSyntax.self) {
            return memberType.name.text
        }
        return nil
    }

    override func visitPost(_ node: FunctionDeclSyntax) {
        _ = functionStack.popLast()
    }

    override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind {
        let location = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        let functionID = functionStack.last
        let index = catchClauses.count
        catchClauses.append(
            CatchClauseSite(
                line: location.line,
                column: location.column,
                functionID: functionID,
                functionName: functionID.flatMap { functionNames[$0] },
                handledCases: [],
                ignoredCases: [],
                caseHandling: [:],
                usesCatchBodyForHandling: []
            )
        )
        for item in node.catchItems {
            if let pattern = item.pattern,
               let caseName = extractCaseName(from: pattern) {
                catchClauses[index].handledCases.insert(caseName)
                catchClauses[index].usesCatchBodyForHandling.insert(caseName)
            }
            if let whereClause = item.whereClause,
               let caseName = extractCaseNameFromWhereExpression(whereClause.condition) {
                catchClauses[index].handledCases.insert(caseName)
                catchClauses[index].usesCatchBodyForHandling.insert(caseName)
            }
        }
        catchClauseStack.append(index)
        return .visitChildren
    }

    override func visitPost(_ node: CatchClauseSyntax) {
        if let index = catchClauseStack.last {
            let body = node.body
            for caseName in catchClauses[index].usesCatchBodyForHandling {
                if bodyContainsThrough(body) {
                    catchClauses[index].ignoredCases.insert(caseName)
                }
                updateCaseHandling(caseName: caseName, body: body, catchIndex: index)
            }
        }
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
            if let member = expressionPattern.expression.as(MemberAccessExprSyntax.self) {
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

    private func extractCaseNameFromWhereExpression(_ expression: ExprSyntax) -> String? {
        guard let sequence = expression.as(SequenceExprSyntax.self) else {
            return nil
        }
        let parts = Array(sequence.elements)
        guard parts.count == 3,
              let operatorExpr = parts[1].as(BinaryOperatorExprSyntax.self),
              operatorExpr.operator.text == "=="
        else {
            return nil
        }
        if let caseName = extractUnqualifiedCaseName(from: parts[0]) {
            return caseName
        }
        return extractUnqualifiedCaseName(from: parts[2])
    }

    private func extractUnqualifiedCaseName(from expression: ExprSyntax) -> String? {
        guard let member = expression.as(MemberAccessExprSyntax.self),
              member.base == nil
        else {
            return nil
        }
        return member.declName.baseName.text
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
    private static let defaultFunctionScope = UnitPathScopeRule(kind: .everyFunction, ifEmpty: .violate)
    private static let defaultCatchScope = UnitPathScopeRule(kind: .everyCatch, ifEmpty: .violate)

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
                let onPath = try parseUnitPathScope(
                    from: callExpr.arguments.first(where: { $0.label?.text == "onPath" })?.expression,
                    default: defaultFunctionScope
                )
                try validateUnitPathScope(onPath, allowed: .function, predicate: "MustCall")
                let pattern: RuleCallPattern
                if let receiverExpr = callExpr.arguments.first(where: { $0.label?.text == "receiver" })?.expression,
                   let methodExpr = callExpr.arguments.first(where: { $0.label?.text == "method" })?.expression {
                    let receiver = try parseReceiverPattern(receiverExpr)
                    guard let methodName = stringLiteralValue(methodExpr) else {
                        throw RuleBodyParserError.invalidClause("MustCall method must be a string literal")
                    }
                    pattern = RuleCallPattern(receiver: receiver, methodName: methodName)
                } else if let firstArg = callExpr.arguments.first(where: { $0.label?.text == nil })?.expression {
                    pattern = try parseRuleCallPattern(firstArg)
                } else {
                    throw RuleBodyParserError.invalidClause("MustCall requires a target")
                }
                parsed.mustCallRules.append(MustCallRule(pattern: pattern, onPath: onPath))
                continue
            }
            if called == "MustCallAnyOf" {
                let onPath = try parseUnitPathScope(
                    from: callExpr.arguments.first(where: { $0.label?.text == "onPath" })?.expression,
                    default: defaultFunctionScope
                )
                try validateUnitPathScope(onPath, allowed: .function, predicate: "MustCallAnyOf")
                guard let firstArg = callExpr.arguments.first(where: { $0.label?.text == nil })?.expression,
                      let arrayExpr = firstArg.as(ArrayExprSyntax.self)
                else {
                    throw RuleBodyParserError.invalidClause("MustCallAnyOf requires array literal")
                }
                let patterns = try arrayExpr.elements.map { try parseRuleCallPattern($0.expression) }
                parsed.mustCallAnyOfRules.append(MustCallAnyOfRule(patterns: patterns, onPath: onPath))
                continue
            }
            if called == "MustHandleError" {
                let onPath = try parseUnitPathScope(
                    from: callExpr.arguments.first(where: { $0.label?.text == "onPath" })?.expression,
                    default: defaultCatchScope
                )
                try validateUnitPathScope(onPath, allowed: .catchScope, predicate: "MustHandleError")
                let whenUnmentioned = try parseWhenUnmentioned(
                    from: callExpr.arguments.first(where: { $0.label?.text == "whenUnmentioned" })?.expression
                )
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
                parsed.mustHandleErrorRules.append(
                    MustHandleErrorRule(
                        targetCase: value,
                        handling: handling,
                        onPath: onPath,
                        whenUnmentioned: whenUnmentioned
                    )
                )
                continue
            }
            if called == "mustAlsoCall" || called == "mustAlsoCallAnyOf" {
                let parsedWhenCalls = try parseWhenCallsChain(from: callExpr)
                parsed.whenCallsConditions.append(parsedWhenCalls)
                continue
            }
            if called == "MustDeclare" {
                let onPath = try parseUnitPathScope(
                    from: callExpr.arguments.first(where: { $0.label?.text == "onPath" })?.expression,
                    default: defaultFunctionScope
                )
                try validateUnitPathScope(onPath, allowed: .function, predicate: "MustDeclare")
                guard let firstArg = callExpr.arguments.first(where: { $0.label?.text == nil })?.expression else {
                    throw RuleBodyParserError.invalidClause("MustDeclare requires declaration constraint")
                }
                parsed.mustDeclareRules.append(
                    MustDeclareRule(
                        binding: try parseMustDeclareLocal(firstArg),
                        onPath: onPath
                    )
                )
                continue
            }
            if called == "MustThrow" {
                let onPath = try parseUnitPathScope(
                    from: callExpr.arguments.first(where: { $0.label?.text == "onPath" })?.expression,
                    default: defaultFunctionScope
                )
                try validateUnitPathScope(onPath, allowed: .function, predicate: "MustThrow")
                guard let typeExpr = callExpr.arguments.first(where: { $0.label?.text == "type" })?.expression,
                      let typeName = stringLiteralValue(typeExpr)
                else {
                    throw RuleBodyParserError.invalidClause("MustThrow(type: \"...\") requires a string literal")
                }
                parsed.mustThrowRules.append(MustThrowRule(typeName: typeName, onPath: onPath))
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
            if called == "WhenCalls" {
                let parsedWhenCalls = try parseWhenCallsChain(from: callExpr)
                parsed.whenCallsConditions.append(parsedWhenCalls)
                continue
            }
            throw RuleBodyParserError.invalidClause(
                "Unsupported top-level clause in rule body: \(called ?? "unknown")"
            )
        }
        return parsed
    }

    private enum AllowedUnitPathScopes {
        case function
        case catchScope
    }

    private static func validateUnitPathScope(
        _ scope: UnitPathScopeRule,
        allowed: AllowedUnitPathScopes,
        predicate: String
    ) throws {
        switch (allowed, scope.kind) {
        case (.function, .everyCatch), (.function, .namedFunctionCatches):
            throw RuleBodyParserError.invalidClause("\(predicate) cannot use catch onPath scope \(scope.kind.rendered)")
        case (.catchScope, .everyFunction), (.catchScope, .namedFunctions), (.catchScope, .matchingFunctions):
            throw RuleBodyParserError.invalidClause("\(predicate) cannot use function onPath scope \(scope.kind.rendered)")
        default:
            break
        }
    }

    private static func parseUnitPathScope(
        from expression: ExprSyntax?,
        default defaultScope: UnitPathScopeRule
    ) throws -> UnitPathScopeRule {
        guard let expression else { return defaultScope }
        guard let callExpr = expression.as(FunctionCallExprSyntax.self),
              let member = callExpr.calledExpression.as(MemberAccessExprSyntax.self),
              member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "UnitPathScope"
        else {
            throw RuleBodyParserError.invalidClause("onPath must use UnitPathScope")
        }
        let ifEmpty = try parseIfEmptyPolicy(from: callExpr.arguments)
        switch member.declName.baseName.text {
        case "everyFunction":
            return UnitPathScopeRule(kind: .everyFunction, ifEmpty: ifEmpty)
        case "namedFunctions":
            guard let nameExpr = callExpr.arguments.first?.expression,
                  let name = stringLiteralValue(nameExpr) else {
                throw RuleBodyParserError.invalidClause("namedFunctions requires a string literal")
            }
            return UnitPathScopeRule(kind: .namedFunctions(name), ifEmpty: ifEmpty)
        case "matchingFunctions":
            guard let patternExpr = callExpr.arguments.first?.expression else {
                throw RuleBodyParserError.invalidClause("matchingFunctions requires a pattern")
            }
            return UnitPathScopeRule(kind: .matchingFunctions(try parseFunctionNamePattern(patternExpr)), ifEmpty: ifEmpty)
        case "everyCatch":
            return UnitPathScopeRule(kind: .everyCatch, ifEmpty: ifEmpty)
        case "namedFunctionCatches":
            guard let nameExpr = callExpr.arguments.first?.expression,
                  let name = stringLiteralValue(nameExpr) else {
                throw RuleBodyParserError.invalidClause("namedFunctionCatches requires a string literal")
            }
            return UnitPathScopeRule(kind: .namedFunctionCatches(name), ifEmpty: ifEmpty)
        default:
            throw RuleBodyParserError.invalidClause("Unknown UnitPathScope: \(member.declName.baseName.text)")
        }
    }

    private static func parseIfEmptyPolicy(from arguments: LabeledExprListSyntax) throws -> EmptyUnitPolicyRule {
        guard let ifEmptyArg = arguments.first(where: { $0.label?.text == "ifEmpty" }) else {
            return .violate
        }
        if let member = ifEmptyArg.expression.as(MemberAccessExprSyntax.self) {
            switch member.declName.baseName.text {
            case "skip":
                return .skip
            case "violate":
                return .violate
            default:
                throw RuleBodyParserError.invalidClause("ifEmpty must be .skip or .violate")
            }
        }
        throw RuleBodyParserError.invalidClause("ifEmpty must be .skip or .violate")
    }

    private static func parseFunctionNamePattern(_ expression: ExprSyntax) throws -> FunctionNamePatternRule {
        guard let patternCall = expression.as(FunctionCallExprSyntax.self),
              let called = calledName(of: patternCall.calledExpression),
              let firstArg = patternCall.arguments.first?.expression,
              let value = stringLiteralValue(firstArg)
        else {
            throw RuleBodyParserError.invalidClause("function name pattern must be .exact/.prefix/.suffix with string literal")
        }
        switch called {
        case "exact":
            return .exact(value)
        case "prefix":
            return .prefix(value)
        case "suffix":
            return .suffix(value)
        default:
            throw RuleBodyParserError.invalidClause("Unsupported function name pattern: \(called)")
        }
    }

    private static func parseFollowUpScope(from expression: ExprSyntax?) throws -> FollowUpScopeRule {
        guard let expression else { return .sameFunction }
        if let member = expression.as(MemberAccessExprSyntax.self) {
            switch member.declName.baseName.text {
            case "sameFunction":
                return .sameFunction
            case "entireFile":
                return .entireFile
            default:
                throw RuleBodyParserError.invalidClause("WhenCalls onPath must be .sameFunction or .entireFile")
            }
        }
        throw RuleBodyParserError.invalidClause("WhenCalls onPath must be .sameFunction or .entireFile")
    }

    private static func parseWhenUnmentioned(from expression: ExprSyntax?) throws -> WhenUnmentionedPolicyRule {
        guard let expression else { return .violate }
        if let member = expression.as(MemberAccessExprSyntax.self) {
            switch member.declName.baseName.text {
            case "skip":
                return .skip
            case "violate":
                return .violate
            default:
                throw RuleBodyParserError.invalidClause("whenUnmentioned must be .skip or .violate")
            }
        }
        throw RuleBodyParserError.invalidClause("whenUnmentioned must be .skip or .violate")
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
              let mustUseIdentifier
        else {
            throw RuleBodyParserError.invalidClause(
                "WhenCalls(name:) chain requires name, inArgument(argumentLabel:), and mustUse(identifier:)"
            )
        }
        if let mustNotUseIdentifier, mustUseIdentifier == mustNotUseIdentifier {
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

    private static func parseWhenCallsChain(from expression: FunctionCallExprSyntax) throws -> WhenCallsCondition {
        var current: FunctionCallExprSyntax? = expression
        var trigger: RuleCallPattern?
        var andRequirements: [RuleCallPattern] = []
        var orRequirementGroups: [[RuleCallPattern]] = []
        var followUpScope: FollowUpScopeRule = .sameFunction

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
                    andRequirements.insert(
                        RuleCallPattern(receiver: receiver, methodName: methodName),
                        at: 0
                    )
                } else if let reqExpr = call.arguments.first?.expression,
                          let reqArray = reqExpr.as(ArrayExprSyntax.self) {
                    let parsed = try reqArray.elements.map { try parseRuleCallPattern($0.expression) }
                    andRequirements.insert(contentsOf: parsed, at: 0)
                } else {
                    throw RuleBodyParserError.invalidClause(
                        "mustAlsoCall requires either receiver/method or requirements array"
                    )
                }
                current = call.calledExpression.as(MemberAccessExprSyntax.self)?.base?.as(FunctionCallExprSyntax.self)
            case "mustAlsoCallAnyOf":
                guard let arrayExpr = call.arguments.first?.expression.as(ArrayExprSyntax.self) else {
                    throw RuleBodyParserError.invalidClause("mustAlsoCallAnyOf requires array literal")
                }
                let group = try arrayExpr.elements.map { try parseRuleCallPattern($0.expression) }
                orRequirementGroups.insert(group, at: 0)
                current = call.calledExpression.as(MemberAccessExprSyntax.self)?.base?.as(FunctionCallExprSyntax.self)
            case "WhenCalls":
                if call.arguments.contains(where: { $0.label?.text == "name" }) {
                    throw RuleBodyParserError.invalidClause("WhenCalls(name:) cannot use follow-up onPath scope")
                }
                followUpScope = try parseFollowUpScope(
                    from: call.arguments.first(where: { $0.label?.text == "onPath" })?.expression
                )
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
        guard !andRequirements.isEmpty || !orRequirementGroups.isEmpty else {
            throw RuleBodyParserError.invalidClause("WhenCalls requires at least one follow-up requirement")
        }
        return WhenCallsCondition(
            trigger: trigger,
            andRequirements: andRequirements,
            orRequirementGroups: orRequirementGroups,
            followUpScope: followUpScope
        )
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
    var mustCallRules: [MustCallRule] = []
    var mustCallAnyOfRules: [MustCallAnyOfRule] = []
    var whenCallsConditions: [WhenCallsCondition] = []
    var mustHandleErrorRules: [MustHandleErrorRule] = []
    var mustDeclareRules: [MustDeclareRule] = []
    var mustThrowRules: [MustThrowRule] = []
    var whenCallsNameChecks: [WhenCallsNameRule] = []
}

private struct MustCallRule {
    let pattern: RuleCallPattern
    let onPath: UnitPathScopeRule
}

private struct MustCallAnyOfRule {
    let patterns: [RuleCallPattern]
    let onPath: UnitPathScopeRule
}

private struct MustDeclareRule {
    let binding: LocalBindingRule
    let onPath: UnitPathScopeRule
}

private struct MustThrowRule {
    let typeName: String
    let onPath: UnitPathScopeRule
}

private struct WhenCallsCondition {
    let trigger: RuleCallPattern
    let andRequirements: [RuleCallPattern]
    let orRequirementGroups: [[RuleCallPattern]]
    let followUpScope: FollowUpScopeRule
}

private struct MustHandleErrorRule {
    let targetCase: String
    let handling: ErrorHandlingKind
    let onPath: UnitPathScopeRule
    let whenUnmentioned: WhenUnmentionedPolicyRule
}

private struct UnitPathScopeRule {
    let kind: UnitPathScopeKind
    let ifEmpty: EmptyUnitPolicyRule
}

private enum UnitPathScopeKind {
    case everyFunction
    case namedFunctions(String)
    case matchingFunctions(FunctionNamePatternRule)
    case everyCatch
    case namedFunctionCatches(String)

    var rendered: String {
        switch self {
        case .everyFunction:
            return ".everyFunction"
        case .namedFunctions(let name):
            return ".namedFunctions(\"\(name)\")"
        case .matchingFunctions:
            return ".matchingFunctions(...)"
        case .everyCatch:
            return ".everyCatch"
        case .namedFunctionCatches(let name):
            return ".namedFunctionCatches(\"\(name)\")"
        }
    }
}

private enum EmptyUnitPolicyRule {
    case skip
    case violate
}

private enum FollowUpScopeRule {
    case sameFunction
    case entireFile
}

private enum WhenUnmentionedPolicyRule {
    case skip
    case violate
}

private enum FunctionNamePatternRule {
    case exact(String)
    case prefix(String)
    case suffix(String)
}

private struct WhenCallsNameRule {
    let namePattern: TypeNamePatternRule
    let argumentLabel: String
    let mustUseIdentifier: String
    let mustNotUseIdentifier: String?
}

struct CollectedCallSite {
    let receiver: String
    let method: String
    let functionName: String?
}

struct CollectedCatchClause {
    let line: Int
    let column: Int
    let functionName: String?
    let handledCases: [String]
}

private struct CallSite {
    let receiver: CallReceiver
    let method: String
    let functionID: Int?
    let functionName: String?
    let line: Int
    let column: Int
}

private enum CallReceiver {
    case none
    case simpleName(String)
    case complex

    var collectedDescription: String {
        switch self {
        case .none:
            return "none"
        case .simpleName(let name):
            return name
        case .complex:
            return "complex"
        }
    }
}

private struct CatchClauseSite {
    let line: Int
    let column: Int
    let functionID: Int?
    let functionName: String?
    var handledCases: Set<String>
    var ignoredCases: Set<String>
    var caseHandling: [String: CaseHandlingSnapshot]
    var usesCatchBodyForHandling: Set<String>
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


import Foundation
import Testing
@testable import RinCore

@Test func semanticEngineThrowsViolationWhenRequiredMethodIsMissing() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(id: "rule", body: #"MustCall(RuleCallTarget(receiver: .symbol("Analytics"), method: "sendAnalytics"))"#, message: nil, severity: .error)
    ])
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: "func run() {}")] }
    )

    do {
        try await engine.check()
        Issue.record("Expected violations")
    } catch let error as RinterSemanticEngineError {
        switch error {
        case .violations(let violations):
            #expect(violations.count == 1)
            #expect(violations[0].ruleId == "rule")
            #expect(violations[0].reason.contains("sendAnalytics"))
            #expect(violations[0].line != nil)
            #expect(violations[0].column != nil)
        default:
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test func semanticEnginePassesWhenRequiredMethodExists() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(id: "rule", body: #"MustCall(RuleCallTarget(receiver: .symbol("Analytics"), method: "sendAnalytics"))"#, message: nil, severity: .error)
    ])
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: "func run() { Analytics.sendAnalytics() }")] }
    )

    try await engine.check()
}

@Test func semanticEngineRejectsLegacyArrayCallTargetSyntax() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(id: "rule", body: "MustCall([Analytics, sendAnalytics])", message: nil, severity: .error)
    ])
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: "func run() {}")] }
    )

    do {
        try await engine.check()
        Issue.record("Expected invalid rule body for legacy MustCall array syntax")
    } catch let error as SwiftSyntaxRuleEvaluatorError {
        switch error {
        case .invalidRuleBody(_, let reason):
            #expect(reason.contains("unsupported call target expression"))
        default:
            Issue.record("Unexpected evaluator error: \(error)")
        }
    }
}

@Test func semanticEngineRejectsLegacyArrayCallTargetSyntaxInMustCallAnyOf() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(
            id: "rule-any",
            body: """
            MustCallAnyOf([
            [Analytics, sendScreen],
            [Analytics, sendTap]
            ])
            """,
            message: nil,
            severity: .error
        )
    ])
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: "func run() {}")] }
    )

    do {
        try await engine.check()
        Issue.record("Expected invalid rule body for legacy MustCallAnyOf array syntax")
    } catch let error as SwiftSyntaxRuleEvaluatorError {
        switch error {
        case .invalidRuleBody(_, let reason):
            #expect(reason.contains("unsupported call target expression"))
        default:
            Issue.record("Unexpected evaluator error: \(error)")
        }
    }
}

@Test func semanticEngineRejectsLegacyArrayCallTargetSyntaxInWhenCalls() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(
            id: "rule-when",
            body: """
            WhenCalls([Analytics, sendScreen]).mustAlsoCall([
            [Analytics, sendContext]
            ])
            """,
            message: nil,
            severity: .error
        )
    ])
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: "func run() {}")] }
    )

    do {
        try await engine.check()
        Issue.record("Expected invalid rule body for legacy WhenCalls array syntax")
    } catch let error as SwiftSyntaxRuleEvaluatorError {
        switch error {
        case .invalidRuleBody(_, let reason):
            #expect(reason.contains("unsupported call target expression"))
        default:
            Issue.record("Unexpected evaluator error: \(error)")
        }
    }
}

@Test func semanticEngineSupportsMultilineMustCallAnyOf() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(
            id: "rule-any",
            body: """
            MustCallAnyOf([
            RuleCall(receiver: .symbol("Analytics"), method: "sendScreen"),
            RuleCall(receiver: .symbol("Analytics"), method: "sendTap")
            ])
            """,
            message: nil,
            severity: .error
        )
    ])
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: "func run() { Analytics.sendTap() }")] }
    )

    try await engine.check()
}

@Test func semanticEngineSupportsMultilineWhenCalls() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(
            id: "rule-when",
            body: """
            WhenCalls(receiver: .symbol("Analytics"), method: "sendScreen")
            .mustAlsoCall(receiver: .symbol("Analytics"), method: "sendContext")
            """,
            message: nil,
            severity: .error
        )
    ])
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: "func run() { Analytics.sendScreen() }")] }
    )

    do {
        try await engine.check()
        Issue.record("Expected violations for missing sendContext call")
    } catch let error as RinterSemanticEngineError {
        switch error {
        case .violations(let violations):
            #expect(violations.count == 1)
            #expect(violations[0].reason.contains("sendContext"))
        default:
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test func semanticEngineMustHandleErrorCasePassesWhenCaseIsHandledInCatch() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(id: "handle-cancelled", body: #"MustHandleError(target: .case("cancelled"), as: .through)"#, message: nil, severity: .error)
    ])
    let source = """
    func run() async {
        do {
            try await fetch()
        } catch {
            if case .cancelled = error { return }
            print(error)
        }
    }
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: source)] }
    )

    try await engine.check()
}

@Test func semanticEngineMustHandleErrorCaseFailsWhenGuardElseReturnsForNonTargetCase() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(id: "handle-cancelled", body: #"MustHandleError(target: .case("cancelled"), as: .through)"#, message: nil, severity: .error)
    ])
    let source = """
    func run() async {
        do {
            try await fetch()
        } catch {
            guard case .cancelled = error else { return }
            print("handled")
        }
    }
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: source)] }
    )

    do {
        try await engine.check()
        Issue.record("Expected violations because guard else return does not exit target case")
    } catch let error as RinterSemanticEngineError {
        switch error {
        case .violations(let violations):
            #expect(violations.count == 1)
            #expect(violations[0].reason.contains("through"))
        default:
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test func semanticEngineMustHandleErrorCaseFailsWhenCatchDoesNotHandleCase() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(id: "handle-cancelled", body: #"MustHandleError(target: .case("cancelled"), as: .through)"#, message: nil, severity: .error)
    ])
    let source = """
    func run() async {
        do {
            try await fetch()
        } catch {
            print(error)
        }
    }
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: source)] }
    )

    do {
        try await engine.check()
        Issue.record("Expected violations for missing cancelled case handling")
    } catch let error as RinterSemanticEngineError {
        switch error {
        case .violations(let violations):
            #expect(violations.count == 1)
            #expect(violations[0].reason.contains("case .cancelled"))
        default:
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test func semanticEngineMustHandleErrorCaseFailsWhenCaseIsNotIgnored() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(id: "handle-cancelled", body: #"MustHandleError(target: .case("cancelled"), as: .through)"#, message: nil, severity: .error)
    ])
    let source = """
    func run() async {
        do {
            try await fetch()
        } catch {
            if case .cancelled = error {
                print("ignore")
            }
        }
    }
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: source)] }
    )

    do {
        try await engine.check()
        Issue.record("Expected violations for non-ignored cancelled case handling")
    } catch let error as RinterSemanticEngineError {
        switch error {
        case .violations(let violations):
            #expect(violations.count == 1)
            #expect(violations[0].reason.contains("through"))
        default:
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test func semanticEngineMustHandleErrorCasePassesWhenCaseBreaksLoop() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(id: "handle-cancelled", body: #"MustHandleError(target: .case("cancelled"), as: .through)"#, message: nil, severity: .error)
    ])
    let source = """
    func run() async {
        do {
            try await fetch()
        } catch {
            while true {
                if case .cancelled = error { break }
                break
            }
        }
    }
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: source)] }
    )

    try await engine.check()
}

@Test func semanticEngineMustHandleErrorCasePassesWhenTargetCaseContinuesLoop() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(id: "handle-cancelled", body: #"MustHandleError(target: .case("cancelled"), as: .through)"#, message: nil, severity: .error)
    ])
    let source = """
    func run() async {
        do {
            try await fetch()
        } catch {
            while true {
                if case .cancelled = error { continue }
                break
            }
        }
    }
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: source)] }
    )

    try await engine.check()
}

@Test func semanticEngineMustHandleErrorCaseFailsWhenOnlyNonTargetCaseReturns() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(id: "handle-cancelled", body: #"MustHandleError(target: .case("cancelled"), as: .through)"#, message: nil, severity: .error)
    ])
    let source = """
    func run() async {
        do {
            try await fetch()
        } catch {
            if case .network = error { return }
            if case .cancelled = error { print("handled") }
        }
    }
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: source)] }
    )

    do {
        try await engine.check()
        Issue.record("Expected violations because target case does not exit control flow")
    } catch let error as RinterSemanticEngineError {
        switch error {
        case .violations(let violations):
            #expect(violations.count == 1)
            #expect(violations[0].reason.contains("through"))
        default:
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test func semanticEngineMustHandleErrorCaseSupportsAssignHandling() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(id: "handle-cancelled", body: #"MustHandleError(target: .case("cancelled"), as: .assign(to: "error"))"#, message: nil, severity: .error)
    ])
    let source = """
    func run() async {
        do {
            try await fetch()
        } catch {
            if case .cancelled = error {
                self.error = error
            }
        }
    }
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: source)] }
    )

    try await engine.check()
}

@Test func semanticEngineMustHandleErrorCaseAssignFailsWhenAssignmentOutsideCaseBlock() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(id: "handle-cancelled", body: #"MustHandleError(target: .case("cancelled"), as: .assign(to: "error"))"#, message: nil, severity: .error)
    ])
    let source = """
    func run() async {
        do {
            try await fetch()
        } catch {
            if case .cancelled = error {
                print("noop")
            }
            self.error = error
        }
    }
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: source)] }
    )

    do {
        try await engine.check()
        Issue.record("Expected violation because assignment is outside cancelled case block")
    } catch let error as RinterSemanticEngineError {
        switch error {
        case .violations(let violations):
            #expect(violations.count == 1)
            #expect(violations[0].reason.contains("assignment handling"))
        default:
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test func semanticEngineMustHandleErrorCaseSupportsTransformHandling() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(id: "handle-cancelled", body: #"MustHandleError(target: .case("cancelled"), as: .transform(by: "mappingToAppError"))"#, message: nil, severity: .error)
    ])
    let source = """
    func run() async {
        do {
            try await fetch()
        } catch {
            if case .cancelled = error {
                _ = mappingToAppError(error)
            }
        }
    }
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: source)] }
    )

    try await engine.check()
}

@Test func semanticEngineMustHandleErrorCaseSupportsRethrowHandling() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(id: "handle-cancelled", body: #"MustHandleError(target: .case("cancelled"), as: .rethrow)"#, message: nil, severity: .error)
    ])
    let source = """
    func run() async throws {
        do {
            try await fetch()
        } catch {
            if case .cancelled = error {
                throw error
            }
        }
    }
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: source)] }
    )

    try await engine.check()
}

@Test func semanticEngineMustHandleErrorCaseViolatesWhenNoCatchClauseExists() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(id: "handle-cancelled", body: #"MustHandleError(target: .case("cancelled"), as: .through)"#, message: nil, severity: .error)
    ])
    let source = """
    func run(error: AppError) {
        if case .cancelled = error { return }
    }
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: source)] }
    )

    do {
        try await engine.check()
        Issue.record("Expected violation because everyCatch(ifEmpty: .violate) applies when no catch exists")
    } catch let error as RinterSemanticEngineError {
        switch error {
        case .violations(let violations):
            #expect(violations.count == 1)
            #expect(violations[0].reason.contains("catch clause"))
        default:
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test func semanticEngineMustHandleErrorCaseViolatesFileWithoutCatch() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(id: "handle-cancelled", body: #"MustHandleError(target: .case("cancelled"), as: .through)"#, message: nil, severity: .error)
    ])
    let source = """
    func run() async {
        _ = await fetch()
    }
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: source)] }
    )

    do {
        try await engine.check()
        Issue.record("Expected violation because everyCatch(ifEmpty: .violate) applies when no catch exists")
    } catch let error as RinterSemanticEngineError {
        switch error {
        case .violations(let violations):
            #expect(violations.count == 1)
            #expect(violations[0].reason.contains("catch clause"))
        default:
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test func semanticEngineMustCallEvaluatesEachFunctionIndependently() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(id: "must-call-analytics", body: #"MustCall(RuleCallTarget(receiver: .symbol("Analytics"), method: "sendAnalytics"))"#, message: nil, severity: .error)
    ])
    let source = """
    func a() { Analytics.sendAnalytics() }
    func b() {}
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: source)] }
    )

    do {
        try await engine.check()
        Issue.record("Expected violation in function b")
    } catch let error as RinterSemanticEngineError {
        switch error {
        case .violations(let violations):
            #expect(violations.count == 1)
            #expect(violations[0].reason.contains("sendAnalytics"))
        default:
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test func semanticEngineMustCallDoesNotTreatCaseMatchAsCall() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(id: "must-call-cancelled", body: #"MustCall(RuleCallTarget(receiver: .any, method: "cancelled"))"#, message: nil, severity: .error)
    ])
    let source = """
    func run() async {
        do {
            try await fetch()
        } catch {
            if case .cancelled = error { return }
        }
    }
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: source)] }
    )

    do {
        try await engine.check()
        Issue.record("Expected violations because MustCall only checks call sites")
    } catch let error as RinterSemanticEngineError {
        switch error {
        case .violations(let violations):
            #expect(violations.count == 1)
            #expect(violations[0].reason.contains("[any, cancelled]"))
        default:
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test func semanticEngineMustCallDoesNotMatchComplexReceiverToTypeName() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(id: "must-call", body: #"MustCall(RuleCallTarget(receiver: .symbol("Analytics"), method: "sendAnalytics"))"#, message: nil, severity: .error)
    ])
    let source = """
    struct API {
        let analytics: Analytics
        func run() {
            api.analytics.sendAnalytics()
        }
    }
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: source)] }
    )

    do {
        try await engine.check()
        Issue.record("Expected violation because complex receiver should not match type name")
    } catch let error as RinterSemanticEngineError {
        switch error {
        case .violations(let violations):
            #expect(violations.count == 1)
            #expect(violations[0].reason.contains("[symbol(Analytics), sendAnalytics]"))
        default:
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test func semanticEngineMustCallSupportsNoneReceiverPattern() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(id: "must-call-mapper", body: #"MustCall(RuleCallTarget(receiver: .none, method: "mappingToAppError"))"#, message: nil, severity: .error)
    ])
    let source = """
    func run() {
        _ = mappingToAppError(error)
    }
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: source)] }
    )

    try await engine.check()
}

@Test func semanticEngineWhenCallsNameMustUseOnlyPasses() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(
            id: "store-witness-performer",
            body: """
            WhenCalls(name: .suffix("StoreWitness")).inArgument(argumentLabel: "performer").mustUse(identifier: "performer")
            """,
            message: nil,
            severity: .error
        )
    ])
    let source = """
    struct ProductStoreWitness {
        init(performer: Any) {}
    }
    struct ProductStore {
        func makeStoreWitness(performer: Any) -> ProductStoreWitness {
            return ProductStoreWitness(performer: performer)
        }
    }
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/ProductStore.swift", source: source)] }
    )

    try await engine.check()
}

@Test func semanticEngineWhenCallsNameMustUseOnlyFailsForWrongIdentifier() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(
            id: "store-witness-performer",
            body: """
            WhenCalls(name: .suffix("StoreWitness")).inArgument(argumentLabel: "performer").mustUse(identifier: "performer")
            """,
            message: nil,
            severity: .error
        )
    ])
    let source = """
    struct ProductStoreWitness {
        init(performer: Any) {}
    }
    struct ProductStore {
        func makeStoreWitness(store: Any) -> ProductStoreWitness {
            return ProductStoreWitness(performer: store)
        }
    }
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/ProductStore.swift", source: source)] }
    )

    do {
        try await engine.check()
        Issue.record("Expected violation for mustUse-only wrong identifier")
    } catch let error as RinterSemanticEngineError {
        switch error {
        case .violations(let violations):
            #expect(violations.count == 1)
            #expect(violations[0].reason.contains("must use identifier"))
        default:
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test func semanticEngineWhenCallsNameReportsMustUseWhenIdentifierIsNeither() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(
            id: "store-witness-performer",
            body: """
            WhenCalls(name: .suffix("StoreWitness")).inArgument(argumentLabel: "performer").mustUse(identifier: "performer").mustNotUse(identifier: "store")
            """,
            message: nil,
            severity: .error
        )
    ])
    let source = """
    struct ProductStoreWitness {
        init(performer: Any) {}
    }
    struct ProductStore {
        func makeStoreWitness(logger: Any) -> ProductStoreWitness {
            return ProductStoreWitness(performer: logger)
        }
    }
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/ProductStore.swift", source: source)] }
    )

    do {
        try await engine.check()
        Issue.record("Expected violation when identifier matches neither mustUse nor mustNotUse")
    } catch let error as RinterSemanticEngineError {
        switch error {
        case .violations(let violations):
            #expect(violations.count == 1)
            #expect(violations[0].reason.contains("must use identifier"))
            #expect(!violations[0].reason.contains("must not use identifier"))
        default:
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test func semanticEngineWhenCreatesMustUseOnlyPasses() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(
            id: "store-witness-performer",
            body: """
            WhenCreates(typeNamePattern: .suffix("StoreWitness")).inArgument(argumentLabel: "performer").mustUse(identifier: "performer")
            """,
            message: nil,
            severity: .error
        )
    ])
    let source = """
    struct ProductStoreWitness {
        init(performer: Any) {}
    }
    struct ProductStore {
        func makeStoreWitness(performer: Any) -> ProductStoreWitness {
            return ProductStoreWitness(performer: performer)
        }
    }
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/ProductStore.swift", source: source)] }
    )

    try await engine.check()
}

@Test func semanticEngineWhenCallsNameWithMustDeclarePassesForPerformerBinding() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(
            id: "store-witness-performer",
            body: """
            MustDeclare(.local(binding: LocalBindingConstraint(identifier: "performer", typePattern: .anyConformance("WitnessActionPerformer"), initializerIdentifier: "store")))
            WhenCalls(name: .suffix("StoreWitness")).inArgument(argumentLabel: "performer").mustUse(identifier: "performer").mustNotUse(identifier: "store")
            """,
            message: nil,
            severity: .error
        )
    ])
    let source = """
    protocol WitnessActionPerformer<Action> {}
    struct ProductStoreWitness {
        init(performer: Any) {}
    }
    struct ProductStore {
        func makeStoreWitness(store: Any) -> ProductStoreWitness {
            let performer: any WitnessActionPerformer<Int> = store
            return ProductStoreWitness(performer: performer)
        }
    }
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/ProductStore.swift", source: source)] }
    )

    try await engine.check()
}

@Test func semanticEngineWhenCallsNameFailsForDirectStoreArgument() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(
            id: "store-witness-performer",
            body: """
            MustDeclare(.local(binding: LocalBindingConstraint(identifier: "performer", typePattern: .anyConformance("WitnessActionPerformer"), initializerIdentifier: "store")))
            WhenCalls(name: .suffix("StoreWitness")).inArgument(argumentLabel: "performer").mustUse(identifier: "performer").mustNotUse(identifier: "store")
            """,
            message: nil,
            severity: .error
        )
    ])
    let source = """
    protocol WitnessActionPerformer<Action> {}
    struct MemberStoreWitness {
        init(performer: Any) {}
    }
    struct MemberStore {
        func makeStoreWitness(store: Any) -> MemberStoreWitness {
            let performer: any WitnessActionPerformer<Int> = store
            return MemberStoreWitness(performer: store)
        }
    }
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/MemberStore.swift", source: source)] }
    )

    do {
        try await engine.check()
        Issue.record("Expected violation for direct store passing")
    } catch let error as RinterSemanticEngineError {
        switch error {
        case .violations(let violations):
            #expect(violations.count == 1)
            #expect(violations[0].reason.contains("must not use identifier"))
        default:
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test func semanticEngineWhenCallsNameFailsWhenLocalBindingMissing() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(
            id: "store-witness-performer",
            body: """
            MustDeclare(.local(binding: LocalBindingConstraint(identifier: "performer", typePattern: .anyConformance("WitnessActionPerformer"), initializerIdentifier: "store")))
            WhenCalls(name: .suffix("StoreWitness")).inArgument(argumentLabel: "performer").mustUse(identifier: "performer").mustNotUse(identifier: "store")
            """,
            message: nil,
            severity: .error
        )
    ])
    let source = """
    struct ProductStoreWitness {
        init(performer: Any) {}
    }
    struct ProductStore {
        func makeStoreWitness(store: Any, performer: Any) -> ProductStoreWitness {
            ProductStoreWitness(performer: performer)
        }
    }
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/ProductStore.swift", source: source)] }
    )

    do {
        try await engine.check()
        Issue.record("Expected violation for missing local declaration")
    } catch let error as RinterSemanticEngineError {
        switch error {
        case .violations(let violations):
            #expect(violations.count == 1)
            #expect(violations[0].reason.contains("local declaration"))
        default:
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test func semanticEngineWhenCallsNameAppliesToAllMatches() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(
            id: "store-witness-performer",
            body: """
            MustDeclare(.local(binding: LocalBindingConstraint(identifier: "performer", typePattern: .anyConformance("WitnessActionPerformer"), initializerIdentifier: "store")))
            WhenCalls(name: .suffix("StoreWitness")).inArgument(argumentLabel: "performer").mustUse(identifier: "performer").mustNotUse(identifier: "store")
            """,
            message: nil,
            severity: .error
        )
    ])
    let source = """
    protocol WitnessActionPerformer<Action> {}
    struct ProductStoreWitness {
        init(performer: Any) {}
    }
    struct ProductStore {
        func makeStoreWitness(store: Any) {
            let performer: any WitnessActionPerformer<Int> = store
            _ = ProductStoreWitness(performer: performer)
            _ = ProductStoreWitness(performer: store)
        }
    }
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/ProductStore.swift", source: source)] }
    )

    do {
        try await engine.check()
        Issue.record("Expected violation because all matched creations must satisfy the rule")
    } catch let error as RinterSemanticEngineError {
        switch error {
        case .violations(let violations):
            #expect(violations.count == 1)
            #expect(violations[0].reason.contains("must not use identifier"))
        default:
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test func semanticEngineRejectsWhenCallsNameRuleWithConflictingIdentifiers() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(
            id: "store-witness-performer",
            body: """
            WhenCalls(name: .suffix("StoreWitness")).inArgument(argumentLabel: "performer").mustUse(identifier: "performer").mustNotUse(identifier: "performer")
            """,
            message: nil,
            severity: .error
        )
    ])
    let source = """
    struct ProductStoreWitness {
        init(performer: Any) {}
    }
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/ProductStore.swift", source: source)] }
    )

    do {
        try await engine.check()
        Issue.record("Expected invalid rule body due to conflicting identifiers")
    } catch let error as SwiftSyntaxRuleEvaluatorError {
        switch error {
        case .invalidRuleBody(_, let reason):
            #expect(reason.contains("cannot reference the same identifier"))
        default:
            Issue.record("Unexpected evaluator error: \(error)")
        }
    }
}

@Test func semanticEngineMustDeclareStandaloneRequiresBindingInEachFunction() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(
            id: "required-performer-binding",
            body: """
            MustDeclare(.local(binding: LocalBindingConstraint(identifier: "performer", typePattern: .anyConformance("WitnessActionPerformer"), initializerIdentifier: "store")))
            """,
            message: nil,
            severity: .error
        )
    ])
    let source = """
    protocol WitnessActionPerformer<Action> {}
    struct Store {
        func makeA(store: Any) {
            let performer: any WitnessActionPerformer<Int> = store
        }
        func makeB(store: Any) {
            _ = store
        }
    }
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/Store.swift", source: source)] }
    )

    do {
        try await engine.check()
        Issue.record("Expected violation for missing local declaration in makeB")
    } catch let error as RinterSemanticEngineError {
        switch error {
        case .violations(let violations):
            #expect(violations.count == 1)
            #expect(violations[0].reason.contains("same function"))
        default:
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test func semanticEngineAcceptsLegacyWhenCreatesSyntax() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(
            id: "store-witness-performer",
            body: """
            WhenCreates(typeNamePattern: .suffix("StoreWitness")).inArgument(argumentLabel: "performer").mustUse(identifier: "performer").mustNotUse(identifier: "store")
            """,
            message: nil,
            severity: .error
        )
    ])
    let source = """
    struct ProductStoreWitness {
        init(performer: Any) {}
    }
    struct ProductStore {
        func makeStoreWitness(store: Any, performer: Any) -> ProductStoreWitness {
            ProductStoreWitness(performer: performer)
        }
    }
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/ProductStore.swift", source: source)] }
    )

    try await engine.check()
}

@Test func semanticEngineMustHandleErrorPassesWithWhereClauseMention() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(id: "handle-cancelled", body: #"MustHandleError(target: .case("cancelled"), as: .through)"#, message: nil, severity: .error)
    ])
    let source = """
    func run() async {
        do {
            try await fetch()
        } catch let error where error == .cancelled {
            return
        }
    }
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: source)] }
    )

    try await engine.check()
}

@Test func semanticEngineMustHandleErrorWhenUnmentionedSkipAllowsGenericCatch() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(
            id: "handle-cancelled",
            body: #"MustHandleError(target: .case("cancelled"), as: .through, whenUnmentioned: .skip)"#,
            message: nil,
            severity: .error
        )
    ])
    let source = """
    func run() async {
        do {
            try await fetch()
        } catch {
            print(error)
        }
    }
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: source)] }
    )

    try await engine.check()
}

@Test func semanticEngineWhenCallsDefaultsToSameFunctionScope() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(
            id: "transaction-pair",
            body: """
            WhenCalls(receiver: .symbol("DB"), method: "beginTransaction")
            .mustAlsoCall(receiver: .symbol("DB"), method: "commit")
            """,
            message: nil,
            severity: .error
        )
    ])
    let source = """
    func a() { DB.beginTransaction() }
    func b() { DB.commit() }
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: source)] }
    )

    do {
        try await engine.check()
        Issue.record("Expected violation at beginTransaction trigger in function a")
    } catch let error as RinterSemanticEngineError {
        switch error {
        case .violations(let violations):
            #expect(violations.count == 1)
            #expect(violations[0].reason.contains("commit"))
        default:
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test func semanticEngineWhenCallsEntireFileAllowsFollowUpInAnotherFunction() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(
            id: "transaction-pair",
            body: """
            WhenCalls(receiver: .symbol("DB"), method: "beginTransaction", onPath: .entireFile)
            .mustAlsoCall(receiver: .symbol("DB"), method: "commit")
            """,
            message: nil,
            severity: .error
        )
    ])
    let source = """
    func a() { DB.beginTransaction() }
    func b() { DB.commit() }
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: source)] }
    )

    try await engine.check()
}

@Test func semanticEngineWhenCallsMustAlsoCallAnyOfPassesWithEitherFollowUp() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(
            id: "transaction-pair",
            body: """
            WhenCalls(receiver: .symbol("DB"), method: "beginTransaction")
            .mustAlsoCallAnyOf([
                RuleCall(receiver: .symbol("DB"), method: "commit"),
                RuleCall(receiver: .symbol("DB"), method: "rollback")
            ])
            """,
            message: nil,
            severity: .error
        )
    ])
    let source = """
    func run() {
        DB.beginTransaction()
        DB.rollback()
    }
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: source)] }
    )

    try await engine.check()
}

@Test func semanticEngineNamedFunctionsIfEmptySkipPassesWhenTargetMissing() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(
            id: "load-analytics",
            body: #"MustCall(receiver: .symbol("Analytics"), method: "sendScreen", onPath: UnitPathScope.namedFunctions("load", ifEmpty: .skip))"#,
            message: nil,
            severity: .error
        )
    ])
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: "func run() {}")] }
    )

    try await engine.check()
}

@Test func semanticEngineRejectsMustCallWithCatchOnPath() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(
            id: "invalid-scope",
            body: #"MustCall(receiver: .symbol("Analytics"), method: "sendScreen", onPath: UnitPathScope.everyCatch())"#,
            message: nil,
            severity: .error
        )
    ])
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: "func run() {}")] }
    )

    do {
        try await engine.check()
        Issue.record("Expected parser error for invalid onPath scope combination")
    } catch let error as SwiftSyntaxRuleEvaluatorError {
        switch error {
        case .invalidRuleBody(_, let reason):
            #expect(reason.contains("catch onPath"))
        default:
            Issue.record("Unexpected evaluator error: \(error)")
        }
    }
}

@Test func collectorExposesCallSitesWithFunctionName() throws {
    let calls = try SwiftSyntaxRuleEvaluator.collectCallSites(source: """
    func a() { Analytics.sendScreen() }
    func b() {}
    """)
    #expect(calls.count == 1)
    #expect(calls[0].method == "sendScreen")
    #expect(calls[0].functionName == "a")
}

@Test func collectorExposesCatchClausesWithHandledCases() throws {
    let catches = try SwiftSyntaxRuleEvaluator.collectCatchClauses(source: """
    func run() {
        do { try fetch() }
        catch let error where error == .cancelled { return }
    }
    """)
    #expect(catches.count == 1)
    #expect(catches[0].functionName == "run")
    #expect(catches[0].handledCases.contains("cancelled"))
}

@Test func semanticEngineMustCallAnyOfEvaluatesEachFunctionIndependently() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(
            id: "must-call-any",
            body: """
            MustCallAnyOf([
                RuleCall(receiver: .symbol("Analytics"), method: "sendScreen"),
                RuleCall(receiver: .symbol("Analytics"), method: "sendTap")
            ])
            """,
            message: nil,
            severity: .error
        )
    ])
    let source = """
    func a() { Analytics.sendScreen() }
    func b() {}
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: source)] }
    )

    do {
        try await engine.check()
        Issue.record("Expected violation in function b")
    } catch let error as RinterSemanticEngineError {
        switch error {
        case .violations(let violations):
            #expect(violations.count == 1)
            #expect(violations[0].reason.contains("sendScreen"))
        default:
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test func semanticEngineMustCallViolatesWhenNoFunctionsExist() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(id: "must-call", body: #"MustCall(RuleCallTarget(receiver: .symbol("Analytics"), method: "sendAnalytics"))"#, message: nil, severity: .error)
    ])
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: "print(1)")] }
    )

    do {
        try await engine.check()
        Issue.record("Expected violation when everyFunction finds no units")
    } catch let error as RinterSemanticEngineError {
        switch error {
        case .violations(let violations):
            #expect(violations.count == 1)
            #expect(violations[0].reason.contains("evaluation unit"))
        default:
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test func semanticEngineMustHandleErrorViolatesCatchIsTypePattern() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(id: "handle-cancelled", body: #"MustHandleError(target: .case("cancelled"), as: .through)"#, message: nil, severity: .error)
    ])
    let source = """
    func run() async {
        do {
            try await fetch()
        } catch is CancellationError {
            return
        }
    }
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: source)] }
    )

    do {
        try await engine.check()
        Issue.record("Expected violation because catch is Type does not mention case name")
    } catch let error as RinterSemanticEngineError {
        switch error {
        case .violations(let violations):
            #expect(violations.count == 1)
            #expect(violations[0].reason.contains("cancelled"))
        default:
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test func semanticEngineMustHandleErrorPassesQualifiedCatchPattern() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(id: "handle-cancelled", body: #"MustHandleError(target: .case("cancelled"), as: .through)"#, message: nil, severity: .error)
    ])
    let source = """
    func run() async {
        do {
            try await fetch()
        } catch AppError.cancelled {
            return
        }
    }
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: source)] }
    )

    try await engine.check()
}

@Test func semanticEngineMustHandleErrorReportsOnlyFailingCatchClause() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(id: "handle-cancelled", body: #"MustHandleError(target: .case("cancelled"), as: .through)"#, message: nil, severity: .error)
    ])
    let source = """
    func run() async {
        do {
            try await fetch()
        } catch {
            if case .cancelled = error { return }
        } catch {
            if case .cancelled = error { print("not through") }
        }
    }
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: source)] }
    )

    do {
        try await engine.check()
        Issue.record("Expected violation only for the second catch clause")
    } catch let error as RinterSemanticEngineError {
        switch error {
        case .violations(let violations):
            #expect(violations.count == 1)
            #expect(violations[0].reason.contains("through"))
        default:
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test func semanticEngineWhenCallsMixedAndAndOrRequirements() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(
            id: "mixed-pairing",
            body: """
            WhenCalls(receiver: .symbol("DB"), method: "beginTransaction")
            .mustAlsoCall(receiver: .symbol("DB"), method: "prepare")
            .mustAlsoCallAnyOf([
                RuleCall(receiver: .symbol("DB"), method: "commit"),
                RuleCall(receiver: .symbol("DB"), method: "rollback")
            ])
            """,
            message: nil,
            severity: .error
        )
    ])
    let source = """
    func run() {
        DB.beginTransaction()
        DB.commit()
    }
    """
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: source)] }
    )

    do {
        try await engine.check()
        Issue.record("Expected violation for missing AND requirement prepare")
    } catch let error as RinterSemanticEngineError {
        switch error {
        case .violations(let violations):
            #expect(violations.count == 1)
            #expect(violations[0].reason.contains("prepare"))
        default:
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test func semanticEngineWhenCallsSkipsWhenNoTriggerExists() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(
            id: "transaction-pair",
            body: """
            WhenCalls(receiver: .symbol("DB"), method: "beginTransaction")
            .mustAlsoCall(receiver: .symbol("DB"), method: "commit")
            """,
            message: nil,
            severity: .error
        )
    ])
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: "func run() {}")] }
    )

    try await engine.check()
}

@Test func collectorExposesQualifiedCatchPatternCaseName() throws {
    let catches = try SwiftSyntaxRuleEvaluator.collectCatchClauses(source: """
    func run() {
        do { try fetch() }
        catch AppError.cancelled { return }
    }
    """)
    #expect(catches.count == 1)
    #expect(catches[0].handledCases.contains("cancelled"))
}

@Test func semanticEngineMustThrowPassesForLiteralTypedThrows() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(
            id: "must-throw-app-error",
            body: #"MustThrow(type: "AppError", onPath: UnitPathScope.namedFunctions("run", ifEmpty: .skip))"#,
            message: nil,
            severity: .error
        )
    ])
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in
            [DiffedSwiftFile(path: "Sources/App.swift", source: """
            func run() async throws(AppError) { try await work() }
            """)]
        }
    )

    try await engine.check()
}

@Test func semanticEngineMustThrowFailsForUntypedThrows() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(
            id: "must-throw-app-error",
            body: #"MustThrow(type: "AppError")"#,
            message: nil,
            severity: .error
        )
    ])
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in
            [DiffedSwiftFile(path: "Sources/App.swift", source: """
            func run() throws { try work() }
            """)]
        }
    )

    do {
        try await engine.check()
        Issue.record("Expected typed throw violation")
    } catch let error as RinterSemanticEngineError {
        switch error {
        case .violations(let violations):
            #expect(violations.count == 1)
            #expect(violations[0].reason.contains("AppError"))
        default:
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test func semanticEngineMustThrowMatchesQualifiedThrownTypeName() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(
            id: "must-throw-app-error",
            body: #"MustThrow(type: "AppError")"#,
            message: nil,
            severity: .error
        )
    ])
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in
            [DiffedSwiftFile(path: "Sources/App.swift", source: """
            func run() throws(Module.AppError) { try work() }
            """)]
        }
    )

    try await engine.check()
}

@Test func semanticEngineMustThrowFailsWhenFunctionHasNoThrows() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(id: "must-throw-app-error", body: #"MustThrow(type: "AppError")"#, message: nil, severity: .error)
    ])
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: "func run() { work() }")] }
    )

    do {
        try await engine.check()
        Issue.record("Expected typed throw violation")
    } catch let error as RinterSemanticEngineError {
        switch error {
        case .violations(let violations):
            #expect(violations.count == 1)
        default:
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test func semanticEngineMustThrowFailsForWrongThrownType() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(id: "must-throw-app-error", body: #"MustThrow(type: "AppError")"#, message: nil, severity: .error)
    ])
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: "func run() throws(NetworkError) { try work() }")] }
    )

    do {
        try await engine.check()
        Issue.record("Expected typed throw violation")
    } catch let error as RinterSemanticEngineError {
        switch error {
        case .violations(let violations):
            #expect(violations.count == 1)
        default:
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test func semanticEngineMustThrowSkipsWhenNamedFunctionMissing() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(
            id: "must-throw-app-error",
            body: #"MustThrow(type: "AppError", onPath: UnitPathScope.namedFunctions("run", ifEmpty: .skip))"#,
            message: nil,
            severity: .error
        )
    ])
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: "func load() throws(AppError) { }")] }
    )

    try await engine.check()
}

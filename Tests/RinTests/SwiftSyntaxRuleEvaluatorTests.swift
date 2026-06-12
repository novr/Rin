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
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: "print(1)")] }
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
            RuleCallTarget(receiver: .symbol("Analytics"), method: "sendScreen"),
            RuleCallTarget(receiver: .symbol("Analytics"), method: "sendTap")
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
            WhenCalls(RuleCallTarget(receiver: .symbol("Analytics"), method: "sendScreen")).mustAlsoCall([
            RuleCallTarget(receiver: .symbol("Analytics"), method: "sendContext")
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

@Test func semanticEngineMustHandleErrorCaseIgnoresNonCatchCaseMatch() async throws {
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

    try await engine.check()
}

@Test func semanticEngineMustHandleErrorCaseSkipsFileWithoutCatch() async throws {
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

    try await engine.check()
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

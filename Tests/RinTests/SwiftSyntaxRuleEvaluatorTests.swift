import Foundation
import Testing
@testable import RinCore

@Test func semanticEngineThrowsViolationWhenRequiredMethodIsMissing() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(id: "rule", body: "MustCall([Analytics, sendAnalytics])", message: nil, severity: .error)
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
        RinRule(id: "rule", body: "MustCall([Analytics, sendAnalytics])", message: nil, severity: .error)
    ])
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: "func run() { Analytics.sendAnalytics() }")] }
    )

    try await engine.check()
}

@Test func semanticEngineSupportsMultilineMustCallAnyOf() async throws {
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
        loadFiles: { _ in [DiffedSwiftFile(path: "Sources/App.swift", source: "func run() { Analytics.sendTap() }")] }
    )

    try await engine.check()
}

@Test func semanticEngineSupportsMultilineWhenCalls() async throws {
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
        RinRule(id: "must-call-cancelled", body: #"MustCall(RuleCallTarget("*", "cancelled"))"#, message: nil, severity: .error)
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
            #expect(violations[0].reason.contains("[*, cancelled]"))
        default:
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test func semanticEngineMustCallDoesNotMatchComplexReceiverToTypeName() async throws {
    let policy = RinPolicy(include: [], exclude: [], rules: [
        RinRule(id: "must-call", body: "MustCall([Analytics, sendAnalytics])", message: nil, severity: .error)
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
            #expect(violations[0].reason.contains("[Analytics, sendAnalytics]"))
        default:
            Issue.record("Unexpected error: \(error)")
        }
    }
}

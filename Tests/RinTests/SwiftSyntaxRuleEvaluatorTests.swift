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

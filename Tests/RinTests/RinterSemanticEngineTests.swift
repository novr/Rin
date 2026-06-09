import Foundation
import Testing
@testable import RinCore

@Test func semanticEngineRespectsTargetIncludeExclude() async throws {
    let policy = RinPolicy(
        include: ["Sources/App/**/*.swift"],
        exclude: ["Sources/App/Generated/**"],
        rules: [
            RinRule(id: "rule", body: "MustCall([Analytics, sendAnalytics])", message: nil, severity: .error)
        ]
    )
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in
            [
                DiffedSwiftFile(path: "Sources/App/Feature/Screen.swift", source: "func run() {}"),
                DiffedSwiftFile(path: "Sources/App/Generated/Auto.swift", source: "func run() {}"),
                DiffedSwiftFile(path: "Sources/Other/Screen.swift", source: "func run() {}")
            ]
        }
    )

    do {
        try await engine.check()
        Issue.record("Expected violation only for included non-excluded target.")
    } catch let error as RinterSemanticEngineError {
        switch error {
        case .violations(let violations):
            #expect(violations.count == 1)
            #expect(violations[0].file == "Sources/App/Feature/Screen.swift")
        default:
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test func semanticEngineMatchesPlusInTargetPattern() async throws {
    let policy = RinPolicy(
        include: ["**/*+Injection.swift"],
        exclude: [],
        rules: [
            RinRule(id: "rule", body: "MustCall([Resolver, register])", message: nil, severity: .error)
        ]
    )
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in
            [
                DiffedSwiftFile(path: "Sources/AppFeature+Injection.swift", source: "func setup() {}"),
                DiffedSwiftFile(path: "Sources/AppFeature.swift", source: "func setup() {}")
            ]
        }
    )

    do {
        try await engine.check()
        Issue.record("Expected violation for +Injection target file.")
    } catch let error as RinterSemanticEngineError {
        switch error {
        case .violations(let violations):
            #expect(violations.count == 1)
            #expect(violations[0].file == "Sources/AppFeature+Injection.swift")
        default:
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test func semanticEngineRespectsRuleScope() async throws {
    let policy = RinPolicy(
        include: ["Features/**/*.swift"],
        exclude: [],
        rules: [
            RinRule(
                id: "viewmodel_analytics",
                body: "MustCall([Analytics, sendScreen])",
                scopeInclude: ["**/*ViewModel.swift"]
            )
        ]
    )
    let engine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in policy },
        loadFiles: { _ in
            [
                DiffedSwiftFile(path: "Features/Home/HomeViewModel.swift", source: "func start() {}"),
                DiffedSwiftFile(path: "Features/Home/HomeRepository.swift", source: "func fetch() {}")
            ]
        }
    )

    do {
        try await engine.check()
        Issue.record("Expected violation only for scoped ViewModel file.")
    } catch let error as RinterSemanticEngineError {
        switch error {
        case .violations(let violations):
            #expect(violations.count == 1)
            #expect(violations[0].file == "Features/Home/HomeViewModel.swift")
        default:
            Issue.record("Unexpected error: \(error)")
        }
    }
}

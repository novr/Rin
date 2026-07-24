import Foundation
import Testing
@testable import RinCore

@Test func configValidatorAcceptsValidRules() throws {
    let validator = RinConfigValidator(
        loadPolicy: { _ in
            RinPolicy(
                include: [],
                exclude: [],
                rules: [
                    RinRule(
                        id: "analytics",
                        body: #"MustCall(receiver: .symbol("Analytics"), method: "send")"#
                    )
                ]
            )
        }
    )

    try validator.validate(at: URL(fileURLWithPath: "/tmp/Rinfile.swift"))
}

@Test func configValidatorRejectsDuplicateRuleIDs() throws {
    let validator = RinConfigValidator(
        loadPolicy: { _ in
            RinPolicy(
                include: [],
                exclude: [],
                rules: [
                    RinRule(id: "duplicate", body: #"MustThrow(type: "AppError")"#),
                    RinRule(id: "duplicate", body: #"MustThrow(type: "NetworkError")"#)
                ]
            )
        }
    )

    #expect(throws: RinConfigValidatorError.self) {
        try validator.validate(at: URL(fileURLWithPath: "/tmp/Rinfile.swift"))
    }
}

@Test func configValidatorRejectsEmptyRuleBody() throws {
    let validator = RinConfigValidator(
        loadPolicy: { _ in
            RinPolicy(
                include: [],
                exclude: [],
                rules: [RinRule(id: "empty", body: " \n ")]
            )
        }
    )

    #expect(throws: RinConfigValidatorError.self) {
        try validator.validate(at: URL(fileURLWithPath: "/tmp/Rinfile.swift"))
    }
}

@Test func configValidatorRejectsWhitespaceRuleID() throws {
    let validator = RinConfigValidator(
        loadPolicy: { _ in
            RinPolicy(
                include: [],
                exclude: [],
                rules: [RinRule(id: " \n ", body: #"MustThrow(type: "AppError")"#)]
            )
        }
    )

    #expect(throws: RinConfigValidatorError.self) {
        try validator.validate(at: URL(fileURLWithPath: "/tmp/Rinfile.swift"))
    }
}

@Test func configValidatorRejectsUnknownRuleClause() throws {
    let validator = RinConfigValidator(
        loadPolicy: { _ in
            RinPolicy(
                include: [],
                exclude: [],
                rules: [RinRule(id: "unknown", body: "UnknownPredicate()")]
            )
        }
    )

    #expect(throws: SwiftSyntaxRuleEvaluatorError.self) {
        try validator.validate(at: URL(fileURLWithPath: "/tmp/Rinfile.swift"))
    }
}

@Test func configValidatorRejectsNonPredicateStatement() throws {
    let validator = RinConfigValidator(
        loadPolicy: { _ in
            RinPolicy(
                include: [],
                exclude: [],
                rules: [RinRule(id: "statement", body: "let value = 1")]
            )
        }
    )

    #expect(throws: SwiftSyntaxRuleEvaluatorError.self) {
        try validator.validate(at: URL(fileURLWithPath: "/tmp/Rinfile.swift"))
    }
}

@Test func rinterEngineCheckConfigSkipsSourceEvaluation() async throws {
    let semanticEngine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in
            Issue.record("Configuration check must not run semantic evaluation.")
            return RinPolicy(include: [], exclude: [], rules: [])
        },
        loadFiles: { _ in
            Issue.record("Configuration check must not load source files.")
            return []
        }
    )
    let engine = RinterEngine(
        semanticEngine: semanticEngine,
        checkConfig: true,
        validateConfig: {}
    )

    try await engine.run()
}

@Test func rinterEngineCheckConfigMapsFailureToRuntimeError() async throws {
    let semanticEngine = RinterSemanticEngine(
        projectRootURL: URL(fileURLWithPath: "/tmp"),
        rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
        loadPolicy: { _ in RinPolicy(include: [], exclude: [], rules: []) },
        loadFiles: { _ in [] }
    )
    let engine = RinterEngine(
        semanticEngine: semanticEngine,
        checkConfig: true,
        validateConfig: {
            throw RinConfigValidatorError.duplicateRuleID("duplicate")
        }
    )

    do {
        try await engine.run()
        Issue.record("Expected configuration failure.")
    } catch RinterEngineError.runtime(let message) {
        #expect(message.contains("duplicate"))
    }
}

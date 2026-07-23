import Foundation
import Testing
@testable import RinCore

private func emptyFilesEngine(
    failOnEmpty: Bool = false,
    outputFormat: RinOutputFormat = .text,
    writeStandardOutput: @escaping (String) throws -> Void = { _ in }
) -> RinterEngine {
    RinterEngine(
        semanticEngine: RinterSemanticEngine(
            projectRootURL: URL(fileURLWithPath: "/tmp"),
            rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
            loadPolicy: { _ in RinPolicy(include: [], exclude: [], rules: []) },
            loadFiles: { _ in [] }
        ),
        failOnEmpty: failOnEmpty,
        outputFormat: outputFormat,
        writeStandardOutput: writeStandardOutput
    )
}

@Test func rinViolationJSONEncodesEmptyArray() throws {
    let json = try RinViolationJSON.encodedLine([])
    #expect(json == "[]\n")
}

@Test func rinViolationJSONEncodesViolationFields() throws {
    let violations = [
        RinSemanticViolation(
            ruleId: "must-call-analytics",
            reason: "Required call was not found.",
            file: "Sources/App.swift",
            line: 12,
            column: 4
        )
    ]

    let json = try RinViolationJSON.encodedLine(violations)
    let decoded = try JSONDecoder().decode([RinSemanticViolation].self, from: Data(json.utf8))
    #expect(decoded == violations)
}

@Test func rinterEnginePassesWhenNoSwiftFilesByDefault() async throws {
    try await emptyFilesEngine().run()
}

@Test func rinterEngineFailsWhenNoSwiftFilesAndFailOnEmpty() async throws {
    do {
        try await emptyFilesEngine(failOnEmpty: true).run()
        Issue.record("Expected fail-on-empty violation")
    } catch RinterEngineError.violation(let message) {
        #expect(message == "No Swift files to evaluate.")
    }
}

@Test func rinterEngineFailOnEmptyWritesNoJSONOutput() async throws {
    var capturedOutput = ""
    let engine = emptyFilesEngine(
        failOnEmpty: true,
        outputFormat: .json,
        writeStandardOutput: { capturedOutput = $0 }
    )

    do {
        try await engine.run()
        Issue.record("Expected fail-on-empty violation")
    } catch RinterEngineError.violation {
        #expect(capturedOutput.isEmpty)
    }
}

@Test func rinterEngineFailsWhenAllFilesFilteredOutAndFailOnEmpty() async throws {
    let engine = RinterEngine(
        semanticEngine: RinterSemanticEngine(
            projectRootURL: URL(fileURLWithPath: "/tmp"),
            rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
            loadPolicy: { _ in
                RinPolicy(include: ["Sources/App/**"], exclude: [], rules: [])
            },
            loadFiles: { _ in
                [DiffedSwiftFile(path: "Tests/AppTests.swift", source: "func testLoad() { }")]
            }
        ),
        failOnEmpty: true
    )

    do {
        try await engine.run()
        Issue.record("Expected fail-on-empty violation")
    } catch RinterEngineError.violation(let message) {
        #expect(message == "No Swift files to evaluate.")
    }
}

@Test func rinterEngineWritesJSONOnSuccess() async throws {
    var capturedOutput = ""
    let engine = emptyFilesEngine(
        outputFormat: .json,
        writeStandardOutput: { capturedOutput = $0 }
    )

    try await engine.run()
    #expect(capturedOutput == "[]\n")
}

@Test func rinterEngineWritesJSONOnViolations() async throws {
    var capturedOutput = ""
    let engine = RinterEngine(
        semanticEngine: RinterSemanticEngine(
            projectRootURL: URL(fileURLWithPath: "/tmp"),
            rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
            loadPolicy: { _ in
                RinPolicy(include: [], exclude: [], rules: [
                    RinRule(id: "must-call-analytics", body: #"MustCall(receiver: .symbol("Analytics"), method: "sendScreen")"#, message: nil, severity: .error)
                ])
            },
            loadFiles: { _ in
                [DiffedSwiftFile(path: "Sources/App.swift", source: "func load() { }")]
            }
        ),
        outputFormat: .json,
        writeStandardOutput: { capturedOutput = $0 }
    )

    do {
        try await engine.run()
        Issue.record("Expected violation")
    } catch RinterEngineError.violation {
        #expect(capturedOutput.contains(#""ruleId":"must-call-analytics""#))
        #expect(capturedOutput.hasSuffix("\n"))
    }
}

@Test func rinterEnginePassesWhenSwiftFilesExistDespiteFailOnEmpty() async throws {
    let engine = RinterEngine(
        semanticEngine: RinterSemanticEngine(
            projectRootURL: URL(fileURLWithPath: "/tmp"),
            rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
            loadPolicy: { _ in RinPolicy(include: [], exclude: [], rules: []) },
            loadFiles: { _ in
                [DiffedSwiftFile(path: "Sources/App.swift", source: "func load() { }")]
            }
        ),
        failOnEmpty: true
    )

    try await engine.run()
}

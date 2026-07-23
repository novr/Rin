import Foundation
import Testing
@testable import RinCore

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

@Test func rinterEngineWritesJSONOnSuccess() async throws {
  var capturedOutput = ""
  let engine = RinterEngine(
    semanticEngine: RinterSemanticEngine(
      projectRootURL: URL(fileURLWithPath: "/tmp"),
      rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
      loadPolicy: { _ in RinPolicy(include: [], exclude: [], rules: []) },
      loadFiles: { _ in [] }
    ),
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

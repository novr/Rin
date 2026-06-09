import Foundation
import Testing
@testable import RinCore

@Test func rinterEngineRuns() async throws {
    let engine = RinterEngine(
        semanticEngine: RinterSemanticEngine(
            projectRootURL: URL(fileURLWithPath: "/tmp"),
            rinfileURL: URL(fileURLWithPath: "/tmp/Rinfile.swift"),
            loadPolicy: { _ in RinPolicy(include: [], exclude: [], rules: []) },
            loadFiles: { _ in [] }
        )
    )

    do {
        try await engine.run()
    } catch {
        Issue.record("Expected engine run to finish without fatal errors: \(error)")
    }
}

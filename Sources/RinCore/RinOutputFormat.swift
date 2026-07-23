import Foundation

public enum RinOutputFormat: String, Sendable {
    case text
    case json
}

enum RinViolationJSON {
    static func encodedLine(_ violations: [RinSemanticViolation]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(violations)
        guard let json = String(data: data, encoding: .utf8) else {
            throw RinViolationJSONError.encodingFailed
        }
        return json + "\n"
    }
}

enum RinViolationJSONError: Error {
    case encodingFailed
}

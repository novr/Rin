import Foundation

struct RinSemanticViolation: Equatable, Codable {
    let ruleId: String
    let reason: String
    let file: String?
    let line: Int?
    let column: Int?
}

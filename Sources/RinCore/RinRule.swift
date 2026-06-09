import Foundation

struct RinPolicy: Equatable {
    let include: [String]
    let exclude: [String]
    let rules: [RinRule]

    init(include: [String], exclude: [String], rules: [RinRule]) {
        self.include = include
        self.exclude = exclude
        self.rules = rules
    }
}

struct RinRule: Equatable {
    let id: String
    let body: String
    let message: String?
    let severity: Severity?
    let scopeInclude: [String]
    let scopeExclude: [String]

    init(
        id: String,
        body: String,
        message: String? = nil,
        severity: Severity? = nil,
        scopeInclude: [String] = [],
        scopeExclude: [String] = []
    ) {
        self.id = id
        self.body = body
        self.message = message
        self.severity = severity
        self.scopeInclude = scopeInclude
        self.scopeExclude = scopeExclude
    }
}

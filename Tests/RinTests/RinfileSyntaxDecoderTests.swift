import Foundation
import Testing
@testable import RinCore

@Test func rinfileDecoderExtractsTargetAndRules() throws {
    let source = """
    let policy = Rin.Policy {
        Target(include: ["Sources/**/*.swift"], exclude: ["**/Generated/**"])
        Rules {
            Rule(id: "no_direct_async_in_view") {
                "Do not call repository directly in View."
            }
            .message("Move async logic out of View.")
            .severity(.error)
        }
    }
    """

    let policy = try RinfileSyntaxDecoder().decode(source: source)
    #expect(policy.include == ["Sources/**/*.swift"])
    #expect(policy.exclude == ["**/Generated/**"])
    #expect(policy.rules.count == 1)
    #expect(policy.rules[0].id == "no_direct_async_in_view")
    #expect(policy.rules[0].message == "Move async logic out of View.")
    #expect(policy.rules[0].severity == .error)
}

@Test func rinfileDecoderRejectsStringInterpolation() throws {
    let source = """
    let reason = "dynamic"
    let policy = Rin.Policy {
        Rules {
            Rule(id: "no_dynamic") {
                "\\(reason)"
            }
        }
    }
    """

    #expect(throws: RinfileSyntaxDecoderError.self) {
        _ = try RinfileSyntaxDecoder().decode(source: source)
    }
}

@Test func rinfileDecoderAllowsLeadingNonPolicyVariables() throws {
    let source = """
    let version = "1.0"
    let policy = Rin.Policy {
        Rules {
            Rule(id: "no_dynamic") {
                MustCall([Analytics, sendAnalytics])
            }
        }
    }
    """

    let policy = try RinfileSyntaxDecoder().decode(source: source)
    #expect(policy.rules.count == 1)
    #expect(policy.rules[0].id == "no_dynamic")
}

@Test func rinfileDecoderParsesRuleScope() throws {
    let source = """
    let policy = Rin.Policy {
        Rules {
            Rule(id: "scoped_rule") {
                MustCall(RuleCallTarget("Analytics", "sendScreen"))
            }
            .scope(include: ["Features/**/*.swift"], exclude: ["**/*Mock*.swift"])
        }
    }
    """

    let policy = try RinfileSyntaxDecoder().decode(source: source)
    #expect(policy.rules.count == 1)
    #expect(policy.rules[0].scopeInclude == ["Features/**/*.swift"])
    #expect(policy.rules[0].scopeExclude == ["**/*Mock*.swift"])
}

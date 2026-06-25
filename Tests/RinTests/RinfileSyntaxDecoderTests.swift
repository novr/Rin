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
                MustCall(receiver: .symbol("Analytics"), method: "sendAnalytics")
            }
        }
    }
    """

    let policy = try RinfileSyntaxDecoder().decode(source: source)
    #expect(policy.rules.count == 1)
    #expect(policy.rules[0].id == "no_dynamic")
}

@Test func rinfileDecoderRendersMustCallWithReceiverMethodSyntax() throws {
    let source = """
    let policy = Rin.Policy {
        Rules {
            Rule(id: "analytics") {
                MustCall(receiver: .symbol("Analytics"), method: "sendAnalytics")
            }
        }
    }
    """

    let policy = try RinfileSyntaxDecoder().decode(source: source)
    #expect(policy.rules[0].body.contains(#"MustCall(receiver: .symbol("Analytics"), method: "sendAnalytics")"#))
}

@Test func rinfileDecoderParsesRuleScope() throws {
    let source = """
    let policy = Rin.Policy {
        Rules {
            Rule(id: "scoped_rule") {
                MustCall(RuleCallTarget(receiver: .symbol("Analytics"), method: "sendScreen"))
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

@Test func rinfileDecoderParsesMustHandleErrorCheckCaseClause() throws {
    let source = #"""
    let policy = Rin.Policy {
        Rules {
            Rule(id: "handle_cancelled") {
                MustHandleError(target: .case("cancelled"), as: .through)
            }
        }
    }
    """#

    let policy = try RinfileSyntaxDecoder().decode(source: source)
    #expect(policy.rules.count == 1)
    #expect(policy.rules[0].body.contains(#"MustHandleError(target: .case("cancelled"), as: .through)"#))
}

@Test func rinfileDecoderParsesMustDeclareAndWhenCallsNameClauses() throws {
    let source = #"""
    let policy = Rin.Policy {
        Rules {
            Rule(id: "store_witness_requires_performer_binding") {
                MustDeclare(.local(binding: LocalBindingConstraint(identifier: "performer", typePattern: .anyConformance("WitnessActionPerformer"), initializerIdentifier: "store")))
                WhenCalls(name: .suffix("StoreWitness"))
                    .inArgument(argumentLabel: "performer")
                    .mustUse(identifier: "performer")
                    .mustNotUse(identifier: "store")
            }
        }
    }
    """#

    let policy = try RinfileSyntaxDecoder().decode(source: source)
    #expect(policy.rules.count == 1)
    #expect(policy.rules[0].body.contains("MustDeclare(.local(binding: LocalBindingConstraint"))
    #expect(policy.rules[0].body.contains("WhenCalls(name: .suffix(\"StoreWitness\"))"))
    #expect(policy.rules[0].body.contains(".inArgument(argumentLabel: \"performer\")"))
}

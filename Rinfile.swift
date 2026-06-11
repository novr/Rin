let policy = Rin.Policy {
    Target(
        include: ["Sources/**/*.swift", "Plugins/**/*.swift"],
        exclude: ["**/Generated/**", "**/*Mock*.swift", ".build/**"]
    )
    Rules {
        Rule(id: "cli_returns_exitcode") {
            MustCall(
                RuleCallTarget(receiver: .symbol("ExitCode"), method: "rawValue")
            )
        }
        .scope(include: ["Sources/RinterCLI/main.swift"])
        .message("CLI must return explicit ExitCode for failures.")
        .severity(.error)

        Rule(id: "engine_wraps_violation_error") {
            MustCall(
                RuleCallTarget(receiver: .symbol("RinterEngineError"), method: "violation")
            )
        }
        .scope(include: ["Sources/RinCore/RinterEngine.swift"])
        .message("Engine must map semantic violations to RinterEngineError.violation.")
        .severity(.error)

        Rule(id: "engine_wraps_runtime_error") {
            MustCall(
                RuleCallTarget(receiver: .symbol("RinterEngineError"), method: "runtime")
            )
        }
        .scope(include: ["Sources/RinCore/RinterEngine.swift"])
        .message("Engine must map runtime failures to RinterEngineError.runtime.")
        .severity(.error)

        Rule(id: "plugin_waits_for_process") {
            WhenCalls(
                RuleCallTarget(receiver: .symbol("process"), method: "run"),
                mustAlsoCall: [
                    RuleCallTarget(receiver: .symbol("process"), method: "waitUntilExit")
                ]
            )
        }
        .scope(include: ["Plugins/Rinter/Rinter.swift"])
        .message("Plugin must wait for launched process completion.")
        .severity(.error)

        Rule(id: "gitdiff_waits_for_process") {
            WhenCalls(
                RuleCallTarget(receiver: .symbol("process"), method: "run"),
                mustAlsoCall: [
                    RuleCallTarget(receiver: .symbol("process"), method: "waitUntilExit")
                ]
            )
        }
        .scope(include: ["Sources/RinCore/GitDiffProvider.swift"])
        .message("Git process execution must waitUntilExit before reading outputs.")
        .severity(.error)
    }
}
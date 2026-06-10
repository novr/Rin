let policy = Rin.Policy {
    Target(
        include: ["Sources/**/*.swift", "Plugins/**/*.swift"],
        exclude: ["**/Generated/**", "**/*Mock*.swift", ".build/**"]
    )
    Rules {
        Rule(id: "cli_returns_exitcode") {
            MustCall(
                RuleCallTarget("ExitCode", "rawValue")
            )
        }
        .scope(include: ["Sources/RinterCLI/main.swift"])
        .message("CLI must return explicit ExitCode for failures.")
        .severity(.error)

        Rule(id: "engine_wraps_violation_error") {
            MustCall(
                RuleCallTarget("RinterEngineError", "violation")
            )
        }
        .scope(include: ["Sources/RinCore/RinterEngine.swift"])
        .message("Engine must map semantic violations to RinterEngineError.violation.")
        .severity(.error)

        Rule(id: "engine_wraps_runtime_error") {
            MustCall(
                RuleCallTarget("RinterEngineError", "runtime")
            )
        }
        .scope(include: ["Sources/RinCore/RinterEngine.swift"])
        .message("Engine must map runtime failures to RinterEngineError.runtime.")
        .severity(.error)

        Rule(id: "plugin_waits_for_process") {
            WhenCalls(
                RuleCallTarget("process", "run"),
                mustAlsoCall: [
                    RuleCallTarget("process", "waitUntilExit")
                ]
            )
        }
        .scope(include: ["Plugins/Rinter/Rinter.swift"])
        .message("Plugin must wait for launched process completion.")
        .severity(.error)

        Rule(id: "gitdiff_waits_for_process") {
            WhenCalls(
                RuleCallTarget("process", "run"),
                mustAlsoCall: [
                    RuleCallTarget("process", "waitUntilExit")
                ]
            )
        }
        .scope(include: ["Sources/RinCore/GitDiffProvider.swift"])
        .message("Git process execution must waitUntilExit before reading outputs.")
        .severity(.error)
    }
}
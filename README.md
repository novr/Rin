# Rin (Rinter)

Rinter is a semantic policy CLI for Swift projects.  
It reads `Rinfile.swift`, evaluates changed Swift code with deterministic SwiftSyntax AST checks, and fail-closes on runtime errors.

## Problem

- Missed required calls (authorization, logging, transaction cleanup) are hard to catch in review.
- Rinter enforces these rules with static AST checks and fails CI when violations are found.

## Installation

### Requirements

- macOS 13 or later

### Homebrew (tap)

```bash
brew tap novr/taps
brew trust --formula novr/taps/rinter
brew install novr/taps/rinter
```

### Release tar.gz

```bash
curl -LO https://github.com/novr/Rin/releases/download/v<version>/rinter_<version>_darwin_arm64.tar.gz
curl -LO https://github.com/novr/Rin/releases/download/v<version>/checksums.txt
shasum -a 256 -c checksums.txt
tar -xzf rinter_<version>_darwin_arm64.tar.gz
./rinter --help
```

### From source

- Build from source: Swift 6.2 or later

```bash
swift build -c release
./.build/release/rinter --help
```

## Quick Start

1. Create `Rinfile.swift`:

```swift
let policy = Rin.Policy {
    Target(
        include: ["App/**/*.swift", "Features/**/*.swift"],
        exclude: ["**/Generated/**", "**/*Mock*.swift"]
    )
    Rules {
        Rule(id: "viewmodel_tracks_screen") {
            MustCall(receiver: .symbol("Analytics"), method: "sendScreen")
        }
        .message("ViewModel entry flows must send screen analytics.")
        .severity(.error)
    }
}
```

2. Run:

```bash
rinter
```

3. Example output:

```text
❌ Semantic policy violation(s) found.
Features/Home/HomeViewModel.swift:42:13: [viewmodel_tracks_screen]
Required call `[symbol(Analytics), sendScreen]` was not found.
❌ Semantic policy violations detected.
```

## Configuration

Minimal policy:

```swift
let policy = Rin.Policy {
    Target(
        include: ["App/**/*.swift", "Features/**/*.swift"],
        exclude: ["**/Generated/**"]
    )
    Rules {
        Rule(id: "viewmodel_tracks_screen") {
            MustCall(receiver: .symbol("Analytics"), method: "sendScreen")
        }
        .scope(
            include: ["**/*ViewModel.swift"],
            exclude: ["**/*Mock*.swift"]
        )
        .message("ViewModel entry flows must send screen analytics.")
        .severity(.error)
    }
}
```

## Scan Paths

Changed Swift files matched by `Target(include:)` are analyzed.  
Use `Target(exclude:)` to skip paths.

```swift
Target(
    include: ["app/**/*.swift", "src/**/*.swift", "Modules/**/*.swift"],
    exclude: ["vendor/**", "tests/**"]
)
```

## Rule Scope

Use `Rule.scope(include:exclude:)` to narrow a rule to specific files.

```swift
Rule(id: "viewmodel_tracks_screen") {
    MustCall(receiver: .symbol("Analytics"), method: "sendScreen")
}
.scope(
    include: ["**/*ViewModel.swift"],
    exclude: ["**/*Mock*.swift"]
)
.message("ViewModel entry flows must send screen analytics.")
.severity(.error)
```

## Required Calls

```swift
Rule(id: "authorization_single") {
    MustCall(receiver: .symbol("Authorizer"), method: "authorize")
}

Rule(id: "authorization_any") {
    MustCallAnyOf([
        RuleCall(receiver: .symbol("Authorizer"), method: "authorize"),
        RuleCall(receiver: .symbol("Authorizer"), method: "can")
    ])
}
```

## Error Handling

```swift
Rule(id: "store_catch_cancellation") {
    MustHandleError(target: .case("cancelled"), as: .through)
}
.scope(
    include: ["**/Domain/Store/*Store.swift"]
)
.message("Store の catch では cancelled を読み捨てること。")
.severity(.error)
```

`MustHandleError` supports these handling modes:
- `.through`
- `.assign(to: "...")`
- `.transform(by: "...")`
- `.rethrow`

`as: .through` is considered satisfied only when the target case itself exits control flow (`return`, `break`, or `continue`).

Examples:
- OK: `if case .cancelled = error { return }`
- NG: `guard case .cancelled = error else { return }` (the exit path is non-target side)

## Paired Calls

```swift
Rule(id: "transaction_pair") {
    WhenCalls(receiver: .symbol("DB"), method: "beginTransaction")
        .mustAlsoCallAnyOf([
            RuleCall(receiver: .symbol("DB"), method: "commit"),
            RuleCall(receiver: .symbol("DB"), method: "rollback"),
        ])
}
.message("Transactions must end with commit() or rollback().")
.severity(.error)
```

By default, `WhenCalls` evaluates follow-up calls within the **same function** as the trigger (`onPath: .sameFunction`). Use `onPath: .entireFile` to opt into file-wide co-occurrence.

## Evaluation Model

Rinter evaluates each predicate **per evaluation unit** (function, catch clause, or trigger call site). Violations are reported at the unit's anchor location.

| Principle | Behavior |
|-----------|----------|
| Per-unit evaluation | Each function / catch / trigger is checked independently |
| `onPath` on predicate | Scope is declared on the predicate itself (not chained afterward) |
| Empty units (`ifEmpty`) | When no units match `onPath`, `.violate` (default) or `.skip` |
| Conditional predicates | When no trigger matches, the rule is skipped |
| Violation location | Anchor of the failing unit (function declaration, `catch`, or trigger call) |

| Predicate | Unit | Default `onPath` |
|-----------|------|------------------|
| `MustCall` / `MustCallAnyOf` / `MustDeclare` | Each `FunctionDecl` | `everyFunction(ifEmpty: .violate)` |
| `MustHandleError` | Each `catch` clause | `everyCatch(ifEmpty: .violate)` |
| `WhenCalls` + follow-ups | Each trigger call | `sameFunction` |
| `WhenCalls(name:)` + `MustDeclare` | Each matching type creation | Creation's function (no `onPath`) |

`MustHandleError` detects case mentions from catch patterns, `if case` / `guard case` in the catch body, and `where` clauses comparing against `.caseName`. Unmentioned catch clauses violate by default (`whenUnmentioned: .violate`); use `whenUnmentioned: .skip` to allow generic handlers.

Scope examples:

```swift
MustCall(receiver: .symbol("Analytics"), method: "sendScreen",
         onPath: .namedFunctions("load", ifEmpty: .skip))

MustHandleError(target: .case("cancelled"), as: .through,
                onPath: .everyCatch(ifEmpty: .violate),
                whenUnmentioned: .violate)
```

## CLI

```bash
rinter [--config <path>] [--rule <id>] [-a|--all-files] [--verbose]
```

- `-c`, `--config`: path to `Rinfile.swift` (default: `Rinfile.swift`)
- `-r`, `--rule`: evaluate only the specified rule id
- `-a`, `--all-files`: evaluate all Swift files under project root (not just git diff)
- `-v`, `--verbose`: verbose logs during evaluation
- `--version`: show rinter version
- `-h`, `--help`: show help

Alternative execution:

```bash
swift package rinter --help
mint run novr/rin@<tag> rinter --help
swift run rinter --help
```

## CI Integration

```yaml
name: Rinter
on: [push, pull_request]
jobs:
  check:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - name: Download release binary
        env:
          RINTER_VERSION: "v1.0.0" # pin your desired release tag
        run: |
          curl -LO "https://github.com/novr/Rin/releases/download/${RINTER_VERSION}/rinter_${RINTER_VERSION#v}_darwin_arm64.tar.gz"
          curl -LO "https://github.com/novr/Rin/releases/download/${RINTER_VERSION}/checksums.txt"
          shasum -a 256 -c checksums.txt
          tar -xzf "rinter_${RINTER_VERSION#v}_darwin_arm64.tar.gz"
          chmod +x ./rinter
      - run: ./rinter --config Rinfile.swift
```

## How It Works

- Parse `Rinfile.swift` with SwiftSyntax.
- Collect changed Swift files from git diff.
- Collect call sites in each file.
- Evaluate `MustCall`, `MustCallAnyOf`, `MustHandleError`, and `WhenCalls`.
- Exit non-zero on violations or runtime errors.

## Limitations

- File-local AST evaluation only.
- Receiver matching is syntax-based (`.symbol("name")` matches base identifier exactly).
- `.through` is syntax-based for control-flow exits and does not track jump destination semantics for nested loops/blocks.
- Scope control is path-based (`Target` and `Rule.scope`).
- Co-occurrence checks do not guarantee call order or 1:1 pairing.
- Helper delegation (calls moved to private helpers) is not detected.
- `deinit` and `subscript` are not attached to function scope metadata.
- `catch is Type` and non-literal `where` conditions are not treated as case mentions.

## Special Thanks

Special thanks to [fuwasegu/guardrail](https://github.com/fuwasegu/guardrail).

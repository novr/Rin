# Rin (Rinter)

Rinter is a semantic policy CLI for Swift projects.  
It reads `Rinfile.swift`, evaluates changed Swift code with deterministic SwiftSyntax AST checks, and fail-closes on runtime errors.

## Problem

- Missed required calls (authorization, logging, transaction cleanup) are hard to catch in review.
- Rinter enforces these rules with static AST checks and fails CI when violations are found.

## Installation

### Requirements

- macOS 13 or later (Apple Silicon and Intel)

### Homebrew (tap)

```bash
brew tap novr/taps
brew trust --formula novr/taps/rinter
brew install novr/taps/rinter
```

### Release tar.gz

Universal binary (Apple Silicon and Intel):

```bash
curl -LO https://github.com/novr/Rin/releases/download/v<version>/rinter_<version>_darwin.tar.gz
curl -LO https://github.com/novr/Rin/releases/download/v<version>/checksums.txt
shasum -a 256 -c checksums.txt
tar -xzf rinter_<version>_darwin.tar.gz
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
        Rule(id: "viewmodel_load_tracks_screen") {
            MustCall(
                receiver: .symbol("Analytics"),
                method: "sendScreen",
                onPath: .namedFunctions("load", ifEmpty: .skip)
            )
        }
        .scope(include: ["**/*ViewModel.swift"])
        .message("ViewModel.load must send screen analytics.")
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
Features/Home/HomeViewModel.swift:42:13: [viewmodel_load_tracks_screen]
Required call `[symbol(Analytics), sendScreen]` was not found.
❌ Semantic policy violations detected.
```

## Configuration

Same as [Quick Start](#quick-start). Add `exclude` on `Rule.scope` to skip mocks and generated code:

```swift
.scope(
    include: ["**/*ViewModel.swift"],
    exclude: ["**/*Mock*.swift", "**/Generated/**"]
)
```

Narrow **files** with `Rule.scope` and **functions** with `onPath` on each predicate.

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

`Rule.scope` limits which **files** a rule applies to (separate from `onPath`, which limits **functions** or **catch** units inside those files).

```swift
.scope(
    include: ["**/*ViewModel.swift"],
    exclude: ["**/*Mock*.swift"]
)
```

## Required Calls

```swift
Rule(id: "authorization_single") {
    MustCall(
        receiver: .symbol("Authorizer"),
        method: "authorize",
        onPath: .namedFunctions("execute", ifEmpty: .skip)
    )
}

Rule(id: "authorization_any") {
    MustCallAnyOf([
        RuleCall(receiver: .symbol("Authorizer"), method: "authorize"),
        RuleCall(receiver: .symbol("Authorizer"), method: "can")
    ], onPath: .namedFunctions("execute", ifEmpty: .skip))
}
```

`MustCall` and `MustCallAnyOf` default to `everyFunction(ifEmpty: .violate)` when `onPath` is omitted — prefer `namedFunctions` or `matchingFunctions` with `ifEmpty: .skip` for named entry points.

## Error Handling

```swift
Rule(id: "store_catch_cancellation") {
    MustHandleError(
        target: .case("cancelled"),
        as: .through,
        onPath: .everyCatch(ifEmpty: .violate)
    )
}
.scope(
    include: ["**/Domain/Store/*Store.swift"]
)
.message("Store catch blocks must ignore cancelled via control-flow exit.")
.severity(.error)
```

`.through` requires the target case branch to exit via `return`, `break`, or `continue` (not `guard case … else { return }` on the non-target side).

## Typed Throws

Literal typed-throws type name only (e.g. `throws(AppError)` in source):

```swift
Rule(id: "api_run_throws_app_error") {
    MustThrow(type: "AppError", onPath: .namedFunctions("run", ifEmpty: .skip))
}
.scope(include: ["**/API/**/*.swift"])
.message("API run() must declare throws(AppError).")
.severity(.error)
```

Untyped `throws`, `throws(any Error)`, and `typealias`-dependent types are not matched.

## Paired Calls

```swift
Rule(id: "transaction_pair") {
    WhenCalls(receiver: .symbol("DB"), method: "beginTransaction")
        .mustAlsoCallAnyOf([
            RuleCall(receiver: .symbol("DB"), method: "commit"),
            RuleCall(receiver: .symbol("DB"), method: "rollback"),
        ])
}
.scope(include: ["**/Database*.swift"])
.message("Transactions must end with commit() or rollback().")
.severity(.error)
```

By default, `WhenCalls` checks follow-ups in the **same function** as the trigger.

## Adopting to an existing project

Install both skills (Cursor, global). Run **one command per skill** (do not combine multiple `-s` flags):

```bash
npx skills add novr/Rin -s rin-dsl-rinfile -g -a cursor -y
npx skills add novr/Rin -s rin-dsl-rule-extraction -g -a cursor -y
```

- `rin-dsl-rinfile`: applied automatically when writing or editing `Rinfile.swift`
- Invoke rule extraction: `/rin-dsl-rule-extraction`

Skill references:

- [skills/rin-dsl-rinfile/SKILL.md](skills/rin-dsl-rinfile/SKILL.md) — DSL semantics and Rinfile authoring
- [skills/rin-dsl-rule-extraction/SKILL.md](skills/rin-dsl-rule-extraction/SKILL.md) — project rule extraction

## CLI

```bash
rinter [--config <path>] [--rule <id>] [-a|--all-files] [--format text|json] [--verbose]
```

- `-c`, `--config`: path to `Rinfile.swift` (default: `Rinfile.swift`)
- `-r`, `--rule`: evaluate only the specified rule id
- `-a`, `--all-files`: evaluate all Swift files under project root (not just git diff)
- `--format`: output format — `text` (default) prints human-readable messages; `json` prints a violations array to stdout (`[]` on pass)
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
          RINTER_VERSION: "v0.0.9"
        run: |
          curl -LO "https://github.com/novr/Rin/releases/download/${RINTER_VERSION}/rinter_${RINTER_VERSION#v}_darwin.tar.gz"
          curl -LO "https://github.com/novr/Rin/releases/download/${RINTER_VERSION}/checksums.txt"
          shasum -a 256 -c checksums.txt
          tar -xzf "rinter_${RINTER_VERSION#v}_darwin.tar.gz"
          chmod +x ./rinter
      - run: ./rinter --config Rinfile.swift
```

## How It Works

- Parse `Rinfile.swift` with SwiftSyntax.
- Collect changed Swift files from git diff (or all files with `--all-files`).
- Evaluate each rule **per unit** (function, `catch`, or trigger call) using `onPath` scopes.
- Predicates: `MustCall`, `MustCallAnyOf`, `MustHandleError`, `WhenCalls`, `MustDeclare`, `MustThrow`, `WhenCalls(name:)`.
- Exit non-zero on violations or runtime errors (`0` pass, `1` violations, `2` errors).

## Limitations

- File-local AST evaluation only
- Receiver matching is syntax-based (`.symbol("name")` matches base identifier exactly)
- Co-occurrence checks do not guarantee call order or 1:1 pairing
- Helper delegation (calls moved to private helpers) is not detected
- `deinit` and `subscript` are not attached to function scope metadata

Details: [skills/rin-dsl-rinfile/SKILL.md](skills/rin-dsl-rinfile/SKILL.md#limitations)

## Special Thanks

Special thanks to [fuwasegu/guardrail](https://github.com/fuwasegu/guardrail).

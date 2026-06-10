# Rin (Rinter)

Rinter is a semantic policy CLI for Swift projects.  
It reads `Rinfile.swift`, evaluates changed Swift code with deterministic SwiftSyntax AST checks, and fail-closes on runtime errors.

## Problem

- Missed required calls (authorization, logging, transaction cleanup) are hard to catch in review.
- Rinter enforces these rules with static AST checks and fails CI when violations are found.

## Installation

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
            MustCall(
                RuleCallTarget("Analytics", "sendScreen")
            )
        }
        .message("ViewModel entry flows must send screen analytics.")
        .severity(.error)
    }
}
```

2. Run:

```bash
./bin/rinter
```

3. Example output:

```text
❌ Semantic policy violation(s) found.
Features/Home/HomeViewModel.swift:42:13: [viewmodel_tracks_screen]
Required call `[Analytics, sendScreen]` was not found.
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
            MustCall(
                RuleCallTarget("Analytics", "sendScreen")
            )
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
    MustCall(
        RuleCallTarget("Analytics", "sendScreen")
    )
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
    MustCall(
        RuleCallTarget("Authorizer", "authorize")
    )
}

Rule(id: "authorization_any") {
    MustCallAnyOf([
        RuleCallTarget("Authorizer", "authorize"),
        RuleCallTarget("Authorizer", "can")
    ])
}
```

## Paired Calls

```swift
Rule(id: "transaction_pair") {
    WhenCalls(
        RuleCallTarget("DB", "beginTransaction"),
        mustAlsoCall: [
            RuleCallTarget("DB", "commit"),
            RuleCallTarget("DB", "rollback")
        ]
    )
}
.message("Transactions must end with commit() or rollback().")
.severity(.error)
```

## CLI

```bash
./.build/release/rinter [--config <path>] [--rule <id>] [-a|--all-files] [--verbose]
```

- `-c`, `--config`: path to `Rinfile.swift` (default: `Rinfile.swift`)
- `-r`, `--rule`: evaluate only the specified rule id
- `-a`, `--all-files`: evaluate all Swift files under project root (not just git diff)
- `-v`, `--verbose`: verbose logs during evaluation
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
      - run: swift build -c release
      - run: ./.build/release/rinter --config Rinfile.swift
```

## How It Works

- Parse `Rinfile.swift` with SwiftSyntax.
- Collect changed Swift files from git diff.
- Collect call sites in each file.
- Evaluate `MustCall`, `MustCallAnyOf`, and `WhenCalls`.
- Exit non-zero on violations or runtime errors.

## Limitations

- File-local AST evaluation only.
- Receiver matching is syntax-based (`Type.method`).
- Scope control is path-based (`Target` and `Rule.scope`).

## Special Thanks

Special thanks to [fuwasegu/guardrail](https://github.com/fuwasegu/guardrail).

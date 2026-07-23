---
name: rin-dsl-rinfile
description: Guides Rinfile.swift and Rinter DSL authoring. Use when writing or editing Rinfile.swift, Rinter rules, onPath scopes, or predicates such as MustCall, MustThrow, WhenCalls, or MustHandleError. Not for generic Swift editing.
---

# Rin DSL Rinfile Authoring

Write and revise `Rinfile.swift` using the current Rin (Rinter) DSL. Do not invent predicates that do not exist.

Contributor constraints: [AGENTS.md](https://github.com/novr/Rin/blob/main/AGENTS.md). DSL API: [RinterConfigDSL.swift](https://github.com/novr/Rin/blob/main/Sources/RinCore/RinterConfigDSL.swift). Quick Start examples: [README.md](https://github.com/novr/Rin/blob/main/README.md).

## Predicates

- `MustCall(receiver:method:, onPath:)` — per function (default `everyFunction`)
- `MustCallAnyOf([...], onPath:)` — per function
- `WhenCalls(receiver:method:, onPath: .sameFunction|.entireFile).mustAlsoCall(...)` — AND
- `WhenCalls(...).mustAlsoCallAnyOf([...])` — OR
- `MustHandleError(target:, as:, onPath:, whenUnmentioned:)` — per catch
- `MustDeclare(..., onPath:)` — per function
- `MustThrow(type:, onPath:)` — per function; **literal** typed-throws only (e.g. `throws(AppError)`). Plain `throws`, no `throws`, and non-literal forms are **skipped**
- `WhenCalls(name:).inArgument(...).mustUse(...)` — per matching creation; `.mustNotUse(...)` is optional but `mustUse` is required (`.mustNotUse`-only chains are rejected)
- `Target` / `Rule.scope` — **file** globs only (`*`, `**`, `?`; `?` matches one path segment character)

## `Rule.scope` vs `onPath`

| Layer | Use | Example |
|-------|-----|---------|
| Files | `Target`, `Rule.scope` | `**/*ViewModel.swift` |
| Functions / catch in file | `onPath` on predicate | `.namedFunctions("load", ifEmpty: .skip)` |
| Function name pattern | `onPath: .matchingFunctions(...)` | `.suffix("ViewModel")` — **not** file suffix |

`onPath` is declared on the predicate itself, not chained afterward.

`matchingFunctions(.suffix("ViewModel"))` does **not** mean `*ViewModel.swift` files.

## Evaluation model

| Predicate | Unit | Default `onPath` |
|-----------|------|------------------|
| `MustCall` / `MustCallAnyOf` / `MustDeclare` / `MustThrow` | Each `FunctionDecl` | `everyFunction(ifEmpty: .violate)` |
| `MustHandleError` | Each `catch` | `everyCatch(ifEmpty: .violate)` |
| `WhenCalls` + follow-ups | Each trigger | `sameFunction` |
| `WhenCalls(name:)` | Each matching creation | creation's function |

`onPath` variants: `everyFunction`, `namedFunctions`, `matchingFunctions`, `everyCatch`, `namedFunctionCatches`; follow-ups: `sameFunction` (default) or `entireFile`.

- `.mustAlsoCall` = AND; `.mustAlsoCallAnyOf` = OR (commit/rollback)
- `MustHandleError`: `.through` requires target branch to exit via `return` / `break` / `continue`
- Receiver: `Analytics.foo()` → `.symbol("Analytics")`; `deps.analytics.foo()` → `needs_code_convention_change` (use a direct base identifier or refactor call sites)

### Authoring defaults

1. Prefer `namedFunctions` / `matchingFunctions` with `ifEmpty: .skip` over bare `everyFunction`.
2. Narrow `Rule.scope` before widening `onPath`.
3. Use `everyFunction` only when **all** functions in scoped files must comply.

## Limitations

- File-local AST only; syntax-based receiver matching
- No call order / 1:1 pairing guarantee; helper delegation not detected
- `deinit` / `subscript` excluded from function scope metadata
- No import rules, access control, cross-file resolution, or type inference / `typealias`
- Untyped `throws`, no `throws` clause, `throws(any Error)`, and `typealias`-dependent typed throws are **skipped** by `MustThrow` (not violations). Only a present literal typed-throws name is compared; mismatch → violation

## Pattern catalog

| Pattern | `Rule.scope` | `onPath` / shape |
|---------|--------------|------------------|
| `load()` must call analytics | files containing the type | `UnitPathScope.namedFunctions("load", ifEmpty: .skip)` |
| Transaction close | DB-related files | `mustAlsoCallAnyOf([commit, rollback])` |
| Typed throws | API layer files | `MustThrow(type: "AppError", onPath: UnitPathScope.namedFunctions("run", ifEmpty: .skip))` |
| Cross-function cleanup | relevant files | `onPath: .entireFile` on `WhenCalls` |

### `MustDeclare` + `WhenCalls(name:)`

```swift
MustDeclare(.local(binding: LocalBindingConstraint(
    identifier: "performer",
    typePattern: .anyConformance("ActionPerformer"),
    initializerIdentifier: "store"
)), onPath: UnitPathScope.namedFunctions("makeWitness", ifEmpty: .skip))
WhenCalls(name: .suffix("Witness"))
    .inArgument(argumentLabel: "performer")
    .mustUse(identifier: "performer")
    .mustNotUse(identifier: "store")
```

When both `mustUse` and `mustNotUse` are set, a violating argument reports **one** violation; `mustNotUse` takes precedence when the identifier matches the forbidden name.

## Convention → `onPath`

| Convention wording | Suggested `onPath` |
|--------------------|-------------------|
| "`load()` must …" | `.namedFunctions("load", ifEmpty: .skip)` |
| "every function in …" | `.everyFunction()` + narrow `Rule.scope` |
| "in `catch` …" | `.everyCatch()` or `.namedFunctionCatches(...)` |
| "when calling X, must also Y" | `WhenCalls` + `mustAlsoCall` / `mustAlsoCallAnyOf` |
| "files named *Foo.swift" | `Rule.scope`, not `matchingFunctions` |

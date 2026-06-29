---
name: rin-dsl-rule-extraction
description: Explores a Swift project and extracts project-specific Rin (Rinter) DSL rule candidates verifiable by current AST predicates. Use only when the user explicitly invokes /rin-dsl-rule-extraction or asks for Rin rule extraction from a PROJECT_ROOT.
disable-model-invocation: true
---

# Rin DSL Rule Extraction

Extract **project-specific** rules expressible by the current Rin DSL. Prefer conventions found in the target codebase. Do not invent predicates that do not exist.

Invoke only via `/rin-dsl-rule-extraction` or `@rin-dsl-rule-extraction`.

Contributor constraints: [AGENTS.md](https://github.com/novr/Rin/blob/main/AGENTS.md). DSL API: [RinterConfigDSL.swift](https://github.com/novr/Rin/blob/main/Sources/RinCore/RinterConfigDSL.swift).

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
- Receiver: `Analytics.foo()` → `.symbol("Analytics")`; `deps.analytics.foo()` → `needs_code_convention_change`

### Limitations

- File-local AST only; syntax-based receiver matching
- No call order / 1:1 pairing guarantee; helper delegation not detected
- `deinit` / `subscript` excluded from function scope metadata
- No import rules, access control, cross-file resolution, or type inference / `typealias`

## Extraction defaults

1. Prefer `namedFunctions` / `matchingFunctions` with `ifEmpty: .skip` over `everyFunction`.
2. Narrow `Rule.scope` before widening `onPath`.
3. Use `everyFunction` only when evidence shows **all** functions in scoped files must comply.
4. Each candidate needs path + line or function name; prefer 2+ files or a doc citation.
5. Tune after `rinter_validation`.

## Workflow

```
Task Progress:
- [ ] Resolve PROJECT_ROOT
- [ ] Omnidirectional survey (layout, naming, entry points, catch handling, existing Rinfile.swift)
- [ ] Map conventions → Rule.scope (files) + onPath (units)
- [ ] Emit draft_rinfile with project-specific identifiers
- [ ] Run rinter validation (mandatory)
- [ ] Report tuning (scope, ifEmpty, rule splits)
```

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

## Project-path prompt

Replace `<<<PROJECT_ROOT>>>`.

````markdown
# Rin DSL rule extraction (project path)

Survey the project and extract **project-specific** rule candidates verifiable by the **current Rin (Rinter) DSL**.

## Target project

- PROJECT_ROOT: `<<<PROJECT_ROOT>>>`
- Depth: `quick` | `standard` (default) | `thorough`

## Current DSL

- `MustCall(receiver:method:, onPath:)` — per function (default `everyFunction`)
- `MustCallAnyOf([...], onPath:)` — per function
- `WhenCalls(receiver:method:, onPath: .sameFunction|.entireFile).mustAlsoCall(...)` — AND
- `WhenCalls(...).mustAlsoCallAnyOf([...])` — OR
- `MustHandleError(target:, as:, onPath:, whenUnmentioned:)` — per catch
- `MustDeclare(..., onPath:)` — per function
- `MustThrow(type:, onPath:)` — per function; **literal** typed-throws type name only (e.g. `throws(AppError)`)
- `WhenCalls(name:).inArgument(...).mustUse(...).mustNotUse(...)` — per matching creation
- `Target` / `Rule.scope` — **file** globs only

## Scope split (required)

- **Files** → `Rule.scope` / `Target`
- **Functions / catch inside files** → `onPath` on predicate
- `matchingFunctions` matches **function names**, not file names

## Extraction defaults

Prefer `namedFunctions` / `matchingFunctions` with `ifEmpty: .skip` over bare `everyFunction`.

## Evidence rules

- Each candidate needs **evidence**: path + line or function name (prefer 2+ files or doc citation).
- Use project-specific identifiers in `dsl_body`, not placeholders.

## Output

`project_summary`, `applicable_rules` (with `verification_sample` OK/NG), `needs_code_convention_change`, `out_of_scope`, `draft_rinfile`, `rinter_validation`.

**Not supported (`out_of_scope`):** import rules, access control, SwiftUI-specific, cross-file resolution, type inference / `typealias`, untyped `throws`, `throws(any Error)`, return/parameter type signatures, call order / 1:1 pairing, helper delegation.

## Self-check

- [ ] `Rule.scope` vs `onPath` correct
- [ ] Narrow `onPath` preferred
- [ ] `mustAlsoCallAnyOf` for OR pairs
- [ ] `rinter_validation` completed
````

## Manual-input prompt

| Convention wording | Suggested `onPath` |
|--------------------|-------------------|
| "`load()` must …" | `.namedFunctions("load", ifEmpty: .skip)` |
| "every function in …" | `.everyFunction()` + narrow `Rule.scope` |
| "in `catch` …" | `.everyCatch()` or `.namedFunctionCatches(...)` |
| "when calling X, must also Y" | `WhenCalls` + `mustAlsoCall` / `mustAlsoCallAnyOf` |
| "files named *Foo.swift" | `Rule.scope`, not `matchingFunctions` |

Same output sections as project-path mode.

## rinter_validation (mandatory)

```bash
cd PROJECT_ROOT && rinter --config Rinfile.swift --all-files
```

If `rinter` is missing, state the blocker and how to install (Homebrew / release binary / `swift build`).

Report: `exit_code`, `violation_count`, `runtime_errors`, `false_positive_candidates`, `missing_coverage`, `recommended_tuning`.

Exit codes: `0` pass, `1` violations, `2` errors. Do not finish without validation or a stated blocker.

## Quality checklist

- [ ] `Rule.scope` vs `onPath` correct
- [ ] Narrow `onPath` preferred
- [ ] Evidence on every candidate
- [ ] `mustAlsoCallAnyOf` for OR pairs
- [ ] `rinter_validation` with tuning notes

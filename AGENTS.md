# AGENTS.md

## Target Audience
This document is a strict runtime instruction for AI code generation agents and a baseline for human PR reviewers.
Every change must satisfy both the underlying Why and the non-negotiable What/What Not.

## Intent
This document preserves decision intent, not implementation trivia.
When uncertain, prioritize long-term rule clarity, deterministic behavior, and reviewer trust.

---

## Why & Non-Negotiable Rules

### 1. Why This Project Exists
- Policy regressions are expensive because they often pass compilation and surface late.
- Static, deterministic checks reduce review variance and make failures explainable.
- The tool should make architecture rules explicit so teams share the same mental model.

### 2. Why Rules Must Stay Explicit
- A rule name should communicate intent without requiring source dives.
- Each rule should enforce one architectural contract to avoid ambiguous pass/fail outcomes.
- Scope should stay unsurprising so policy adoption remains low-friction.

### 3. Why Analysis Must Be Structural
- Structural analysis is resilient to formatting and stylistic churn.
- Semantics must not depend on incidental text shape.
- Predictable diagnostics are more important than permissive matching.
- Here, "rule semantics" means rule extraction, condition matching, and violation decision logic.
- MUST NOT: Use `NSRegularExpression`, Swift `Regex`, or ad-hoc string slicing to implement rule semantics.
- MUST: Keep both DSL decoding (`Rinfile.swift`) and evaluator-side detection on AST walking (`SwiftSyntax` / `SwiftParser`).
- MUST NOT: Add rules that cannot be implemented structurally with AST.

### 4. Why Fail-Closed
- Silent success is riskier than explicit failure for policy tooling.
- Uncertain parsing or evaluation should stop the run so results remain trustworthy.
- MUST NOT: Implement warning-only fallbacks that still exit with `0`.
- MUST: Keep the exit-code contract strict (`0` pass, `1` policy violations, `2` runtime/config/parser errors).

---

## Operational Constraints
- Prefer minimal, intention-preserving evolution over broad feature expansion.
- Add DSL/API surface only when it clarifies intent, not just expressiveness.
- MUST NOT: Introduce runtime dependencies that risk cross-platform portability.

## Quality Gate
Before proposing completion or PR readiness, verify:
1. Local execution path works (`swift run rinter`).
2. Deterministic tests cover changed behavior, including exit-code contract (`0`, `1`, `2`) where relevant.
3. If a change touches DSL decoding or evaluator semantics, tests for both sides must be updated or confirmed.

## Enforcement
- Violations of non-negotiable rules are reject reasons for PR review.

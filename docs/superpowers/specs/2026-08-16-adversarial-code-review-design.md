# Adversarial repository review skill

## Goal

Provide a reusable, repository-local skill that examines any DevSpace artifact
or change with a defect-seeking posture. It reports every credible concern,
while making issues that could cause real user, data, security, or release
failures impossible to miss.

## Design

Create `.agents/skills/adversarial-code-review/SKILL.md` as a self-contained
process skill. Its discovery description will cover code review, implementation
plans, design documents, tests, build/release changes, and operational
documentation in this repository.

The skill will require a review to begin by establishing the intended scope
and inspecting the relevant diff, surrounding code, tests, instructions, and
recent history. It will review in these layers:

1. Scope, requirements, design, and documentation consistency.
2. Swift/SwiftUI state and lifecycle correctness, including async/concurrency
   and resource cleanup.
3. DevSpace-specific integration boundaries: DevPod CLI calls, PTY/terminal
   ownership, SSH/tunnels, notification routing, and command/input safety.
4. Test coverage, failure behavior, and build/runtime validation.
5. macOS operational and repository rules, including the strict separation of
   the development and daily-driver release bundles.

Findings will have a fixed evidence-based shape: severity, title, evidence
(file and line when applicable), failure mode/impact, and a practical fix or
follow-up. They will be sorted `Critical`, `High`, `Medium`, `Low`, followed
by clearly labeled questions and assumptions. A review that finds no defects
will state residual risks and validation gaps rather than inventing findings.

## Severity policy

Critical and High are reserved for plausible defects that could compromise
security, lose/corrupt state, break key workspace or terminal behavior,
misroute sensitive notifications, ship a broken app, or disrupt the user's
running release bundle. Medium and Low capture credible correctness,
maintainability, documentation, and consistency concerns. Report every
credible concern, but do not use severity inflation.

## Validation

Before authoring the skill, establish a baseline with pressure scenarios that
tempt an unguided reviewer to overlook a release-safety rule, a cross-layer
PTY/SSH lifecycle failure, and a mismatch between a stated requirement and its
tests. Author the smallest skill that closes observed gaps, then repeat those
scenarios with the skill loaded. Finally, check frontmatter/discovery wording,
the report contract, repository-specific constraints, and the skill's length.

## Constraints

The skill is guidance only: it must not itself change code, run destructive
commands, commit, push, build a release bundle, or stop `DevSpace.app`.
Reviews must distinguish verified defects from hypotheses and must honor the
repository's existing `AGENTS.md` instructions.

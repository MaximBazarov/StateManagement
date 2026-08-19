# Changelog

All notable changes to StateManagement are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Pre-1.0, expect breaking changes between minor versions.

## [Unreleased]

### Changed

- Telemetry is now off by default ([ADR 0012](docs/adr/0012-Telemetry.md)). Turn it on with the `Telemetry` (user spans) or `TelemetryInternal` (state mutation) SwiftPM package traits. When off, every telemetry call site compiles away to nothing, so production pays no runtime cost. This is a behavior change for anyone who relied on the always-on default, not a source break.
- A `Set` span names the key path only, the state value is gone. This removes a privacy leak (the raw value reached every event consumer) and the per-set `String(describing:)` cost.

### Added

- `SharedEnvironment.read` snapshots a Value without subscribing. A Combine object, or any caller outside a Container, can read `.shared` this way.
- Every async Operation declares `reentrancy`. `runAll` lets overlapping Executions proceed. `firstWins` Joins the live Execution of an Identity. `newestWins` Cancels the previous live Execution and moves awaiters onto the new one. Cancel is Task cancellation plus a Sync write door ([ADR 0002](docs/adr/0002-AsyncOperation.md)).
- `TraceContext.log(_:)` records a developer note against the current operation span. Outside a span it does nothing.
- `TelemetryEvent.Kind.log` for the note event. It carries no duration and breaks an exhaustive switch over `Kind`, acceptable pre-1.0.

### Changed

- `AsyncOperation` requires `reentrancy`. There is no default. Breaking, acceptable pre-1.0.

### Fixed

- `withSpan` no longer does work when telemetry is off. Both overloads were unguarded, so even with both flags off they ran `TraceID.generate()`, allocated a `Span`, and bound a task-local on every operation and set.

## [0.0.2]

- Draft of most public APIs, testing support, and CI.

## [0.0.1]

- Initial draft.

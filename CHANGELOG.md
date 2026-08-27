# Changelog

All notable changes to StateManagement are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Pre-1.0, expect breaking changes between minor versions.

## [Unreleased]

### Added

- `AsyncOperationEnvironment` has awaitable `perform` for a non-throwing `AsyncOperation` child, matching `SharedEnvironment`. Fire-and-forget stays.

### Fixed

- A synchronous first read that kicks `onRead` is not a receiver of nested `apply` / `fail`. The body already has the applied Value. Other already-subscribed receivers still notify.
- Nested sync `perform` shares the original Operation. Observers see one notification with the final Value. Same-stack strategy inbound joins that round.
- `@Perform` sends `objectWillChange` only after that instance's `isInProgress` has been read. Dispatch-only views do not re-render on `begin()` / `end()`. The send still hops.

## [0.9.2] - 2026-08-25

### Added

- DEBUG `SharedEnvironment.seed { }` applies a Seed batch to an existing Environment. `seeded { }` stays the factory. `SeedBatch` stays internal.
- `AsyncStrategyEnvironment.environmentID` is the Environment identity a strategy is bound to. Satellites overlay Persistence identity by this key.
- Awaitable `read` of a `$` Address on `AsyncOperationEnvironment` and `EnvironmentService`. `refresh()` on `@AsyncState` and the `Watch` projection dirties and kicks `onRead`.

### Changed

- `Source` is `AsyncStrategy`. `provide` / `dropped` are `onRead` / `onDrop`. Persist-out is `onWrite`. No shim.
- `onRead`, `onWrite`, and `onDrop` take a Policy value stored on `@AsyncState`. Address still names the Value. Type-only `@AsyncState(SomeStrategy.self)` remains only when `Policy == Void`. May break `provide`. No shim.
- Labeled `AsyncState.init(wrappedValue:policy:)` is the designated init (`@_disfavoredOverload`). The app call site is unlabeled. A Satellite pins `S` by forwarding to it.

## [0.9.1] - 2026-08-20

### Fixed

- `Watch` and `@Perform` no longer send Combine `objectWillChange` during a SwiftUI view update. Invalidation hops to the next main run-loop turn in common modes. `notifyAll()` stays synchronous.

## [0.9.0] - 2026-08-19

First tagged pre-release. Experimental: the public API may still break before `1.0.0`. In-repo DocC only, no Swift Package Index docs until `1.0.0`.

This record is the whole library. One Environment owns all State, sliced into Containers; every Value has an Address. An Operation is the only change, and an async Operation declares its `reentrancy` (ADR 0002). Computed derives Values from other Values. Watch reads from SwiftUI, Service reacts outside it, a Source produces inbound Values, and Combine and `@SMPublished` bridge legacy call sites. Telemetry is off by default and compiles away unless the `Telemetry` or `TelemetryInternal` trait is on (ADR 0012). In-repo DocC catalogs for `StateManagement` and `StateManagementTestingSupport` walk the public API.

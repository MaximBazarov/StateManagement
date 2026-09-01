# Changelog

All notable changes to StateManagement are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Pre-1.0, expect breaking changes between minor versions.

## [Unreleased]

## [0.9.4] - 2026-09-01

### Changed

- `@AsyncState` is `AsyncState<S, Key, Entry, Value>`. Atomic is `Key == NoKey, Entry == Value`, Keyed is `Value == [Key: Entry]`, and a dictionary-typed declaration resolves Keyed. `Status` leaves the generic list. A Satellite that pins `S` with a `convenience init` constrains `Key`/`Entry` instead of `Status`, and disfavours the Atomic spelling. 0.9.x break, no shim.
- Strategy kicks (`onRead` / `onWrite` / `onDrop`) and inbound verbs (`apply` / `fail` / `markStale`) take the `$` Address first and unlabeled, with the payload last: `onWrite(address, policy:, value:)`, `apply(address, value:)`, `fail(address, error:)`. `0.9.3` moved these onto the `$` Address; this settles the order. No `value: Any` on the handle or `finishAppWrite`. Watch and Operations keep the Value Address. 0.9.x break, no shim.
- `preheat` takes the `$` Address too, so `preheat(\C.done)` no longer compiles. It had compiled and done nothing. Keyed `preheat`, `refresh`, and `markStale` take `keys: Set<Key>`, so a keyless keyed call does not compile either. This replaces the "Preheat stays Value-path" note in `0.9.3`.
- `SourceStatus` is `AsyncStateStatus`. The last `Source` name is gone.
- `NoKey` moves to `Core` and is the one spelling for both `Computed` and `AsyncState`.
- `remove` on a sourced keyed Address evicts rather than deletes: the entry goes back to `.pending`, nothing reaches the strategy, and the next read reloads it. A removal is a change to the Value and it must not escape.
- Reading a dictionary-typed sourced Address names the whole dictionary, which is never a seam Address, so it binds the wrapper and kicks nothing. Reading one entry of the same declaration kicks.

### Added

- `Sources/AsyncState/` is a scope of its own: the wrapper, `AsyncStrategy`, `AsyncStrategyEnvironment`, `AsyncStateRuntime`, and the `$`-Address counterparts carved out of `AsyncOperation`, `EnvironmentService`, and `Watch`. `SharedEnvironment` keeps one property into it.

### Removed

- `restoreSeed`. It had no caller in the library or in any Satellite strategy, and it left an Address `.pending` with a read already recorded, which no synchronous read could reload. Nothing replaces it.
- `SharedEnvironment.getValue` / `setValue` / `removeValue`, and the two `read` methods that only forwarded to `getValue`. The type that owns storage now spells them `read` / `write` / `remove`. Internal and test-facing only.

## [0.9.3] - 2026-08-31

### Changed

- `getValue` and `setValue` are gone from `EnvironmentService`, `ComputationEnvironment`, and the `Computed` service surface. The two verbs are `read` and `write` wherever the capability exists.
- `write` and `remove` take the Address first and unlabelled, and `read` no longer labels it `keyPath:`.
- `SharedEnvironment.read` is internal. Out-of-package callers read through `StateReader` in `StateManagementTestingSupport`.
- Strategy kicks (`onRead` / `onWrite` / `onDrop`) and inbound verbs (`apply` / `fail` / `restoreSeed` / `markStale`) take the `$` Address. Pin `Self` on kicks. No `value: Any` on the handle or `finishAppWrite`. Watch and Operations keep the Value Address. Preheat stays Value-path. 0.9.x break, no shim.

### Added

- `SyncOperationEnvironment` and `AsyncOperationEnvironment` read a `Computed`, atomic and keyed, by Address. An Operation does not subscribe; cache, dependency edges, and the cycle guard behave as for any other reader.
- `AsyncOperationEnvironment` has awaitable `perform` for a non-throwing `AsyncOperation` child, matching `SharedEnvironment`. Fire-and-forget stays.

### Removed

- A Service has no write hatch. The `setValue` family, including both `Computed` overloads, atomic and keyed-dictionary, and `ignoreNotificationsFor` are gone. A Service changes State only by performing an Operation, and a derivation is not swappable at runtime: declare it with `@Computed` and let an Operation write the Values it reads. 0.9.x break, no shim.
- A `Computed` cannot be written at all. Every write route refuses one, including a dictionary or array of them, so a Container can no longer hold a `Computed` no reader could evaluate.

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

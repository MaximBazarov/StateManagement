//===----------------------------------------------------------------------===//
//
// This source file is part of the StateManagement package open source project
//
// Copyright (c) 2025-2035 Maxim Bazarov and the StateManagement package
// open source project authors
// Licensed under MIT
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: MIT
//
//===----------------------------------------------------------------------===//

import Foundation

/// Spots a ``Computed`` behind a generic `Value`, so a write route can refuse one it could not
/// reject at compile time. See ADR 0023.
///
/// The conditional conformances carry the mark through a container, so a dictionary or array of
/// Computeds is refused as readily as a bare one.
protocol ComputedRefusesStorage {}

extension Dictionary: ComputedRefusesStorage where Value: ComputedRefusesStorage {}
extension Array: ComputedRefusesStorage where Element: ComputedRefusesStorage {}
extension Optional: ComputedRefusesStorage where Wrapped: ComputedRefusesStorage {}

/// The refusal every write route reports. The `@available` twins repeat these words as a literal,
/// because an attribute message cannot reference a constant.
let computedIsNotStorable = """
A Computed is derived, not stored. Declare it with @Computed and reach it through its Address \
(\\Container.$name).
"""

/// A value derived from other values, that is kept up to date automatically.
/// The function that derives the new value is provided with the ``ComputationEnvironment`` instance and whenever reads
/// other values registers as a `dependant` of them.
/// Whenever any of those values change, the value of the ``Computed`` is invalidated
/// and will be recalculated on the next read.
/// As other states in container, readers are notified when value changes.
///
/// > Note The result is cached. The closure runs on the first read, then the value is reused until invalidated.
/// Reading the same computed from many places in one update costs one computation.
///
/// > Important: A Computed is evaluable only through its Address, `\Container.$name`. A write route
/// refuses one, and an instance held any other way — a local, or a stored property inside a
/// Container — has no way to be evaluated.
///
/// > Warning: A derivation that reads its own Address, directly or around a chain, traps
/// (`fatalError`). The cycle cannot be broken at runtime because the read is what would supply the
/// value it is waiting for.
///
/// In the following example `count` recomputes when `items` change; `isDone`
/// recomputes when that id's `done` flag changes.
/// ```swift
/// final class ListContainer: StateContainer {
///     var items: [UUID] = []
///     var done: [UUID: Bool] = [:]
///
///     // Atomic computed: equal to the count of the items.
///     @Computed var count = { env in
///         env.read(\ListContainer.items).count
///     }
///
///     // Keyed computed: derived per item id.
///     @Computed<UUID, Bool> var isDone = { env, id in
///         env.read(\ListContainer.done, key: id) ?? false
///     }
/// }
/// ```
///
@propertyWrapper
@MainActor public final class Computed<Key: Hashable, Output> {

    // MARK: - Property Wrapper

    /// Computation closure produces the value from the state it reads, for a given key.
    /// An atomic computed (`Key == NoKey`).
    public let wrappedValue: (ComputationEnvironment, Key) -> Output

    public var projectedValue: Computed<Key, Output> { self }

    // MARK: - Cache

    /// Cached outputs, one entry per key. An atomic computed (`Key == NoKey`)
    /// holds at most one entry, under ``NoKey/noKey``.
    private var cache: [Key: Output] = [:]

    // MARK: - Init

    /// Computation takes a key as its second parameter, deriving a value per key.
    public init(wrappedValue: @escaping (ComputationEnvironment, Key) -> Output) {
        self.wrappedValue = wrappedValue
    }

    /// Computation takes only the environment, no key.
    public init(wrappedValue: @escaping (ComputationEnvironment) -> Output) where Key == NoKey {
        self.wrappedValue = { env, _ in wrappedValue(env) }
    }

    // MARK: - Read

    /// The single way any computed value is read, by ``Watch``, by ``EnvironmentService``, and by
    /// other computeds (atomic and keyed alike). Serves the cache first: returns the stored output
    /// if present, otherwise runs the closure once, stores the result, and returns it. Then
    /// subscribes `receiver` so the consumer is notified of later changes.
    /// The closure re-registers its dependency edges and installs the hook that clears this cache
    /// entry when an input changes, so a later cache hit is safe — it only happens while those
    /// edges still hold.
    ///
    /// A `nil` `receiver` reads without subscribing. An Operation reads that way: it is a
    /// first-class reader, so the cache and the dependency edges behave exactly as for any other
    /// consumer, and only the subscription is withheld (ADR 0023).
    ///
    /// `evaluating` is the history of computeds currently mid-read, threaded down the recursion
    /// (top-level callers rely on the default). If this `valueID` is already in that history, the
    /// closure is about to read itself — a dependency cycle: the chain is reported through telemetry
    /// and then trapped. A cache hit returns before the check, so it can never recurse. See ADR 0004
    /// (composition) and ADR 0014 (cycle guard).
    /// Subscribe after the Value is in hand so nested inbound during `onRead` does not notify this reader.
    @_documentation(visibility: private)
    func read(
        env: SharedEnvironment,
        valueID: ValueID,
        receiver: NotificationReceiver?,
        key: Key,
        evaluating: [ValueID] = []
    ) -> Output {
        if let cached = cache[key] {
            subscribe(receiver, to: valueID, in: env)
            return cached
        }

        if let start = evaluating.firstIndex(of: valueID) {
            let cycle = (evaluating[start...] + [valueID])
                .map(\.debugDescription)
                .joined(separator: " → ")
            let message = "Computed dependency cycle: \(cycle)"
            TraceContext.log(message)   // report (telemetry channel, best-effort)
            fatalError(message)         // trap (always-on guarantee)
        }

        let dependent = Dependent(id: valueID) { [weak self] in
            self?.cache[key] = nil
        }
        let compEnv = ComputationEnvironment(
            env: env,
            notificationReceiver: receiver,
            dependent: dependent,
            evaluating: evaluating + [valueID]
        )
        let value = wrappedValue(compEnv, key)
        cache[key] = value
        subscribe(receiver, to: valueID, in: env)
        return value
    }

    private func subscribe(
        _ receiver: NotificationReceiver?,
        to valueID: ValueID,
        in env: SharedEnvironment
    ) {
        guard let receiver else { return }
        env.observation.subscribe(receiver: receiver, valueID: valueID)
    }
}

extension Computed: ComputedRefusesStorage {}

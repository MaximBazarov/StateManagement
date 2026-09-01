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

/// A base class for services that respond to state changes within a shared environment.
///
/// Services managed by a SharedEnvironment must override ``serve()`` to perform work when their dependencies update. The environment calls this method whenever a value previously read by the service changes.
///
/// The service is a reliable latest-wins reactor. Contract:
/// - Latest-wins: a follow-up run always reads the current state, so the final change is never lost.
/// - Single-flight: one ``serve()`` run at a time, never overlapping. Changes during a run coalesce.
/// - Finish-then-follow: a running ``serve()`` completes, then follows the latest if a change arrived. It is never cancelled mid-run, so side effects stay whole.
/// - Re-subscribes itself: after each run the service re-registers on its inputs, so it keeps reacting to the latest state without re-reading.
///
/// > Important: A Service changes State only by performing an Operation, and it hears that change
/// like any other reader. Performing an Operation that writes a Value this Service also reads is a
/// loop. Either do not read what that Operation writes, or carry a guard that knows the write
/// already happened — a one-shot flag, or ``isSetup`` when only the first run writes. `wasUpdated`
/// is not that guard: it says a Value changed, not who changed it, so it is still true on the
/// notify this Service caused.
///
/// > Note: Subscriptions are one-shot. A Service re-subscribes itself after each run, so it keeps
/// reacting without re-reading. See <doc:Observing-State>.
///
/// ## Example
/// ```swift
/// struct SetTitle: SyncOperation {
///     let title: String
///     func perform(in env: SyncOperationEnvironment) {
///         env.write(\Document.title, value: title)
///     }
/// }
///
/// final class TitleSyncService: EnvironmentService {
///
///     override func serve() async {
///         guard !isSetup else {
///             // Optional step if we need a separate setup
///             return await setup()
///         }
///         // `slug` is read, `title` is written, so this Operation cannot retrigger the Service.
///         let slug = read(\Document.slug)
///         try? perform(SetTitle(title: slug.capitalized))
///     }
///
///     func setup() async {
///         // Do necessary instantiations and preparations
///         // Read values that we are interested in,
///         // otherwise environment won't know what to notify about.
///         _ = read(\Document.slug)
///     }
/// }
/// ```
///
/// - `init` must not have side-effects,
/// - use `setup` method for subscription and initial setup.
@MainActor open class EnvironmentService {

    /// Environment
    internal let env: SharedEnvironment

    static func id() -> ObjectIdentifier {
        ObjectIdentifier(type(of: Self.self))
    }

    /// Creates a service and saves the provided environment as its environment.
    public required init(env: SharedEnvironment) {
        self.env = env
    }

    /// Dropped by `reset()`. Remaining `serve()` may finish; writes do not land.
    internal var isDropped = false

    /// True while a ``serve()`` run is in flight. Guards single-flight: a change that arrives now
    /// coalesces instead of starting a second run.
    internal var isServing: Bool = false

    /// A relevant change arrived while serving. This mark is held across the `Task` hop, so the
    /// final change is never lost. When set, the serving loop runs one more time.
    internal var hasPendingWork: Bool = false

    /// Changed IDs that arrived while serving, waiting for the next run to read them.
    /// Handed to ``updatedValues`` at the top of each iteration, so a run always sees the latest set.
    internal var pendingValues: Set<ValueID> = []

    /// Returns true if the `serve` was called after the service initialization.
    public var isSetup: Bool {
        updatedValues == []
    }

    /// Override this function to define what to do when values you read were updated.
    /// Similar to SwiftUI View body, but instead of drawing service does its job based on the current state of values.
    ///
    /// > Important: Always will be called once after the service initialisation.
    /// If you need to know whether the `serve` was called after the initialisation or after the updates check ``isSetup``
    open func serve() async {

    }

    /// Contains value IDs updated during the last operation.
    /// Flushed after ``serve()``.
    internal var updatedValues: Set<ValueID> = []

    /// Runs synchronously inside `notifyAll()`. Coalesces to the latest and never starts a second run.
    lazy var notificationReceiver = NotificationReceiver {
        [weak self] updatedValueIDs in
        guard let self, !self.isDropped else { return }

        guard !updatedValueIDs.isEmpty else { return }

        // Accumulate. Two coalesced notifications union, they never overwrite each other.
        self.pendingValues.formUnion(updatedValueIDs)

        // A run is already in flight, mark it and let that run follow the latest.
        guard !self.isServing else {
            self.hasPendingWork = true
            return
        }

        self.startServing()
    }

    /// One `Task`, finish-then-follow. Every run completes, then follows the latest if a change arrived.
    ///
    /// We do not cancel and restart. ``serve()`` does side effects, and Swift cancellation is
    /// cooperative, so a cancelled run can still finish last. Finishing every run keeps side effects
    /// whole and keeps latest-wins.
    func startServing() {
        guard !isDropped else { return }
        isServing = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.isDropped {
                self.isServing = false
                return
            }
            repeat {
                self.hasPendingWork = false
                // Hand the accumulated changes to this run, so `wasUpdated` and `serve()` see them.
                self.updatedValues = self.pendingValues
                self.pendingValues = []
                await self.serve()
                // Staying subscribed is automatic, re-register on the inputs after every run.
                if self.isDropped { break }
                self.resubscribe()
            } while self.hasPendingWork && !self.isDropped
            self.isServing = false
        }
    }

    /// Resubscribe to the values.
    /// We need to do it because of the observation auto subscription cleanup.
    /// Every time the value is consumed, receiver is unsubscribed from further updates of the value.
    func resubscribe() {
        updatedValues.forEach { valueID in
            env.observation.subscribe(
                receiver: notificationReceiver,
                valueID: valueID
            )
        }
    }

    // MARK: - I/O -

    /// Forwards to the Environment so throw, notify, and the span stay one path.
    public func perform<Op: ThrowingSyncOperation>(
        _ operation: Op,
        file: String = #fileID,
        line: UInt = #line
    ) throws(Op.Failure) {
        guard !isDropped else { return }
        try env.perform(operation, file: file, line: line)
    }

    public func wasUpdated<Storage: StateContainer, Value>(
        _ valueKeyPath: KeyPath<Storage, Value>
    ) -> Bool {
        updatedValues.contains(ValueID(keyPath: valueKeyPath))
    }

    public func wasUpdated<Storage: StateContainer, Value>(
        _ valueKeyPaths: [KeyPath<Storage, Value>]
    ) -> Bool {
        valueKeyPaths.contains { keyPath in
            updatedValues.contains(ValueID(keyPath: keyPath))
        }
    }

    /// Reads a Value and subscribes, so a change to it schedules the next ``serve()``.
    /// - Parameter keyPath: path to the value e.g. `\MyState.myValue`.
    // `Value` is unconstrained, so a `$` Address satisfies this overload with
    // `Value == AsyncState<…>`. Disfavoured so `read(\C.$value)` reaches the awaitable read below
    // instead of handing back the wrapper (ADR 0024).
    @_disfavoredOverload
    public func read<Storage: StateContainer, Value>(
        _ keyPath: KeyPath<Storage, Value>
    ) -> Value {
        // A dropped Service must not recreate a Container by reading.
        guard !isDropped else { return Storage()[keyPath: keyPath] }
        let value = env.read(keyPath)
        env.observation.subscribe(
            receiver: notificationReceiver,
            valueID: ValueID(keyPath: keyPath)
        )
        return value
    }

    /// Reads the whole dictionary and subscribes to it. That Address names a whole fact and never
    /// kicks a strategy; reading one entry of the same declaration does (ADR 0026).
    public func read<Storage: StateContainer, Key: Hashable, Value>(
        _ keyPath: KeyPath<Storage, [Key: Value]>
    ) -> [Key: Value] {
        // A dropped Service must not recreate a Container by reading.
        guard !isDropped else { return Storage()[keyPath: keyPath] }
        let value = env.read(keyPath)
        env.observation.subscribe(
            receiver: notificationReceiver,
            valueID: ValueID(keyPath: keyPath)
        )
        return value
    }

    /// Reads a Keyed value and subscribes to that key.
    ///   - keyPath: path to the value e.g. `\MyState.myValue`.
    ///   - key: dictionary key of the value.
    public func read<Storage: StateContainer, Key: Hashable, Value>(
        _ keyPath: KeyPath<Storage, [Key: Value]>,
        key: Key
    ) -> Value? {
        // A dropped Service must not recreate a Container by reading.
        guard !isDropped else { return Storage()[keyPath: keyPath][key] }
        let value = env.read(keyPath, key: key)
        env.observation.subscribe(
            receiver: notificationReceiver,
            valueID: ValueID(keyPath: keyPath, key: key)
        )
        return value
    }

}

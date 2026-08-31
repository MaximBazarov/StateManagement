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
/// > Important: To prevent infinite recursion, the environment automatically tracks the IDs of values the service modifies. Calls to ``serve()`` won't happen if the only value that changed are changed by the service.
///
/// > Note: Subscriptions are one-shot. A Service re-subscribes itself after each run, so it keeps
/// reacting without re-reading. See <doc:Observing-State>.
///
/// ## Example
/// ```swift
/// final class UpdatesCounterService: EnvironmentService {
///
///     override func serve() async {
///         guard !isSetup else {
///             // Optional step if we need a separate setup
///             return await setup()
///         }
///         let x = getValue(\Counter.x)
///
///         // here normally serve() would be called again as we read x before.
///         // however since this service is the one who mutated it, we ignore such updates, so it's safe.
///         setValue(x + 1, keyPath: \Counter.x)
///     }
///
///     func setup() async {
///         // Do necessary instantiations and preparations
///         // Read values that we are interested in,
///         // otherwise environment won't know what to notify about.
///         let x = getValue(\Counter.x)
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

    /// IDs this service just wrote, so the notify that write triggers is ignored and the service
    /// does not react to its own change. An ID is added right before the write's notify and removed
    /// right after, so it only ever suppresses that one notify.
    internal var ignoreNotificationsFor: Set<ValueID> = []

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

        let relevant = updatedValueIDs.subtracting(self.ignoreNotificationsFor)
        guard !relevant.isEmpty else { return }

        // Accumulate. Two coalesced notifications union, they never overwrite each other.
        self.pendingValues.formUnion(relevant)

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
                // A previous run's own writes stop being ignored before this run.
                self.ignoreNotificationsFor = []
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

    /// Get value subscribing.
    /// - Parameter keyPath: path to the value e.g. `\MyState.myValue`.
    public func getValue<Storage: StateContainer, Value>(
        _ keyPath: KeyPath<Storage, Value>
    ) -> Value {
        // A dropped Service must not recreate a Container by reading.
        guard !isDropped else { return Storage()[keyPath: keyPath] }
        let value = env.getValue(keyPath: keyPath)
        env.observation.subscribe(
            receiver: notificationReceiver,
            valueID: ValueID(keyPath: keyPath)
        )
        return value
    }

    /// Get value subscribing.
    ///   - keyPath: path to the value e.g. `\MyState.myValue`.
    ///   - key: dictionary key of the value.
    public func getValue<Storage: StateContainer, Key: Hashable, Value>(
        keyPath: KeyPath<Storage, [Key: Value]>,
        key: Key
    ) -> Value? {
        // A dropped Service must not recreate a Container by reading.
        guard !isDropped else { return Storage()[keyPath: keyPath][key] }
        let value = env.getValue(keyPath: keyPath, key: key)
        env.observation.subscribe(
            receiver: notificationReceiver,
            valueID: ValueID(keyPath: keyPath, key: key)
        )
        return value
    }

    // MARK: - Awaitable sourced read

    /// Awaits the sourced Value at a `$` Address, subscribing like ``getValue(_:)``.
    ///
    /// `.settled` returns the Value with no kick. `.pending` or Stale kicks `onRead`, or Joins the
    /// kick already in flight, and waits for `apply` / `fail`. `.error` throws the stored `Failure`.
    ///
    /// The subscription outlives the wait, so the inbound `apply` that resumes this call also
    /// schedules the next ``serve()``. A strategy whose `onRead` returns without `apply` or `fail`
    /// leaves this call suspended; `reset` releases it with the current Value.
    public func read<Storage: StateContainer, S: AsyncStrategy, Value>(
        _ keyPath: KeyPath<Storage, AsyncState<S, Value, SourceStatus<S.Failure>>>
    ) async throws(S.Failure) -> Value {
        // A dropped Service must not recreate a Container by reading, and must not wait.
        guard !isDropped else { return Storage()[keyPath: keyPath].storage }
        return try await env.awaitSourced(keyPath) { [weak self] valueID in
            guard let self else { return }
            self.env.observation.subscribe(receiver: self.notificationReceiver, valueID: valueID)
        }
    }

    /// Awaits one key of a keyed sourced Address, subscribing to that key.
    public func read<Storage: StateContainer, S: AsyncStrategy, Key: Hashable, Output>(
        _ keyPath: KeyPath<Storage, AsyncState<S, [Key: Output], [Key: SourceStatus<S.Failure>]>>,
        key: Key
    ) async throws(S.Failure) -> Output? {
        guard !isDropped else { return Storage()[keyPath: keyPath].storage[key] }
        return try await env.awaitSourced(keyPath, key: key) { [weak self] valueID in
            guard let self else { return }
            self.env.observation.subscribe(receiver: self.notificationReceiver, valueID: valueID)
        }
    }

    /// Set value at path.
    /// - Parameters:
    ///   - newValue: New value.
    ///   - keyPath: path to the value e.g. `\MyState.myValue`.
    public func setValue<Storage: StateContainer, Value>(
        _ newValue: Value,
        keyPath: WritableKeyPath<Storage, Value>
    ) {
        guard !isDropped else { return }
        let valueID = ValueID(keyPath: keyPath)
        env.setValue(newValue, keyPath: keyPath)
        // Ignore this write in the notify that follows, then stop ignoring it so a
        // later external change to the same value still reacts. The callback runs
        // synchronously inside notifyAll, so the ignore has done its job on return.
        ignoreNotificationsFor.insert(valueID)
        env.observation.notifyAll()
        ignoreNotificationsFor.remove(valueID)
    }

    /// Sets a dictionary value at path.
    /// - Parameters:
    ///   - newValue: new value.
    ///   - keyPath: path to the value e.g. `\MyState.myValue`.
    ///   - key: dictionary key of the value.
    public func setValue<Storage: StateContainer, Key: Hashable, Value>(
        _ newValue: Value,
        keyPath: WritableKeyPath<Storage, [Key: Value]>,
        key: Key
    ) {
        guard !isDropped else { return }
        let valueID = ValueID(keyPath: keyPath)
        env.setValue(newValue, keyPath: keyPath, key: key)
        // Same as the atomic setValue: ignore only the notify this write triggers.
        ignoreNotificationsFor.insert(valueID)
        env.observation.notifyAll()
        ignoreNotificationsFor.remove(valueID)
    }
}

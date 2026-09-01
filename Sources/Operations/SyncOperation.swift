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
import OSLog

private let syncOperationLogger = Logger(
    subsystem: "StateManagement",
    category: "SyncOperation"
)

/// A Sync operation that may throw `Failure`.
///
/// `Failure` is `Never` for a non-throwing operation. Write `struct Increment: SyncOperation`
/// with a non-throwing `perform`; the compiler infers `Never`.
@MainActor public protocol ThrowingSyncOperation<Failure> {
    associatedtype Failure: Error = Never
    func perform(in env: SyncOperationEnvironment) throws(Failure)
}

/// A Sync operation that does not throw.
///
/// A refining protocol, not `ThrowingSyncOperation<Never>` as a typealias, so
/// `any SyncOperation` is not a parameterized existential (macOS 12).
@MainActor public protocol SyncOperation: ThrowingSyncOperation where Failure == Never {}

/// A restricted interface of ``SharedEnvironment`` provided to ``SyncOperation``.
///
/// We use those for operations to restrict which actions they could take and define the observation behavior.
@MainActor public final class SyncOperationEnvironment {
    unowned var environment: SharedEnvironment
    let allowsWrite: Bool

    init(_ environment: SharedEnvironment, allowsWrite: Bool = true) {
        self.environment = environment
        self.allowsWrite = allowsWrite
    }

    /// Nested sync `perform` shares this Environment. Notification waits for the original `SharedEnvironment.perform`.
    public func perform<Op: ThrowingSyncOperation>(
        _ operation: Op,
        file: String = #fileID,
        line: UInt = #line
    ) throws(Op.Failure) {
        if allowsWrite {
            try environment.perform(operation, file: file, line: line)
        } else {
            try environment.performClosedWrite(operation, file: file, line: line)
        }
    }

    /// Starts a non-throwing async Operation without waiting. Throwing async is `try await` only.
    public func perform<Op: AsyncOperation>(
        _ operation: Op,
        file: String = #fileID,
        line: UInt = #line
    ) {
        environment.perform(operation, file: file, line: line)
    }

    // MARK: - I/O

    public func read<Storage: StateContainer, Value>(
        _ keyPath: KeyPath<Storage, Value>
    ) -> Value {
        environment.read(keyPath)
    }

    /// Reads the whole dictionary. That Address names a whole fact and never kicks a strategy;
    /// reading one entry of the same declaration does (ADR 0026).
    public func read<Storage: StateContainer, Key: Hashable, Value>(
        _ keyPath: KeyPath<Storage, [Key: Value]>
    ) -> [Key: Value] {
        environment.read(keyPath)
    }

    public func write<Storage: StateContainer, Value>(
        _ keyPath: WritableKeyPath<Storage, Value>,
        value newValue: Value
    ) {
        precondition(!(newValue is ComputedRefusesStorage), computedIsNotStorable)
        guard allowsWrite else {
            syncOperationLogger.debug("Nested strategy perform has no write")
            return
        }
        environment.write(keyPath, value: newValue)
    }

    // MARK: - Computed

    /// Reads an atomic ``Computed``. The Operation does not subscribe: it reads and lets go.
    /// The cache and the dependency edges behave as for any other reader (ADR 0023).
    public func read<Storage: StateContainer, Output>(
        _ keyPath: KeyPath<Storage, Computed<NoKey, Output>>
    ) -> Output {
        environment
            .read(keyPath)
            .read(
                env: environment,
                valueID: ValueID(keyPath: keyPath),
                receiver: nil,
                key: .noKey
            )
    }

    /// Reads a keyed ``Computed`` for `key`, without subscribing.
    public func read<Storage: StateContainer, Key: Hashable, Output>(
        _ keyPath: KeyPath<Storage, Computed<Key, Output>>,
        key: Key
    ) -> Output {
        environment
            .read(keyPath)
            .read(
                env: environment,
                valueID: ValueID(keyPath: keyPath, key: key),
                receiver: nil,
                key: key
            )
    }

    // MARK: - Dictionary

    /// Returns a value in a dictionary stored at the given key path.
    public func read<Storage: StateContainer, Key: Hashable, Value>(
        _ keyPath: KeyPath<Storage, [Key: Value]>,
        key: Key
    ) -> Value? {
        environment.read(keyPath, key: key)
    }

    /// Sets a dictionary value for the given key and reports a change for observation.
    public func write<Storage: StateContainer, Key: Hashable, Value>(
        _ keyPath: WritableKeyPath<Storage, [Key: Value]>,
        key: Key,
        value newValue: Value
    ) {
        precondition(!(newValue is ComputedRefusesStorage), computedIsNotStorable)
        guard allowsWrite else {
            syncOperationLogger.debug("Nested strategy perform has no write")
            return
        }
        environment.write(keyPath, key: key, value: newValue)
    }

    /// Removes a dictionary value for the given key and reports a change for observation.
    ///
    /// Prefer this over rewriting the whole dictionary when deleting an entry: it invalidates the
    /// keyed value so per-key watchers are notified (and their subscriptions flushed).
    public func remove<Storage: StateContainer, Key: Hashable, Value>(
        _ keyPath: WritableKeyPath<Storage, [Key: Value]>,
        key: Key
    ) {
        guard allowsWrite else {
            syncOperationLogger.debug("Nested strategy perform has no write")
            return
        }
        environment.remove(keyPath, key: key)
    }

    // MARK: - A Computed is not storable

    // Deprecated rather than unavailable: Swift skips an unavailable overload whenever an
    // available one also matches, and the generic `write` always matches, so `unavailable` here
    // would never fire. Deprecated candidates *are* selected, so the more specific one wins and
    // carries the reason at compile time. The body traps, so the mistake cannot reach State.
    // The message repeats `computedIsNotStorable`: an attribute cannot reference a constant.

    @available(*, deprecated, message: """
    A Computed is derived, not stored. Declare it with @Computed and reach it through its Address \
    (\\Container.$name).
    """)
    public func write<Storage: StateContainer, Key: Hashable, Output>(
        _ keyPath: WritableKeyPath<Storage, Computed<Key, Output>>,
        value newValue: Computed<Key, Output>
    ) {
        preconditionFailure(computedIsNotStorable)
    }

    @available(*, deprecated, message: """
    A Computed is derived, not stored. Declare it with @Computed and reach it through its Address \
    (\\Container.$name).
    """)
    public func write<Storage: StateContainer, DictKey: Hashable, Key: Hashable, Output>(
        _ keyPath: WritableKeyPath<Storage, [DictKey: Computed<Key, Output>]>,
        key: DictKey,
        value newValue: Computed<Key, Output>
    ) {
        preconditionFailure(computedIsNotStorable)
    }

    @available(*, deprecated, message: """
    A Computed is derived, not stored. Declare it with @Computed and reach it through its Address \
    (\\Container.$name).
    """)
    public func write<Storage: StateContainer, DictKey: Hashable, Key: Hashable, Output>(
        _ keyPath: WritableKeyPath<Storage, [DictKey: Computed<Key, Output>]>,
        value newValue: [DictKey: Computed<Key, Output>]
    ) {
        preconditionFailure(computedIsNotStorable)
    }

    /// Drops every Container, Service, and AsyncStrategy. Cancels every in-flight Execution.
    public func reset() {
        environment.resetAll()
    }

    /// Drops the named Container type and calls `onDrop` for its sourced Addresses. Cancels every in-flight Execution.
    public func reset<Storage: StateContainer>(_ type: Storage.Type) {
        environment.resetContainer(type)
    }
}
